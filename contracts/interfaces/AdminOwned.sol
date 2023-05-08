// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0 <=0.9.0;

/**
@notice Based on solmate's Owned.sol with added access control for an operator & error code + if instead of requires.
 */

 error NoAuth();

abstract contract AdminOwned {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed user, address indexed newOwner);
    event SetStrategist(address indexed user, address indexed newStrategist);

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public strategist;

    modifier onlyOwner() virtual {
        checkOwner();
        _;
    }

    modifier onlyAdmin() virtual {
        checkAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = msg.sender;
        strategist = msg.sender;

        emit OwnershipTransferred(address(0), owner);
        emit SetStrategist(address(0), strategist);
    }

    /*//////////////////////////////////////////////////////////////
                             OWNERSHIP LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external virtual onlyOwner {
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }

    function setStrategist(address _newStrategist) external virtual onlyOwner {
        strategist = _newStrategist;
        emit SetStrategist(msg.sender, _newStrategist);
    }

    function checkOwner() internal virtual {
        if(msg.sender != owner){revert NoAuth();}
    }

    
    function checkAdmin() internal virtual {
        if(msg.sender != owner || msg.sender != strategist){revert NoAuth();}
    }

}
