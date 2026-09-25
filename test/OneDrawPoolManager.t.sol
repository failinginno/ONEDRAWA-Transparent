// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {OneDrawPoolManager} from "../src/OneDrawPoolManager.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockRandomnessProvider} from "../src/mocks/MockRandomnessProvider.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

contract OneDrawPoolManagerTest is Test {
    uint128 internal constant USDG = 1_000_000;
    uint128 internal constant PRIZE = 10 * USDG;
    uint128 internal constant FEE = USDG;
    uint32 internal constant CAPACITY = 11;
    uint64 internal constant DURATION = 180;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    MockUSDG internal token;
    FeeVault internal vault;
    MockRandomnessProvider internal randomness;
    OneDrawPoolManager internal manager;

    function setUp() public {
        token = new MockUSDG();
        vault = new FeeVault(owner);
        randomness = new MockRandomnessProvider(address(this));
        manager = new OneDrawPoolManager(owner, address(token), address(vault), address(randomness));

        vm.prank(owner);
        vault.configureManager(address(manager));

        _fundAndApprove(alice);
        _fundAndApprove(bob);
    }

    function test_CreatePoolStoresImmutableEconomics() public {
        uint256 poolId = _createDefaultPool();
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        assertEq(pool.id, poolId);
        assertEq(pool.token, address(token));
        assertEq(pool.prizeAmount, PRIZE);
        assertEq(pool.ticketPrice, USDG);
        assertEq(pool.capacity, CAPACITY);
        assertEq(pool.protocolFee, FEE);
        assertEq(uint8(pool.status), uint8(OneDrawPoolManager.PoolStatus.WAITING));
    }

    function test_MockRandomnessFulfillmentIsOwnerOnly() public {
        uint256 poolId = _createDefaultPool();
        vm.prank(alice);
        manager.buyTickets(poolId, CAPACITY);
        uint256 requestId = manager.getPool(poolId).randomnessRequestId;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        randomness.fulfill(requestId, 0);
    }

    function test_CreatePoolRejectsInvalidEconomics() public {
        vm.prank(owner);
        vm.expectRevert(OneDrawPoolManager.InvalidPoolEconomics.selector);
        manager.createPool(PRIZE, USDG, CAPACITY, DURATION, FEE + 1);
    }

    function test_CreatePoolRejectsInvalidCapacityAndDuration() public {
        vm.startPrank(owner);
        vm.expectRevert(OneDrawPoolManager.InvalidCapacity.selector);
        manager.createPool(USDG, USDG, 1, DURATION, 0);
        vm.expectRevert(OneDrawPoolManager.InvalidCapacity.selector);
        manager.createPool(1_000 * USDG, USDG, 1_001, DURATION, USDG);
        vm.expectRevert(OneDrawPoolManager.InvalidDuration.selector);
        manager.createPool(PRIZE, USDG, CAPACITY, 0, FEE);
        vm.expectRevert(OneDrawPoolManager.InvalidDuration.selector);
        manager.createPool(PRIZE, USDG, CAPACITY, 366 days, FEE);
        vm.stopPrank();
    }

    function test_NonOwnerCannotCreatePool() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        manager.createPool(PRIZE, USDG, CAPACITY, DURATION, FEE);
    }

    function test_FirstPurchaseStartsTimerExactlyOnce() public {
        uint256 poolId = _createDefaultPool();
        uint256 firstTimestamp = vm.getBlockTimestamp();
        _buy(alice, poolId, 2);
        OneDrawPoolManager.Pool memory afterFirst = manager.getPool(poolId);
        assertEq(afterFirst.startTime, firstTimestamp);
        assertEq(afterFirst.deadline, firstTimestamp + DURATION);
        assertEq(uint8(afterFirst.status), uint8(OneDrawPoolManager.PoolStatus.LIVE));

        vm.warp(block.timestamp + 30);
        _buy(bob, poolId, 1);
        OneDrawPoolManager.Pool memory afterSecond = manager.getPool(poolId);
        assertEq(afterSecond.startTime, firstTimestamp);
        assertEq(afterSecond.deadline, firstTimestamp + DURATION);
    }

    function test_SingleAndMultiplePurchasesAssignSequentialZeroBasedTickets() public {
        uint256 poolId = _createDefaultPool();
        _buy(alice, poolId, 2);
        _buy(bob, poolId, 3);

        assertEq(manager.getTicketOwner(poolId, 0), alice);
        assertEq(manager.getTicketOwner(poolId, 1), alice);
        assertEq(manager.getTicketOwner(poolId, 2), bob);
        assertEq(manager.getTicketOwner(poolId, 4), bob);
        uint32[] memory aliceTickets = manager.getUserTickets(poolId, alice);
        assertEq(aliceTickets.length, 2);
        assertEq(aliceTickets[0], 0);
        assertEq(aliceTickets[1], 1);
        assertEq(manager.getContribution(poolId, alice), 2 * USDG);
        assertEq(manager.getContribution(poolId, bob), 3 * USDG);
    }

    function test_SameWalletPurchasesAccumulateTicketsAndContribution() public {
        uint256 poolId = _createDefaultPool();
        _buy(alice, poolId, 2);
        _buy(alice, poolId, 3);
        assertEq(manager.getUserTickets(poolId, alice).length, 5);
        assertEq(manager.getContribution(poolId, alice), 5 * USDG);
    }

    function test_CannotBuyZeroOrOversellAndNoPartialFillOccurs() public {
        uint256 poolId = _createDefaultPool();
        vm.startPrank(alice);
        vm.expectRevert(OneDrawPoolManager.InvalidQuantity.selector);
        manager.buyTickets(poolId, 0);
        vm.expectRevert(OneDrawPoolManager.InsufficientRemainingTickets.selector);
        manager.buyTickets(poolId, CAPACITY + 1);
        vm.stopPrank();
        assertEq(manager.getPool(poolId).ticketsSold, 0);
    }

    function test_DeadlineBoundaryRejectsAtDeadlineButAllowsOneSecondBefore() public {
        uint256 poolId = _createDefaultPool();
        _buy(alice, poolId, 1);
        uint64 deadline = manager.getPool(poolId).deadline;

        vm.warp(deadline - 1);
        _buy(bob, poolId, 1);

        vm.warp(deadline);
        vm.prank(bob);
        vm.expectRevert(OneDrawPoolManager.PoolExpired.selector);
        manager.buyTickets(poolId, 1);

        vm.warp(deadline + 1);
        vm.prank(bob);
        vm.expectRevert(OneDrawPoolManager.PoolExpired.selector);
        manager.buyTickets(poolId, 1);
    }

    function test_FinalPurchaseEntersDrawingAndRequestsRandomnessOnce() public {
        uint256 poolId = _createDefaultPool();
        _buy(alice, poolId, CAPACITY - 2);
        _buy(bob, poolId, 2);
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        assertEq(uint8(pool.status), uint8(OneDrawPoolManager.PoolStatus.DRAWING));
        assertEq(pool.randomnessRequestId, 1);
        assertEq(randomness.nextRequestId(), 2);

        vm.prank(alice);
        vm.expectRevert(OneDrawPoolManager.PoolNotOpen.selector);
        manager.buyTickets(poolId, 1);
    }

    function test_StaleCompetingFinalPurchaseRevertsAndNeverOversells() public {
        uint256 poolId = _createDefaultPool();
        _buy(alice, poolId, CAPACITY - 2);
        _buy(alice, poolId, 2);
        vm.prank(bob);
        vm.expectRevert(OneDrawPoolManager.PoolNotOpen.selector);
        manager.buyTickets(poolId, 2);
        assertEq(manager.getPool(poolId).ticketsSold, CAPACITY);
    }

    function test_FirstTicketCanWinAndSettlementIsExact() public {
        uint256 poolId = _fillDefaultPool();
        uint256 aliceBefore = token.balanceOf(alice);
        randomness.fulfill(1, 0);
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        assertEq(pool.winningTicket, 0);
        assertEq(pool.winner, alice);
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(manager.getClaimablePrize(poolId, alice), PRIZE);
        assertEq(vault.accruedFees(address(token)), FEE);
        assertEq(token.balanceOf(address(vault)), FEE);
        assertEq(token.balanceOf(address(manager)), PRIZE);
        assertEq(manager.totalOutstandingLiabilities(), PRIZE);

        vm.prank(bob);
        vm.expectRevert(OneDrawPoolManager.PrizeUnavailable.selector);
        manager.claimPrize(poolId);
        vm.prank(alice);
        manager.claimPrize(poolId);
        assertEq(token.balanceOf(alice), aliceBefore + PRIZE);
        assertEq(manager.getClaimablePrize(poolId, alice), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(manager.totalOutstandingLiabilities(), 0);
        vm.prank(alice);
        vm.expectRevert(OneDrawPoolManager.PrizeUnavailable.selector);
        manager.claimPrize(poolId);
    }

    function test_LastTicketCanWin() public {
        uint256 poolId = _createDefaultPool();
        _buy(alice, poolId, CAPACITY - 1);
        _buy(bob, poolId, 1);
        randomness.fulfill(1, CAPACITY - 1);
        assertEq(manager.getPool(poolId).winner, bob);
        assertEq(manager.getPool(poolId).winningTicket, CAPACITY - 1);
    }

    function test_RandomnessCannotFulfillTwiceOrFromWrongProvider() public {
        uint256 poolId = _fillDefaultPool();
        MockRandomnessProvider other = new MockRandomnessProvider(address(this));
        uint256 foreignRequest = other.requestRandomness(poolId);
        vm.expectRevert();
        other.fulfill(foreignRequest, 1);

        randomness.fulfill(1, 1);
        vm.expectRevert(MockRandomnessProvider.AlreadyFulfilled.selector);
        randomness.fulfill(1, 2);
    }

    function test_RandomnessProviderMigrationDoesNotInvalidatePendingRequest() public {
        uint256 poolId = _fillDefaultPool();
        MockRandomnessProvider replacement = new MockRandomnessProvider(address(this));
        vm.prank(owner);
        manager.setRandomnessProvider(address(replacement));
        randomness.fulfill(1, 4);
        assertEq(uint8(manager.getPool(poolId).status), uint8(OneDrawPoolManager.PoolStatus.COMPLETED));
    }

    function test_ExpiredPoolRefundsExactAccumulatedContributionWithoutAdminAction() public {
        uint256 poolId = _createDefaultPool();
        uint256 before = token.balanceOf(alice);
        _buy(alice, poolId, 2);
        _buy(alice, poolId, 3);
        vm.warp(manager.getPool(poolId).deadline);
        assertEq(manager.getRefundableAmount(poolId, alice), 5 * USDG);

        vm.prank(alice);
        manager.claimRefund(poolId);
        assertEq(token.balanceOf(alice), before);
        assertEq(manager.getContribution(poolId, alice), 0);
        assertEq(uint8(manager.getEffectiveStatus(poolId)), uint8(OneDrawPoolManager.PoolStatus.EXPIRED));

        vm.prank(alice);
        vm.expectRevert(OneDrawPoolManager.RefundUnavailable.selector);
        manager.claimRefund(poolId);
    }

    function test_OneWalletRefundDoesNotAffectAnother() public {
        uint256 poolId = _createDefaultPool();
        _buy(alice, poolId, 2);
        _buy(bob, poolId, 3);
        vm.warp(manager.getPool(poolId).deadline + 1);
        vm.prank(alice);
        manager.claimRefund(poolId);
        assertEq(manager.getContribution(poolId, bob), 3 * USDG);
        vm.prank(bob);
        manager.claimRefund(poolId);
        assertEq(manager.totalOutstandingLiabilities(), 0);
    }

    function test_FullOrCompletedPoolCannotRefundAndExpiredPoolCannotDraw() public {
        uint256 fullPool = _fillDefaultPool();
        vm.prank(alice);
        vm.expectRevert(OneDrawPoolManager.RefundUnavailable.selector);
        manager.claimRefund(fullPool);
        randomness.fulfill(1, 1);
        vm.prank(alice);
        vm.expectRevert(OneDrawPoolManager.RefundUnavailable.selector);
        manager.claimRefund(fullPool);

        uint256 expiredPool = _createDefaultPool();
        _buy(alice, expiredPool, 1);
        vm.warp(manager.getPool(expiredPool).deadline);
        manager.syncPoolState(expiredPool);
        vm.prank(address(randomness));
        vm.expectRevert(OneDrawPoolManager.InvalidRandomnessRequest.selector);
        manager.fulfillRandomness(999, 1);
    }

    function test_ZeroParticipantWaitingPoolHasNoDeadlineOrRefund() public {
        uint256 poolId = _createDefaultPool();
        vm.warp(block.timestamp + 365 days);
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        assertEq(pool.startTime, 0);
        assertEq(pool.deadline, 0);
        assertEq(uint8(manager.getEffectiveStatus(poolId)), uint8(OneDrawPoolManager.PoolStatus.WAITING));
        vm.prank(alice);
        vm.expectRevert(OneDrawPoolManager.RefundUnavailable.selector);
        manager.claimRefund(poolId);
    }

    function test_PauseBlocksCreationAndPurchasesButNotRefundsOrSettlement() public {
        uint256 refundablePool = _createDefaultPool();
        _buy(alice, refundablePool, 1);
        vm.warp(manager.getPool(refundablePool).deadline);

        vm.prank(owner);
        manager.pause();
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        manager.createPool(PRIZE, USDG, CAPACITY, DURATION, FEE);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        manager.buyTickets(refundablePool, 1);
        vm.prank(alice);
        manager.claimRefund(refundablePool);
    }

    function test_FeeVaultOnlyWithdrawsAccruedFeesAndUsesTwoStepOwnership() public {
        _fillDefaultPool();
        randomness.fulfill(1, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.withdraw(address(token), alice, FEE);

        vm.prank(owner);
        vm.expectRevert(FeeVault.InsufficientAccruedFees.selector);
        vault.withdraw(address(token), treasury, FEE + 1);

        vm.prank(owner);
        vault.withdraw(address(token), treasury, FEE);
        assertEq(token.balanceOf(treasury), FEE);
        assertEq(vault.accruedFees(address(token)), 0);
    }

    function test_TemplatePoolCanRolloverPermissionlesslyAfterCompletion() public {
        vm.startPrank(owner);
        uint256 templateId = manager.createPoolTemplate(PRIZE, USDG, CAPACITY, DURATION, FEE);
        uint256 firstPoolId = manager.createPoolFromTemplate(templateId);
        vm.stopPrank();

        _buy(alice, firstPoolId, CAPACITY);
        randomness.fulfill(1, 7);

        vm.prank(bob);
        uint256 nextPoolId = manager.rolloverPool(firstPoolId);
        assertEq(nextPoolId, firstPoolId + 1);
        assertEq(manager.successorPoolId(firstPoolId), nextPoolId);
        assertEq(manager.poolTemplateId(nextPoolId), templateId);

        OneDrawPoolManager.Pool memory nextPool = manager.getPool(nextPoolId);
        assertEq(nextPool.prizeAmount, PRIZE);
        assertEq(nextPool.ticketPrice, USDG);
        assertEq(nextPool.capacity, CAPACITY);
        assertEq(nextPool.duration, DURATION);
        assertEq(nextPool.protocolFee, FEE);
        assertEq(uint8(nextPool.status), uint8(OneDrawPoolManager.PoolStatus.WAITING));

        vm.expectRevert(OneDrawPoolManager.SuccessorAlreadyCreated.selector);
        manager.rolloverPool(firstPoolId);
    }

    function test_TemplatePoolCanRolloverAfterExpirationWithoutPriorSync() public {
        vm.startPrank(owner);
        uint256 templateId = manager.createPoolTemplate(PRIZE, USDG, CAPACITY, DURATION, FEE);
        uint256 firstPoolId = manager.createPoolFromTemplate(templateId);
        vm.stopPrank();
        _buy(alice, firstPoolId, 1);
        vm.warp(manager.getPool(firstPoolId).deadline);

        uint256 nextPoolId = manager.rolloverPool(firstPoolId);
        assertEq(uint8(manager.getPool(firstPoolId).status), uint8(OneDrawPoolManager.PoolStatus.EXPIRED));
        assertEq(manager.successorPoolId(firstPoolId), nextPoolId);
        assertEq(manager.getRefundableAmount(firstPoolId, alice), USDG);
    }

    function test_DisabledTemplateStopsRolloverWithoutAffectingClaims() public {
        vm.startPrank(owner);
        uint256 templateId = manager.createPoolTemplate(PRIZE, USDG, CAPACITY, DURATION, FEE);
        uint256 poolId = manager.createPoolFromTemplate(templateId);
        manager.setPoolTemplateEnabled(templateId, false);
        vm.stopPrank();
        _buy(alice, poolId, CAPACITY);
        randomness.fulfill(1, 0);

        vm.expectRevert(OneDrawPoolManager.PoolTemplateDisabled.selector);
        manager.rolloverPool(poolId);
        vm.prank(alice);
        manager.claimPrize(poolId);
        assertEq(manager.getClaimablePrize(poolId, alice), 0);
    }

    function test_ManualPoolCannotBeRolledOver() public {
        uint256 poolId = _fillDefaultPool();
        randomness.fulfill(1, 0);
        vm.expectRevert(OneDrawPoolManager.PoolHasNoTemplate.selector);
        manager.rolloverPool(poolId);
    }

    function testFuzz_ValidQuantityNeverExceedsCapacity(uint32 quantity) public {
        quantity = uint32(bound(quantity, 1, CAPACITY));
        uint256 poolId = _createDefaultPool();
        _buy(alice, poolId, quantity);
        assertLe(manager.getPool(poolId).ticketsSold, CAPACITY);
        assertEq(manager.getContribution(poolId, alice), uint256(quantity) * USDG);
    }

    function testFuzz_RandomValueAlwaysSelectsValidSoldTicket(uint256 randomValue) public {
        uint256 poolId = _fillDefaultPool();
        randomness.fulfill(1, randomValue);
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        assertLt(pool.winningTicket, pool.capacity);
        assertEq(pool.winner, manager.getTicketOwner(poolId, pool.winningTicket));
    }

    function testFuzz_EconomicsReconcile(uint128 ticketPrice, uint32 capacity, uint128 prize) public {
        ticketPrice = uint128(bound(ticketPrice, 1, type(uint64).max));
        capacity = uint32(bound(capacity, 2, 1_000));
        uint256 collection = uint256(ticketPrice) * capacity;
        prize = uint128(bound(prize, 1, collection));
        uint128 fee = uint128(collection - prize);

        vm.prank(owner);
        uint256 poolId = manager.createPool(prize, ticketPrice, capacity, DURATION, fee);
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        assertEq(uint256(pool.ticketPrice) * pool.capacity, uint256(pool.prizeAmount) + pool.protocolFee);
    }

    function _createDefaultPool() internal returns (uint256) {
        vm.prank(owner);
        return manager.createPool(PRIZE, USDG, CAPACITY, DURATION, FEE);
    }

    function _fillDefaultPool() internal returns (uint256 poolId) {
        poolId = _createDefaultPool();
        _buy(alice, poolId, CAPACITY);
    }

    function _buy(address buyer, uint256 poolId, uint32 quantity) internal {
        vm.prank(buyer);
        manager.buyTickets(poolId, quantity);
    }

    function _fundAndApprove(address wallet) internal {
        token.mint(wallet, 1_000_000 * USDG);
        vm.prank(wallet);
        token.approve(address(manager), type(uint256).max);
    }
}
