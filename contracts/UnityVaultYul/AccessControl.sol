// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.19;

/**
@notice Based on OZ's Ownable.sol v4 w/ added strategist and harvester controllers. 
        Includes Re-entrancy guard
        Yul optimized
 */

abstract contract AccessControl {
   
    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP STORAGE
    //////////////////////////////////////////////////////////////*/

    address public strategist;
    address public treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public multisig = address(0x3522f55fE566420f14f89bd46820EC66D3A5eb7c);
    address public harvester = address(0xDFAA88D5d068370689b082D34d7B546CbF393bA9);
    uint64 public harvestOnDeposit = 1; 
    uint64 private notEntered = 1;
    uint64 private entered = 2;
    uint64 private status;

    //Owner Slot
    bytes32 internal constant _OWNER_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927;

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
        assembly {
            //Assign owner
            let ownerSlot:= _OWNER_SLOT
            let msig:= sload(multisig.slot)
            let newOwner := shr(96, shl(96, msig)) // Clean the upper 96 bits.
            log3(0, 0, 0x8be0079c, 0, msig) // Emit event
            sstore(ownerSlot, or(msig, shl(255, iszero(msig))))

            //Assign status  
            let currentSlotValue := sload(status.slot)
            let statusMask := shl(64, 0xFFFFFFFFFFFFFFFF) // Mask for the fourth uint64 in the slot.
            let newStatusValue := or(and(currentSlotValue, not(statusMask)), shl(192, 1)) // Set only status to 1.
            sstore(status.slot, newStatusValue)
        }            
    }

    /*//////////////////////////////////////////////////////////////
                             OWNERSHIP LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external virtual onlyOwner {
        assembly {
            let ownerSlot:= _OWNER_SLOT
            newOwner := shr(96, shl(96, newOwner))
            log3(0, 0, 0x8be0079c, sload(_OWNER_SLOT), newOwner)
            sstore(ownerSlot, or(newOwner, shl(255, iszero(newOwner))))
            }
    }

    function getOwner() external virtual view returns(address owner){
        assembly{
            owner:= sload(_OWNER_SLOT)
        } 
    }

    function setStrategist(address _newStrategist) external virtual {
        assembly{
            if iszero(eq(caller(), sload(strategist.slot))){
                mstore(0x00, 0x62c774da) //NotStrategist
                revert(0x1c, 0x04)
            }
            log3(0, 0, 0x10b9e495, sload(strategist.slot), _newStrategist )
            sstore(strategist.slot, _newStrategist)
        }
    }

    function setTreasury(address _newTreasury) external virtual onlyOwner {
        assembly{
            sstore(treasury.slot, _newTreasury)
            mstore(0x00, _newTreasury)
            log1(0x00, 0x20, 0x1504e68f) // SetHarvester log

        }
    }

    function setHarvester(address _newHarvester) external virtual onlyAdmin {
        assembly{
            sstore(harvester.slot, _newHarvester)
            mstore(0x20, _newHarvester)
            log1(0x00, 0x20, 0x1504e68f) // SetHarvester log
        }

    }
    
    function checkOwner() internal virtual {
        assembly{
            if iszero(eq(caller(), sload(_OWNER_SLOT))){
                mstore(0x00, 0xa31aad1e) // NoAuth error
                revert(0x1c, 0x04)
            }
        }
    }

    function checkAdmin() internal virtual {
        assembly {
            // Load the owner and strategist addresses from their respective slots.
            let ownerAddr := sload(_OWNER_SLOT)
            let strategistAddr := sload(strategist.slot)
        
            let callerAddr := caller()
        
            // Check if the caller is not the owner and not the strategist.
            let isOwner := eq(callerAddr, ownerAddr)
            let isStrategist := eq(callerAddr, strategistAddr)
        
            // If the caller is neither the owner nor the strategist, revert.
            if iszero(or(isOwner, isStrategist)) {
                mstore(0x00, 0xa31aad1e) // NoAuth error
                revert(0x1c, 0x04)
            }
        }   
    }

    function checkHarvesters() internal virtual{
        assembly {
            let ownerAddr := sload(_OWNER_SLOT)
            let strategistAddr := sload(strategist.slot)
            let harvesterAddr := sload(harvester.slot)
        
            let callerAddr := caller()

            let isOwner := eq(callerAddr, ownerAddr)
            let isStrategist := eq(callerAddr, strategistAddr)
            let isHarvester := eq(callerAddr, harvesterAddr)

            if iszero(or(isOwner, or(isStrategist, isHarvester))) {
                mstore(0x00, 0xa31aad1e) // NoAuth error
                revert(0x1c, 0x04)
            }
        }  
    }

    function _nonReentrantBefore() private {
        assembly {
            let slotValue := sload(status.slot)

            // Isolate 'entered' value (third uint64 in the slot) by shifting right by 128 bits.
            let enteredVal := shr(128, slotValue)
        
            // Isolate 'status' value (fourth uint64 in the slot) by shifting right by 192 bits.
            let statusVal := shr(192, slotValue)
        
            // Check if 'status' is equal to 'entered'.
            if eq(statusVal, enteredVal) {
                mstore(0x00, 0xa31aad1e) // NoAuth error
                revert(0x1c, 0x04)
            }
        
            // Create a mask to clear 'status'.
            let statusMask := shl(192, 0xFFFFFFFFFFFFFFFF)
        
            // Clear the 'status' part and combine with the rest of the slot.
            slotValue := and(slotValue, not(statusMask))
        
            // Set the 'status' part to 'enteredVal' by shifting 'enteredVal' left by 192 bits.
            slotValue := or(slotValue, shl(192, enteredVal))
        
            // Store the updated value back to the storage slot.
            sstore(status.slot, slotValue)
        }
    }

    function _nonReentrantAfter() private {
        assembly{
            let currentSlotVal := sload(status.slot)

            // Mask for the fourth uint64 in the slot, which is the last 64 bits of the 256-bit slot.
            let statusMask := shl(192, 0xFFFFFFFFFFFFFFFF)

            // Clear status and set it to 1.
            let newStatusVal := or(and(currentSlotVal, not(statusMask)), shl(192, 1))
            sstore(status.slot, newStatusVal)
        }
    }

}
