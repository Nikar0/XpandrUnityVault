// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IveEqual {
    function deposit_for(uint _tokenId, uint _value) external;
    function ownerOf(uint id) external returns (address);
}