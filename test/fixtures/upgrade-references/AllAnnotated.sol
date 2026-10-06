// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// A family where every version after the first names its predecessor: an older version may keep its
// annotation, so this passes.

contract AllAnnotated_v1 is Initializable {}

/// @custom:oz-upgrades-from test/fixtures/upgrade-references/AllAnnotated.sol:AllAnnotated_v1
contract AllAnnotated_v2 is Initializable {}

/// @custom:oz-upgrades-from test/fixtures/upgrade-references/AllAnnotated.sol:AllAnnotated_v2
contract AllAnnotated_v3 is Initializable {}
