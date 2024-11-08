// SPDX-License-Identifier: MIT
// This file has parts of the infrastructure separated out into individual "fake" contracts
// forge build --sizes lets you know where the contract size is going (approx)
// They also serve to list the code needed to implement the facility
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

import {Ownable} from "@solady/auth/Ownable.sol";
import {OwnableRoles} from "@solady/auth/OwnableRoles.sol";

import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {BaoOwnableTransferrable} from "@bao/BaoOwnableTransferrable.sol";
import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {BaoOwnableTransferrableRoles} from "@bao/BaoOwnableTransferrableRoles.sol";

import {TokenHolder} from "@bao/TokenHolder.sol";

/*/////
UUPSUpgradeable
////////////////////////////////////*/

contract _UUPSUpgradeable is UUPSUpgradeable {
    // function initialize() external {
    //     __UUPSUpgradeable_init();
    // }
    function _authorizeUpgrade(address newImplementation) internal virtual override {}
}

// UUPSUpgradeable with the inevitable intializable
contract _Initializable_UUPSUpGradeable is Initializable, UUPSUpgradeable {
    // function initialize() external initializer {
    //     __UUPSUpgradeable_init();
    // }
    function _authorizeUpgrade(address newImplementation) internal virtual override {}
}

/*/////
Solady auth
////////////////////////////////////*/
contract _SoladyOwnable is Ownable {
    // function initialize(address owner) external {
    //     _initializeOwner(owner);
    // }
}

contract _SoladyOwnableRoles is OwnableRoles {
    // function initialize(address owner) external {
    //     _initializeOwner(owner);
    // }
}

/*/////
Bao Ownable + Roles
////////////////////////////////////*/

contract _BaoOwnable_ is BaoOwnable {
    // function initialize(address owner) external {
    //     _initializeOwner(owner);
    // }
}

contract _BaoOwnableRoles_ is BaoOwnableRoles {
    // function initialize(address owner) external {
    //     _initializeOwner(owner);
    // }
}

contract _BaoOwnableTransferrable_ is BaoOwnableTransferrable {
    // function initialize(address owner) external {
    //     _initializeOwner(owner);
    // }
}

contract _BaoOwnableTransferrableRoles_ is BaoOwnableTransferrableRoles {
    // function initialize(address owner) external {
    //     _initializeOwner(owner);
    // }
}

/*/////
OZ Ownable + Access control
////////////////////////////////////*/

contract _OZOwnable is OwnableUpgradeable {
    // function initialize(address owner) external {
    //     __Ownable_init(owner);
    // }
}

contract _OZOwnable2Step is Ownable2StepUpgradeable {
    // function initialize() external {
    //     __Ownable2Step_init();
    // }
}

contract _OZAccessControl is AccessControlUpgradeable {
    // function initialize() external {
    //     __AccessControl_init();
    // }
}

contract _OZDefaultAdminRules is AccessControlDefaultAdminRulesUpgradeable {
    // function initialize(uint48 delay, address owner) external {
    //     __AccessControlDefaultAdminRules_init(delay, owner);
    // }
}
