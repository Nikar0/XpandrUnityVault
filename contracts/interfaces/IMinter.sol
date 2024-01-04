// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IMinter {
    function mint(address, uint) external;
}