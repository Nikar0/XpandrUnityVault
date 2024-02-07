// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (security/Pausable.sol)

pragma solidity 0.8.19;

/**
@notice - Modified version of OZ's Pausable.sol, using uint instead of bool
          Yul optimized
 */

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */


abstract contract Pauser {
  
    uint internal _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor() {
        assembly{
            sstore(_paused.slot, 1)
        }
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        _requirePaused();
        _;
    }

    /**
     * @dev Returns 2 if the contract is paused, and 1 otherwise.
     */
    function paused() public view virtual returns (uint isPaused) {
        assembly{
            isPaused:= sload(_paused.slot)
        }
    }

    /**
     * @dev Throws if the contract is paused.
     */
    function _requireNotPaused() internal view virtual {
        //if(paused() != 1){revert Paused();}
        assembly{
            if iszero(eq(sload(_paused.slot), 1)){
                mstore(0x00,  0x9e87fac8) //Paused error
                revert(0x1c, 0x04)
            }
        }
    }

    /**
     * @dev Throws if the contract is not paused.
     */
    function _requirePaused() internal view virtual {
        //if(paused() != 2){revert NotPaused();}
         assembly{
            if iszero(eq(sload(_paused.slot), 2)){
                mstore(0x00, 0x6cd60201) //NotPaused error
                revert(0x1c, 0x04)
            }
        }
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        assembly{
            sstore(_paused.slot, 2)
            mstore(0x20, caller())
            log1(0x20, 0x20, 0x09472e78) //WasPaused event
        }
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        assembly{
            sstore(_paused.slot, 1)
            mstore(0x20, caller())
            log1(0x20, 0x20, 0x09472e78) //Unpaused event
        }
    }
}
