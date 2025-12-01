// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

contract ERC20WithData is MintableBurnableERC20_v1 {
    address public immutable ADDR;

    struct StateStorage {
        address addr;
        uint aUint;
    }

    // keccak256("bao.mockimplementationwithstate.storage") - 1
    bytes32 private constant MOCKIMPLEMENTATIONWITHSTATE_STORAGE_SLOT =
        0x6e1b6c6e2e20e671e7e55ce49963cf343577b6c7d429f775d390d05f9b0a7b1b;

    // EIP-7201: Storage accessor (Proxy Pattern: EIP-7201)
    function _getStateStorage() internal pure returns (StateStorage storage $) {
        assembly {
            $.slot := MOCKIMPLEMENTATIONWITHSTATE_STORAGE_SLOT
        }
    }

    constructor(address addr) {
        ADDR = addr;
    }

    function initialize(address owner_, string memory name_, string memory symbol_, uint256 aUint) public {
        super.initialize(owner_, name_, symbol_);
        setUint(aUint);
    }

    function setAddress(address newAddr) public {
        StateStorage storage $ = _getStateStorage();
        $.addr = newAddr;
    }

    function setUint(uint256 newUint) public {
        StateStorage storage $ = _getStateStorage();
        $.aUint = newUint;
    }
}
