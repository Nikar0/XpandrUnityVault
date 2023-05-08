// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

/// @notice Gas optimized reentrancy protection for smart contracts.

error Reentrancy();

abstract contract ReentrancyGuard {
    uint256 private locked = 1;

    modifier nonReentrant() virtual {
        if(locked != 1){revert Reentrancy();}

        locked = 2;

        _;

        locked = 1;
    }
}
