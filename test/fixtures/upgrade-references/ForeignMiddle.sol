// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// A family whose middle version names a contract of another family as its predecessor: an annotation that is
// present must name its own family whichever version carries it, so this fails.

contract ForeignTarget_v1 is Initializable {}

contract ForeignMiddle_v1 is Initializable {}

/// @custom:oz-upgrades-from test/fixtures/upgrade-references/ForeignMiddle.sol:ForeignTarget_v1
contract ForeignMiddle_v2 is Initializable {}

/// @custom:oz-upgrades-from test/fixtures/upgrade-references/ForeignMiddle.sol:ForeignMiddle_v2
contract ForeignMiddle_v3 is Initializable {}
