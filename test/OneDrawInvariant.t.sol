// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {OneDrawPoolManager} from "../src/OneDrawPoolManager.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockRandomnessProvider} from "../src/mocks/MockRandomnessProvider.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

contract OneDrawHandler is Test {
    OneDrawPoolManager public immutable manager;
    MockRandomnessProvider public immutable randomness;
    address[] public actors;
    uint256 public immutable poolId;

    constructor(
        OneDrawPoolManager manager_,
        MockRandomnessProvider randomness_,
        address[] memory actors_,
        uint256 poolId_
    ) {
        manager = manager_;
        randomness = randomness_;
        actors = actors_;
        poolId = poolId_;
    }

    function buy(uint256 actorSeed, uint32 quantity) external {
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        if (pool.status != OneDrawPoolManager.PoolStatus.WAITING && pool.status != OneDrawPoolManager.PoolStatus.LIVE) {
            return;
        }
        if (pool.deadline != 0 && block.timestamp >= pool.deadline) return;
        uint32 remaining = pool.capacity - pool.ticketsSold;
        if (remaining == 0) return;
        quantity = uint32(bound(quantity, 1, remaining));
        vm.prank(actors[actorSeed % actors.length]);
        manager.buyTickets(poolId, quantity);
    }

    function advanceTime(uint64 secondsForward) external {
        secondsForward = uint64(bound(secondsForward, 0, 600));
        vm.warp(block.timestamp + secondsForward);
    }

    function refund(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (manager.getRefundableAmount(poolId, actor) == 0) return;
        vm.prank(actor);
        manager.claimRefund(poolId);
    }

    function fulfill(uint256 randomValue) external {
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        if (pool.status != OneDrawPoolManager.PoolStatus.DRAWING) return;
        randomness.fulfill(pool.randomnessRequestId, randomValue);
    }
}

contract OneDrawInvariantTest is StdInvariant, Test {
    uint128 internal constant USDG = 1_000_000;
    address internal owner = makeAddr("owner");

    MockUSDG internal token;
    FeeVault internal vault;
    MockRandomnessProvider internal randomness;
    OneDrawPoolManager internal manager;
    OneDrawHandler internal handler;
    uint256 internal poolId;

    function setUp() public {
        token = new MockUSDG();
        vault = new FeeVault(owner);
        randomness = new MockRandomnessProvider(address(this));
        manager = new OneDrawPoolManager(owner, address(token), address(vault), address(randomness));
        vm.prank(owner);
        vault.configureManager(address(manager));
        vm.prank(owner);
        poolId = manager.createPool(10 * USDG, USDG, 11, 180, USDG);

        address[] memory actors = new address[](4);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            token.mint(actors[i], 1_000 * USDG);
            vm.prank(actors[i]);
            token.approve(address(manager), type(uint256).max);
        }

        handler = new OneDrawHandler(manager, randomness, actors, poolId);
        randomness.transferOwnership(address(handler));
        targetContract(address(handler));
    }

    function invariant_TicketsNeverExceedCapacity() public view {
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        assertLe(pool.ticketsSold, pool.capacity);
    }

    function invariant_ContractBalanceCoversAndEqualsRecordedLiabilities() public view {
        assertEq(token.balanceOf(address(manager)), manager.totalOutstandingLiabilities());
    }

    function invariant_FeeVaultAccountingNeverExceedsItsBalance() public view {
        assertLe(vault.accruedFees(address(token)), token.balanceOf(address(vault)));
    }

    function invariant_CompletedPoolHasExactlyOneValidWinner() public view {
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        if (pool.status == OneDrawPoolManager.PoolStatus.COMPLETED) {
            assertTrue(pool.winner != address(0));
            assertLt(pool.winningTicket, pool.capacity);
            assertEq(pool.winner, manager.getTicketOwner(poolId, pool.winningTicket));
            assertEq(manager.totalOutstandingLiabilities(), pool.prizeAmount);
        }
    }

    function invariant_IncompleteExpiredPoolNeverHasWinner() public view {
        OneDrawPoolManager.Pool memory pool = manager.getPool(poolId);
        if (manager.getEffectiveStatus(poolId) == OneDrawPoolManager.PoolStatus.EXPIRED) {
            assertLt(pool.ticketsSold, pool.capacity);
            assertEq(pool.winner, address(0));
        }
    }
}
