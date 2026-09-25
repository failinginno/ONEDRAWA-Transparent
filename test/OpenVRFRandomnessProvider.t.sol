// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OpenVRFRandomnessProvider} from "../src/OpenVRFRandomnessProvider.sol";
import {IOpenVRFConsumer} from "../src/interfaces/IOpenVRFRouter.sol";
import {OneDrawPoolManager} from "../src/OneDrawPoolManager.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

contract MockOpenVRFRouter {
    uint256 public requestFee;
    uint256 public nextRequestId = 1;
    mapping(uint256 => address) public consumers;
    mapping(uint256 => uint32) public callbackLimits;

    function setRequestFee(uint256 fee) external {
        requestFee = fee;
    }

    function requestRandomness(uint32 callbackGasLimit) external payable returns (uint256 requestId) {
        require(msg.value == requestFee, "fee");
        requestId = nextRequestId++;
        consumers[requestId] = msg.sender;
        callbackLimits[requestId] = callbackGasLimit;
    }

    function fulfill(uint256 requestId, uint256 word) external {
        IOpenVRFConsumer(consumers[requestId]).rawFulfillRandomness(requestId, word);
    }
}

contract RecordingManager {
    OpenVRFRandomnessProvider public provider;
    bool public shouldRevert;
    uint256 public deliveredRequestId;
    uint256 public deliveredWord;

    function setProvider(OpenVRFRandomnessProvider provider_) external {
        provider = provider_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function request(uint256 poolId) external returns (uint256) {
        return provider.requestRandomness(poolId);
    }

    function fulfillRandomness(uint256 requestId, uint256 randomWord) external {
        require(msg.sender == address(provider), "provider");
        require(!shouldRevert, "delivery blocked");
        deliveredRequestId = requestId;
        deliveredWord = randomWord;
    }
}

contract OpenVRFRandomnessProviderTest is Test {
    MockOpenVRFRouter internal router;
    RecordingManager internal manager;
    OpenVRFRandomnessProvider internal provider;

    function setUp() public {
        router = new MockOpenVRFRouter();
        manager = new RecordingManager();
        provider = new OpenVRFRandomnessProvider(address(this), address(manager), address(router), 500_000);
        manager.setProvider(provider);
    }

    function test_RequestPaysExactRouterFeeAndBindsPool() public {
        router.setRequestFee(0.01 ether);
        vm.deal(address(provider), 0.02 ether);

        uint256 requestId = manager.request(42);

        (uint256 poolId, uint256 word, bool received, bool delivered) = provider.requests(requestId);
        assertEq(poolId, 42);
        assertEq(word, 0);
        assertFalse(received);
        assertFalse(delivered);
        assertEq(address(router).balance, 0.01 ether);
        assertEq(router.callbackLimits(requestId), 500_000);
    }

    function test_OnlyManagerCanRequest() public {
        vm.expectRevert(OpenVRFRandomnessProvider.UnauthorizedManager.selector);
        provider.requestRandomness(1);
    }

    function test_RequestRevertsWhenAdapterCannotPayFee() public {
        router.setRequestFee(1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(OpenVRFRandomnessProvider.InsufficientRequestFunds.selector, 1 ether, 0)
        );
        manager.request(1);
    }

    function test_OnlyRouterCanFulfill() public {
        manager.request(7);
        vm.expectRevert(OpenVRFRandomnessProvider.UnauthorizedRouter.selector);
        provider.rawFulfillRandomness(1, 123);
    }

    function test_VerifiedWordIsDeliveredAndCannotBeReplayed() public {
        uint256 requestId = manager.request(7);
        router.fulfill(requestId, 123);

        (uint256 poolId, uint256 word, bool received, bool delivered) = provider.requests(requestId);
        assertEq(poolId, 7);
        assertEq(word, 123);
        assertTrue(received);
        assertTrue(delivered);
        assertEq(manager.deliveredRequestId(), requestId);
        assertEq(manager.deliveredWord(), 123);

        vm.expectRevert(OpenVRFRandomnessProvider.RandomnessAlreadyReceived.selector);
        router.fulfill(requestId, 456);
    }

    function test_FailedManagerDeliveryKeepsSameWordForPermissionlessRetry() public {
        manager.setShouldRevert(true);
        uint256 requestId = manager.request(9);
        router.fulfill(requestId, 777);

        (, uint256 storedWord, bool received, bool delivered) = provider.requests(requestId);
        assertEq(storedWord, 777);
        assertTrue(received);
        assertFalse(delivered);

        manager.setShouldRevert(false);
        vm.prank(address(0xBEEF));
        provider.retryDelivery(requestId);

        (,,, delivered) = provider.requests(requestId);
        assertTrue(delivered);
        assertEq(manager.deliveredWord(), 777);
    }

    function test_CallbackGasLimitAppliesOnlyToFutureRequests() public {
        uint256 first = manager.request(1);
        provider.setCallbackGasLimit(750_000);
        uint256 second = manager.request(2);

        assertEq(router.callbackLimits(first), 500_000);
        assertEq(router.callbackLimits(second), 750_000);
    }

    function test_CallbackGasLimitBounds() public {
        vm.expectRevert(OpenVRFRandomnessProvider.InvalidCallbackGasLimit.selector);
        provider.setCallbackGasLimit(24_999);
        vm.expectRevert(OpenVRFRandomnessProvider.InvalidCallbackGasLimit.selector);
        provider.setCallbackGasLimit(1_000_001);
    }

    function test_OwnerCanWithdrawUnusedNativeBalance() public {
        vm.deal(address(provider), 1 ether);
        uint256 beforeBalance = address(this).balance;
        provider.withdrawNative(payable(address(this)), 0.4 ether);
        assertEq(address(this).balance, beforeBalance + 0.4 ether);
        assertEq(address(provider).balance, 0.6 ether);
    }

    function test_IntegrationSettlesRealPoolManagerAndPreservesPullClaim() public {
        MockUSDG token = new MockUSDG();
        FeeVault vault = new FeeVault(address(this));
        OneDrawPoolManager poolManager =
            new OneDrawPoolManager(address(this), address(token), address(vault), address(router));
        OpenVRFRandomnessProvider adapter =
            new OpenVRFRandomnessProvider(address(this), address(poolManager), address(router), 500_000);
        poolManager.setRandomnessProvider(address(adapter));
        vault.configureManager(address(poolManager));

        uint256 poolId = poolManager.createPool(2_000_000, 1_000_000, 3, 180, 1_000_000);
        address alice = makeAddr("integration-alice");
        address bob = makeAddr("integration-bob");
        token.mint(alice, 1_000_000);
        token.mint(bob, 2_000_000);
        vm.prank(alice);
        token.approve(address(poolManager), type(uint256).max);
        vm.prank(bob);
        token.approve(address(poolManager), type(uint256).max);
        vm.prank(alice);
        poolManager.buyTickets(poolId, 1);
        vm.prank(bob);
        poolManager.buyTickets(poolId, 2);

        uint256 requestId = poolManager.getPool(poolId).randomnessRequestId;
        router.fulfill(requestId, 0);

        OneDrawPoolManager.Pool memory settled = poolManager.getPool(poolId);
        assertEq(uint8(settled.status), uint8(OneDrawPoolManager.PoolStatus.COMPLETED));
        assertEq(settled.winner, alice);
        assertEq(token.balanceOf(alice), 0);
        assertEq(poolManager.getClaimablePrize(poolId, alice), 2_000_000);

        vm.prank(alice);
        poolManager.claimPrize(poolId);
        assertEq(token.balanceOf(alice), 2_000_000);
        assertEq(token.balanceOf(address(vault)), 1_000_000);
    }

    receive() external payable {}
}
