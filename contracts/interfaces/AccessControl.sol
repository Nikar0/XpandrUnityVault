// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.19;

/**
@notice Based on solmate's Owned.sol with added access control for an operator & error code + if instead of requires.
 */

 error NoAuth();
 error NotStrategist();

abstract contract AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed user, address indexed newOwner);
    event SetStrategist(address indexed user, address indexed newStrategist);
    event SetHarvester(address indexed user, address indexed newHarvester);

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public strategist;
    address public constant treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public constant devMultiSig = address(0x3522f55fE566420f14f89bd46820EC66D3A5eb7c);
    address internal harvester = address(0xDFAA88D5d068370689b082D34d7B546CbF393bA9);

    modifier onlyOwner() virtual {
        checkOwner();
        _;
    }

    modifier onlyAdmin() virtual {
        checkAdmin();
        _;
    }

    modifier harvesters() virtual {
        checkHarvesters();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = devMultiSig;
        emit OwnershipTransferred(address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                             OWNERSHIP LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external virtual onlyOwner {
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }

    function setStrategist(address _newStrategist) external virtual {
        if(msg.sender != strategist){revert NotStrategist();}
        strategist = _newStrategist;
        emit SetStrategist(msg.sender, strategist);
    }

    function setHarvester(address _newHarvester) external virtual onlyAdmin {
        harvester = _newHarvester;
        emit SetHarvester(msg.sender, _newHarvester);
    }

    function checkOwner() internal virtual {
        if(tx.origin != owner){revert NoAuth();}
    }

    function checkAdmin() internal virtual {
        if(tx.origin != owner || tx.origin != strategist){revert NoAuth();}
    }

    function checkHarvesters() internal virtual{
        if(tx.origin != harvester || tx.origin != strategist || tx.origin != owner){revert NoAuth();}
    }

}
