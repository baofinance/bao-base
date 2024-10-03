// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Ownable } from "@solady/auth/Ownable.sol";
import { IOwnable } from "@bao/interfaces/IOwnable.sol";

contract SampleOwnable is Ownable /* IOwnable, */, Initializable {
    /// @dev initialiser function - replaces the constructor - see SampleUpgradeable.sol
    function initialize(address owner) external initializer {
        _initializeOwner(owner);
    }

    /// @dev function only executable by `owner`
    function onlyOwnerSampleFunction() public onlyOwner {}
}
