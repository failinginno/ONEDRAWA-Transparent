// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FeeVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ManagerAlreadyConfigured();
    error NotManager();
    error InvalidAccrual();
    error InsufficientAccruedFees();

    address public manager;
    mapping(address token => uint256 amount) public accruedFees;

    event ManagerConfigured(address indexed manager);
    event FeeAccrued(address indexed token, uint256 amount);
    event FeeWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function configureManager(address manager_) external onlyOwner {
        if (manager_ == address(0)) revert ZeroAddress();
        if (manager != address(0)) revert ManagerAlreadyConfigured();
        manager = manager_;
        emit ManagerConfigured(manager_);
    }

    function recordAccrual(address token, uint256 amount) external {
        if (msg.sender != manager) revert NotManager();
        uint256 nextAccrued = accruedFees[token] + amount;
        if (IERC20(token).balanceOf(address(this)) < nextAccrued) revert InvalidAccrual();
        accruedFees[token] = nextAccrued;
        emit FeeAccrued(token, amount);
    }

    function withdraw(address token, address recipient, uint256 amount) external nonReentrant onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 accrued = accruedFees[token];
        if (amount > accrued) revert InsufficientAccruedFees();
        accruedFees[token] = accrued - amount;
        IERC20(token).safeTransfer(recipient, amount);
        emit FeeWithdrawn(token, recipient, amount);
    }
}
