// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IEqualizerPair {
    function getReserves() external view returns (uint[] memory);
}