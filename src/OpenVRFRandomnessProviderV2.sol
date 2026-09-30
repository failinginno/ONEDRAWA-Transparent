// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRandomnessProvider} from "./interfaces/IRandomnessProvider.sol";
import {IRandomnessConsumer} from "./interfaces/IRandomnessConsumer.sol";
import {IOpenVRFRouter, IOpenVRFConsumer} from "./interfaces/IOpenVRFRouter.sol";

/// @notice Binds ONEDRAW pool requests to authenticated OpenVRF callbacks.
/// @dev A failed manager callback stores the same verified word for permissionless retry; it never redraws.
contract OpenVRFRandomnessProviderV2 is IRandomnessProvider, IOpenVRFConsumer, Ownable2Step {
    uint32 public constant MIN_CALLBACK_GAS = 25_000;
    uint32 public constant MAX_CALLBACK_GAS = 1_000_000;

    struct Request {
        uint256 poolId;
        uint256 randomWord;
        bool received;
        bool delivered;
    }

    error ZeroAddress();
    error ManagerAlreadyConfigured();
    error UnauthorizedManager();
    error UnauthorizedRouter();
    error InvalidCallbackGasLimit();
    error InsufficientRequestFunds(uint256 required, uint256 available);
    error InvalidRequest();
    error RandomnessAlreadyReceived();
    error DeliveryFailed();
    error NativeTransferFailed();

    IOpenVRFRouter public immutable router;
    IRandomnessConsumer public manager;
    uint32 public callbackGasLimit;

    mapping(uint256 requestId => Request request) public requests;

    event AdapterRequestCreated(uint256 indexed requestId, uint256 indexed poolId, uint256 fee);
    event VerifiedRandomnessReceived(uint256 indexed requestId, uint256 randomWord);
    event ManagerDeliveryAttempted(uint256 indexed requestId, bool success);
    event CallbackGasLimitUpdated(uint32 previousLimit, uint32 newLimit);
    event NativeFundsWithdrawn(address indexed recipient, uint256 amount);
    event ManagerConfigured(address indexed manager);

    constructor(address initialOwner, address router_, uint32 callbackGasLimit_)
        Ownable(initialOwner)
    {
        if (router_ == address(0) || router_.code.length == 0) revert ZeroAddress();
        _validateCallbackGasLimit(callbackGasLimit_);
        router = IOpenVRFRouter(router_);
        callbackGasLimit = callbackGasLimit_;
    }

    receive() external payable {}

    /// @notice One-time binding to the PoolManager. It can never be replaced.
    function configureManager(address manager_) external onlyOwner {
        if (manager_ == address(0) || manager_.code.length == 0) revert ZeroAddress();
        if (address(manager) != address(0)) revert ManagerAlreadyConfigured();
        manager = IRandomnessConsumer(manager_);
        emit ManagerConfigured(manager_);
    }

    function requestRandomness(uint256 poolId) external returns (uint256 requestId) {
        if (msg.sender != address(manager)) revert UnauthorizedManager();
        uint256 fee = router.requestFee();
        uint256 available = address(this).balance;
        if (available < fee) revert InsufficientRequestFunds(fee, available);

        requestId = router.requestRandomness{value: fee}(callbackGasLimit);
        if (requestId == 0 || requests[requestId].poolId != 0) revert InvalidRequest();
        requests[requestId].poolId = poolId;
        emit AdapterRequestCreated(requestId, poolId, fee);
    }

    /// @notice Receives a word only from the immutable router and preserves it before delivery.
    function rawFulfillRandomness(uint256 requestId, uint256 randomWord) external {
        if (msg.sender != address(router)) revert UnauthorizedRouter();
        Request storage request = requests[requestId];
        if (request.poolId == 0) revert InvalidRequest();
        if (request.received) revert RandomnessAlreadyReceived();

        request.randomWord = randomWord;
        request.received = true;
        emit VerifiedRandomnessReceived(requestId, randomWord);
        _attemptDelivery(requestId, request);
    }

    /// @notice Retries manager settlement with the already-verified word; callable by anyone.
    function retryDelivery(uint256 requestId) external {
        Request storage request = requests[requestId];
        if (!request.received || request.delivered) revert InvalidRequest();
        _attemptDelivery(requestId, request);
        if (!request.delivered) revert DeliveryFailed();
    }

    function setCallbackGasLimit(uint32 newLimit) external onlyOwner {
        _validateCallbackGasLimit(newLimit);
        uint32 previous = callbackGasLimit;
        callbackGasLimit = newLimit;
        emit CallbackGasLimitUpdated(previous, newLimit);
    }

    /// @notice Withdraws uncommitted adapter balance. Fees are transferred to the router at request time.
    function withdrawNative(address payable recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
        emit NativeFundsWithdrawn(recipient, amount);
    }

    function _attemptDelivery(uint256 requestId, Request storage request) private {
        try manager.fulfillRandomness(requestId, request.randomWord) {
            request.delivered = true;
            emit ManagerDeliveryAttempted(requestId, true);
        } catch {
            emit ManagerDeliveryAttempted(requestId, false);
        }
    }

    function _validateCallbackGasLimit(uint32 limit) private pure {
        if (limit < MIN_CALLBACK_GAS || limit > MAX_CALLBACK_GAS) revert InvalidCallbackGasLimit();
    }
}
