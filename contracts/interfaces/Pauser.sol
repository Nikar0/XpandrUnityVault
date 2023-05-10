// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (security/Pausable.sol)

pragma solidity >=0.8.0 <=0.9.0;

import "@openzeppelin/contracts/utils/Context.sol";

/**
@notice - Modified version of OZ's Pausable.sol, using uint instead of bool &error codes w/ Ifs 
          instead of requires w/ strings for cheaper gas costs
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

error NotPaused();
error Paused();

abstract contract Pauser is Context {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event WasPaused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    uint8 public _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor() {
        _paused = 0;
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
     * @dev Returns 1 if the contract is paused, and 0 otherwise.
     */
    function paused() public view virtual returns (uint8) {
        return _paused;
    }

    /**
     * @dev Throws if the contract is paused.
     */
    function _requireNotPaused() internal view virtual {
        //require(paused() != 0, "Pausable: paused");
        if(paused() == 0){revert Paused();}
    }

    /**
     * @dev Throws if the contract is not paused.
     */
    function _requirePaused() internal view virtual {
        //require(paused() == 1, "Pausable: not paused");
        if(paused() != 0){revert NotPaused();}

    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = 1;
        emit WasPaused(msg.sender);
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = 0;
        emit Unpaused(msg.sender);
    }
}
