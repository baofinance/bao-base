// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// A family whose middle version names no predecessor, as after parking v1: only the latest version must
// name one, so this passes.

contract MiddleUnannotated_v1 is Initializable {}

contract MiddleUnannotated_v2 is Initializable {}

/// @custom:oz-upgrades-from test/fixtures/upgrade-references/MiddleUnannotated.sol:MiddleUnannotated_v2
contract MiddleUnannotated_v3 is Initializable {}
