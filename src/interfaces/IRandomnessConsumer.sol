// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRandomnessConsumer {
    function fulfillRandomness(uint256 requestId, uint256 randomValue) external;
}
