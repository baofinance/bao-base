// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// A family whose middle version carries both upgrade annotations: a version takes exactly one, whichever
// version it is, so this fails.

contract BothMiddle_v1 is Initializable {}

/// @custom:oz-upgrades-from test/fixtures/upgrade-references/BothMiddle.sol:BothMiddle_v1
/// @custom:bao-upgrades-from test/fixtures/upgrade-references/BothMiddle.sol:BothMiddle_v1
contract BothMiddle_v2 is Initializable {}

/// @custom:oz-upgrades-from test/fixtures/upgrade-references/BothMiddle.sol:BothMiddle_v2
contract BothMiddle_v3 is Initializable {}
