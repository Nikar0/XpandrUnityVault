// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IEqualizerPair {
    function blockTimestampLast() external view returns (uint);
    function sample(address tokenIn, uint amountIn, uint points, uint window) external view returns (uint[] memory);
}
