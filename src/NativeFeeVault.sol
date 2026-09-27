// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Isolated custody for protocol fees collected by the native ETH pool manager.
contract NativeFeeVault is Ownable2Step, ReentrancyGuard {
    error ZeroAddress();
    error ManagerAlreadyConfigured();
    error NotManager();
    error InvalidAccrual();
    error InsufficientAccruedFees();
    error NativeTransferFailed();

    address public manager;
    uint256 public accruedFees;

    event ManagerConfigured(address indexed manager);
    event FeeAccrued(uint256 amount);
    event FeeWithdrawn(address indexed recipient, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function configureManager(address manager_) external onlyOwner {
        if (manager_ == address(0)) revert ZeroAddress();
        if (manager != address(0)) revert ManagerAlreadyConfigured();
        manager = manager_;
        emit ManagerConfigured(manager_);
    }

    function recordAccrual() external payable {
        if (msg.sender != manager) revert NotManager();
        if (msg.value == 0) revert InvalidAccrual();
        accruedFees += msg.value;
        emit FeeAccrued(msg.value);
    }

    function withdraw(address payable recipient, uint256 amount) external nonReentrant onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount > accruedFees) revert InsufficientAccruedFees();
        accruedFees -= amount;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
        emit FeeWithdrawn(recipient, amount);
    }
}

