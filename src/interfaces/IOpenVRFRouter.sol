// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface used by ONEDRAW's OpenVRF adapter.
interface IOpenVRFRouter {
    function requestFee() external view returns (uint256);

    function requestRandomness(uint32 callbackGasLimit) external payable returns (uint256 requestId);
}

interface IOpenVRFConsumer {
    function rawFulfillRandomness(uint256 requestId, uint256 randomWord) external;
}
