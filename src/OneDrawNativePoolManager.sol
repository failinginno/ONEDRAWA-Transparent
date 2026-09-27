// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRandomnessProvider} from "./interfaces/IRandomnessProvider.sol";
import {IRandomnessConsumer} from "./interfaces/IRandomnessConsumer.sol";
import {NativeFeeVault} from "./NativeFeeVault.sol";

/// @notice ONEDRAW pool manager dedicated to the chain's native ETH asset.
/// @dev Deployed separately from the immutable USDG manager so neither system can affect the other's funds.
contract OneDrawNativePoolManager is Ownable2Step, Pausable, ReentrancyGuard, IRandomnessConsumer {

    uint32 public constant MAX_CAPACITY = 1_000;
    uint64 public constant MAX_DURATION = 365 days;

    enum PoolStatus {
        WAITING,
        LIVE,
        DRAWING,
        COMPLETED,
        EXPIRED
    }

    struct Pool {
        uint256 id;
        address token;
        uint128 prizeAmount;
        uint128 ticketPrice;
        uint32 capacity;
        uint32 ticketsSold;
        uint64 duration;
        uint64 startTime;
        uint64 deadline;
        uint128 protocolFee;
        PoolStatus status;
        address winner;
        uint32 winningTicket;
        uint256 randomnessRequestId;
    }

    struct RandomnessRequest {
        uint256 poolId;
        bool fulfilled;
    }

    /// @notice Immutable economics used to create a sequence of identical pools.
    /// The owner may disable a template, but cannot alter its economics after creation.
    struct PoolTemplate {
        uint128 prizeAmount;
        uint128 ticketPrice;
        uint32 capacity;
        uint64 duration;
        uint128 protocolFee;
        bool enabled;
    }

    error ZeroAddress();
    error PoolNotFound();
    error InvalidQuantity();
    error InvalidCapacity();
    error InvalidDuration();
    error InvalidPoolEconomics();
    error PoolExpired();
    error PoolSoldOut();
    error PoolNotOpen();
    error InsufficientRemainingTickets();
    error RefundUnavailable();
    error InvalidRandomnessRequest();
    error PoolNotDrawing();
    error WinnerAlreadySelected();
    error PrizeUnavailable();
    error PoolTemplateNotFound();
    error PoolTemplateDisabled();
    error PoolNotTerminal();
    error PoolHasNoTemplate();
    error SuccessorAlreadyCreated();
    error IncorrectPayment();
    error NativeTransferFailed();

    NativeFeeVault public immutable feeVault;
    IRandomnessProvider public randomnessProvider;
    uint256 public nextPoolId = 1;
    uint256 public nextPoolTemplateId = 1;
    uint256 public totalOutstandingLiabilities;

    mapping(uint256 poolId => Pool pool) private _pools;
    mapping(uint256 poolId => mapping(uint32 ticketIndex => address owner)) private _ticketOwners;
    mapping(uint256 poolId => mapping(address wallet => uint32[] ticketIndexes)) private _userTickets;
    mapping(uint256 poolId => mapping(address wallet => uint256 amount)) public contributions;
    mapping(address provider => mapping(uint256 requestId => RandomnessRequest request)) private _requests;
    mapping(uint256 poolId => bool claimed) public prizeClaimed;
    mapping(uint256 templateId => PoolTemplate poolTemplate) public poolTemplates;
    mapping(uint256 poolId => uint256 templateId) public poolTemplateId;
    mapping(uint256 poolId => uint256 successorPoolId) public successorPoolId;

    event PoolCreated(
        uint256 indexed poolId,
        address indexed token,
        uint128 prizeAmount,
        uint128 ticketPrice,
        uint32 capacity,
        uint64 duration,
        uint128 protocolFee
    );
    event PoolStarted(uint256 indexed poolId, uint64 startTime, uint64 deadline);
    event TicketsPurchased(
        uint256 indexed poolId, address indexed buyer, uint32 quantity, uint32 firstTicketIndex, uint256 amount
    );
    event PoolFilled(uint256 indexed poolId, uint32 ticketsSold);
    event RandomnessRequested(uint256 indexed poolId, uint256 indexed requestId, address indexed provider);
    event WinnerSelected(uint256 indexed poolId, address indexed winner, uint32 winningTicket, uint256 randomValue);
    event PrizePaid(uint256 indexed poolId, address indexed winner, uint256 amount);
    event ProtocolFeeAccrued(uint256 indexed poolId, address indexed feeVault, uint256 amount);
    event RefundClaimed(uint256 indexed poolId, address indexed wallet, uint256 amount);
    event PoolExpiredStateSynced(uint256 indexed poolId);
    event RandomnessProviderUpdated(address indexed previousProvider, address indexed newProvider);
    event PoolTemplateCreated(
        uint256 indexed templateId,
        uint128 prizeAmount,
        uint128 ticketPrice,
        uint32 capacity,
        uint64 duration,
        uint128 protocolFee
    );
    event PoolTemplateStatusUpdated(uint256 indexed templateId, bool enabled);
    event PoolRolledOver(uint256 indexed previousPoolId, uint256 indexed nextPoolId, uint256 indexed templateId);

    constructor(address initialOwner, address feeVault_, address randomnessProvider_)
        Ownable(initialOwner)
    {
        if (feeVault_ == address(0) || randomnessProvider_ == address(0)) {
            revert ZeroAddress();
        }
        feeVault = NativeFeeVault(payable(feeVault_));
        randomnessProvider = IRandomnessProvider(randomnessProvider_);
    }

    function createPool(uint128 prizeAmount, uint128 ticketPrice, uint32 capacity, uint64 duration, uint128 protocolFee)
        external
        onlyOwner
        whenNotPaused
        returns (uint256 poolId)
    {
        return _createPool(prizeAmount, ticketPrice, capacity, duration, protocolFee, 0);
    }

    /// @notice Creates a reusable, immutable pool configuration for automatic rollover.
    function createPoolTemplate(
        uint128 prizeAmount,
        uint128 ticketPrice,
        uint32 capacity,
        uint64 duration,
        uint128 protocolFee
    ) external onlyOwner returns (uint256 templateId) {
        _validatePoolEconomics(prizeAmount, ticketPrice, capacity, duration, protocolFee);
        templateId = nextPoolTemplateId++;
        poolTemplates[templateId] = PoolTemplate({
            prizeAmount: prizeAmount,
            ticketPrice: ticketPrice,
            capacity: capacity,
            duration: duration,
            protocolFee: protocolFee,
            enabled: true
        });
        emit PoolTemplateCreated(templateId, prizeAmount, ticketPrice, capacity, duration, protocolFee);
    }

    function setPoolTemplateEnabled(uint256 templateId, bool enabled) external onlyOwner {
        PoolTemplate storage poolTemplate = poolTemplates[templateId];
        if (poolTemplate.capacity == 0) revert PoolTemplateNotFound();
        poolTemplate.enabled = enabled;
        emit PoolTemplateStatusUpdated(templateId, enabled);
    }

    /// @notice Owner-only bootstrap for the first pool in a recurring series.
    function createPoolFromTemplate(uint256 templateId) external onlyOwner whenNotPaused returns (uint256 poolId) {
        PoolTemplate storage poolTemplate = _enabledPoolTemplate(templateId);
        poolId = _createPool(
            poolTemplate.prizeAmount,
            poolTemplate.ticketPrice,
            poolTemplate.capacity,
            poolTemplate.duration,
            poolTemplate.protocolFee,
            templateId
        );
    }

    /// @notice Permissionless, idempotency-guarded creation of the next pool in a series.
    /// Automation only pays gas; it cannot choose or modify pool economics.
    function rolloverPool(uint256 previousPoolId) external whenNotPaused returns (uint256 nextPoolId_) {
        Pool storage previousPool = _pool(previousPoolId);
        if (_isEconomicallyExpired(previousPool) && previousPool.status == PoolStatus.LIVE) {
            previousPool.status = PoolStatus.EXPIRED;
            emit PoolExpiredStateSynced(previousPoolId);
        }
        if (previousPool.status != PoolStatus.COMPLETED && previousPool.status != PoolStatus.EXPIRED) {
            revert PoolNotTerminal();
        }
        uint256 templateId = poolTemplateId[previousPoolId];
        if (templateId == 0) revert PoolHasNoTemplate();
        if (successorPoolId[previousPoolId] != 0) revert SuccessorAlreadyCreated();

        PoolTemplate storage poolTemplate = _enabledPoolTemplate(templateId);
        nextPoolId_ = _createPool(
            poolTemplate.prizeAmount,
            poolTemplate.ticketPrice,
            poolTemplate.capacity,
            poolTemplate.duration,
            poolTemplate.protocolFee,
            templateId
        );
        successorPoolId[previousPoolId] = nextPoolId_;
        emit PoolRolledOver(previousPoolId, nextPoolId_, templateId);
    }

    function _createPool(
        uint128 prizeAmount,
        uint128 ticketPrice,
        uint32 capacity,
        uint64 duration,
        uint128 protocolFee,
        uint256 templateId
    ) internal returns (uint256 poolId) {
        _validatePoolEconomics(prizeAmount, ticketPrice, capacity, duration, protocolFee);
        if (templateId != 0 && !poolTemplates[templateId].enabled) revert PoolTemplateDisabled();

        poolId = nextPoolId++;
        _pools[poolId] = Pool({
            id: poolId,
            token: address(0),
            prizeAmount: prizeAmount,
            ticketPrice: ticketPrice,
            capacity: capacity,
            ticketsSold: 0,
            duration: duration,
            startTime: 0,
            deadline: 0,
            protocolFee: protocolFee,
            status: PoolStatus.WAITING,
            winner: address(0),
            winningTicket: 0,
            randomnessRequestId: 0
        });
        poolTemplateId[poolId] = templateId;

        emit PoolCreated(poolId, address(0), prizeAmount, ticketPrice, capacity, duration, protocolFee);
    }

    function _validatePoolEconomics(
        uint128 prizeAmount,
        uint128 ticketPrice,
        uint32 capacity,
        uint64 duration,
        uint128 protocolFee
    ) internal pure {
        if (prizeAmount == 0 || ticketPrice == 0) revert InvalidPoolEconomics();
        if (capacity <= 1 || capacity > MAX_CAPACITY) revert InvalidCapacity();
        if (duration == 0 || duration > MAX_DURATION) revert InvalidDuration();
        if (uint256(ticketPrice) * capacity != uint256(prizeAmount) + protocolFee) {
            revert InvalidPoolEconomics();
        }
    }

    function _enabledPoolTemplate(uint256 templateId) internal view returns (PoolTemplate storage poolTemplate) {
        poolTemplate = poolTemplates[templateId];
        if (poolTemplate.capacity == 0) revert PoolTemplateNotFound();
        if (!poolTemplate.enabled) revert PoolTemplateDisabled();
    }

    function buyTickets(uint256 poolId, uint32 quantity) external payable nonReentrant whenNotPaused {
        Pool storage pool = _pool(poolId);
        if (quantity == 0) revert InvalidQuantity();
        if (pool.status == PoolStatus.DRAWING || pool.status == PoolStatus.COMPLETED) revert PoolNotOpen();
        if (pool.status == PoolStatus.EXPIRED) revert PoolExpired();
        // Timestamp is the protocol's explicit deadline clock; equality is expired.
        // forge-lint: disable-next-line(block-timestamp)
        if (pool.status == PoolStatus.LIVE && block.timestamp >= pool.deadline) revert PoolExpired();

        uint32 remaining = pool.capacity - pool.ticketsSold;
        if (remaining == 0) revert PoolSoldOut();
        if (quantity > remaining) revert InsufficientRemainingTickets();

        uint256 amount = uint256(quantity) * pool.ticketPrice;
        if (msg.value != amount) revert IncorrectPayment();

        if (pool.status == PoolStatus.WAITING) {
            pool.status = PoolStatus.LIVE;
            // Safe for all practical chain timestamps and a uint64 duration.
            // forge-lint: disable-next-line(unsafe-typecast)
            pool.startTime = uint64(block.timestamp);
            // Safe for all practical chain timestamps and a uint64 duration.
            // forge-lint: disable-next-line(unsafe-typecast)
            pool.deadline = uint64(block.timestamp + pool.duration);
            emit PoolStarted(poolId, pool.startTime, pool.deadline);
        }

        uint32 firstTicketIndex = pool.ticketsSold;
        uint32 endExclusive = firstTicketIndex + quantity;
        for (uint32 ticketIndex = firstTicketIndex; ticketIndex < endExclusive; ++ticketIndex) {
            _ticketOwners[poolId][ticketIndex] = msg.sender;
            _userTickets[poolId][msg.sender].push(ticketIndex);
        }

        pool.ticketsSold = endExclusive;
        contributions[poolId][msg.sender] += amount;
        totalOutstandingLiabilities += amount;
        emit TicketsPurchased(poolId, msg.sender, quantity, firstTicketIndex, amount);

        if (endExclusive == pool.capacity) {
            pool.status = PoolStatus.DRAWING;
            emit PoolFilled(poolId, endExclusive);

            IRandomnessProvider provider = randomnessProvider;
            // nonReentrant protects the complete purchase path during the provider call.
            // forge-lint: disable-next-line(reentrancy-no-eth)
            uint256 requestId = provider.requestRandomness(poolId);
            if (requestId == 0 || _requests[address(provider)][requestId].poolId != 0) {
                revert InvalidRandomnessRequest();
            }
            _requests[address(provider)][requestId] = RandomnessRequest({poolId: poolId, fulfilled: false});
            pool.randomnessRequestId = requestId;
            // The provider must return requestId before this event can be emitted.
            // forge-lint: disable-next-line(reentrancy-events)
            emit RandomnessRequested(poolId, requestId, address(provider));
        }
    }

    function fulfillRandomness(uint256 requestId, uint256 randomValue) external nonReentrant {
        RandomnessRequest storage request = _requests[msg.sender][requestId];
        if (request.poolId == 0 || request.fulfilled) revert InvalidRandomnessRequest();

        Pool storage pool = _pool(request.poolId);
        if (pool.status != PoolStatus.DRAWING) revert PoolNotDrawing();
        if (pool.randomnessRequestId != requestId || pool.ticketsSold != pool.capacity) {
            revert InvalidRandomnessRequest();
        }
        if (pool.winner != address(0)) revert WinnerAlreadySelected();

        // Modulo capacity is strictly less than uint32 capacity.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 winningTicket = uint32(randomValue % pool.capacity);
        address winner = _ticketOwners[pool.id][winningTicket];
        if (winner == address(0)) revert InvalidRandomnessRequest();

        request.fulfilled = true;
        pool.winningTicket = winningTicket;
        pool.winner = winner;
        pool.status = PoolStatus.COMPLETED;

        totalOutstandingLiabilities -= pool.protocolFee;

        emit WinnerSelected(pool.id, winner, winningTicket, randomValue);
        emit ProtocolFeeAccrued(pool.id, address(feeVault), pool.protocolFee);

        if (pool.protocolFee != 0) {
            feeVault.recordAccrual{value: pool.protocolFee}();
        }
    }

    /// @notice Allows only the permanently selected winner to pull the prize.
    function claimPrize(uint256 poolId) external nonReentrant {
        Pool storage pool = _pool(poolId);
        if (pool.status != PoolStatus.COMPLETED || pool.winner != msg.sender || prizeClaimed[poolId]) {
            revert PrizeUnavailable();
        }
        prizeClaimed[poolId] = true;
        totalOutstandingLiabilities -= pool.prizeAmount;
        _sendNative(msg.sender, pool.prizeAmount);
        emit PrizePaid(poolId, msg.sender, pool.prizeAmount);
    }

    function getClaimablePrize(uint256 poolId, address wallet) external view returns (uint256) {
        Pool storage pool = _pool(poolId);
        return
            pool.status == PoolStatus.COMPLETED && pool.winner == wallet && !prizeClaimed[poolId] ? pool.prizeAmount : 0;
    }

    function claimRefund(uint256 poolId) external nonReentrant {
        Pool storage pool = _pool(poolId);
        if (!_isEconomicallyExpired(pool)) revert RefundUnavailable();

        uint256 amount = contributions[poolId][msg.sender];
        if (amount == 0) revert RefundUnavailable();

        if (pool.status == PoolStatus.LIVE) {
            pool.status = PoolStatus.EXPIRED;
            emit PoolExpiredStateSynced(poolId);
        }
        contributions[poolId][msg.sender] = 0;
        totalOutstandingLiabilities -= amount;
        _sendNative(msg.sender, amount);
        emit RefundClaimed(poolId, msg.sender, amount);
    }

    function syncPoolState(uint256 poolId) external returns (PoolStatus status) {
        Pool storage pool = _pool(poolId);
        if (_isEconomicallyExpired(pool) && pool.status == PoolStatus.LIVE) {
            pool.status = PoolStatus.EXPIRED;
            emit PoolExpiredStateSynced(poolId);
        }
        return pool.status;
    }

    function setRandomnessProvider(address newProvider) external onlyOwner {
        if (newProvider == address(0)) revert ZeroAddress();
        address previous = address(randomnessProvider);
        randomnessProvider = IRandomnessProvider(newProvider);
        emit RandomnessProviderUpdated(previous, newProvider);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getPool(uint256 poolId) external view returns (Pool memory) {
        return _poolView(poolId);
    }

    function getEffectiveStatus(uint256 poolId) public view returns (PoolStatus) {
        Pool storage pool = _pool(poolId);
        if (_isEconomicallyExpired(pool)) return PoolStatus.EXPIRED;
        return pool.status;
    }

    function getTicketOwner(uint256 poolId, uint32 ticketIndex) external view returns (address) {
        Pool storage pool = _pool(poolId);
        if (ticketIndex >= pool.ticketsSold) revert InvalidQuantity();
        return _ticketOwners[poolId][ticketIndex];
    }

    function getUserTickets(uint256 poolId, address wallet) external view returns (uint32[] memory) {
        _pool(poolId);
        return _userTickets[poolId][wallet];
    }

    function getContribution(uint256 poolId, address wallet) external view returns (uint256) {
        _pool(poolId);
        return contributions[poolId][wallet];
    }

    function getRefundableAmount(uint256 poolId, address wallet) external view returns (uint256) {
        Pool storage pool = _pool(poolId);
        return _isEconomicallyExpired(pool) ? contributions[poolId][wallet] : 0;
    }

    function getRandomnessRequest(address provider, uint256 requestId)
        external
        view
        returns (RandomnessRequest memory)
    {
        return _requests[provider][requestId];
    }

    function _sendNative(address recipient, uint256 amount) internal {
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert NativeTransferFailed();
    }

    function _isEconomicallyExpired(Pool storage pool) internal view returns (bool) {
        uint256 currentTime = block.timestamp;
        return (pool.status == PoolStatus.LIVE || pool.status == PoolStatus.EXPIRED) && pool.deadline != 0
            // Timestamp is the protocol's explicit deadline clock.
            // forge-lint: disable-next-line(block-timestamp)
            && currentTime >= pool.deadline && pool.ticketsSold < pool.capacity;
    }

    function _pool(uint256 poolId) internal view returns (Pool storage pool) {
        pool = _pools[poolId];
        if (pool.id == 0) revert PoolNotFound();
    }

    function _poolView(uint256 poolId) internal view returns (Pool memory pool) {
        pool = _pools[poolId];
        if (pool.id == 0) revert PoolNotFound();
    }
}

