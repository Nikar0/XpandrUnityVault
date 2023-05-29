// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IEqualizerPair {
    function getReserves() external view returns (uint _reserve0, uint _reserve1, uint _blockTimestampLast);
    function sample(address tokenIn, uint amountIn, uint points, uint window) external view returns (uint[] memory);
    function getAmountOut(uint amountIn, address tokenIn) external view returns (uint);
}