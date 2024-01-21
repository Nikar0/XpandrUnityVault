// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.19;

/**
@notice Based on OZ's Ownable.sol with added access control for an strategist, harvester & error code + error codes instead of requires.
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
    event SetTreasury(address indexed newTreasury);

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public strategist;
    address public treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public constant multisig = address(0x3522f55fE566420f14f89bd46820EC66D3A5eb7c);
    address internal harvester = address(0xDFAA88D5d068370689b082D34d7B546CbF393bA9);
    uint64 private constant notEntered = 1;
    uint64 private constant entered = 2;
    uint128 private status;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/


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

    modifier nonReentrant() virtual {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }


    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = multisig;
        status = notEntered;
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

    function setTreasury(address _newTreasury) external virtual onlyOwner {
        treasury = _newTreasury;
        emit SetTreasury(_newTreasury);
    }

    function setHarvester(address _newHarvester) external virtual onlyAdmin {
        harvester = _newHarvester;
        emit SetHarvester(msg.sender, _newHarvester);
    }
    

    function checkOwner() internal virtual {
        if(msg.sender != owner){revert NoAuth();}
    }

    function checkAdmin() internal virtual {
        if(msg.sender != owner && msg.sender != strategist){revert NoAuth();}
    }

    function checkHarvesters() internal virtual{
        if(msg.sender != harvester && msg.sender != strategist && msg.sender != owner){revert NoAuth();}
    }

    function _nonReentrantBefore() private {
        if (status == entered) {revert NoAuth();}
        status = entered;
    }

    function _nonReentrantAfter() private {
       status = notEntered;
    }

}
