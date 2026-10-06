// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// A family whose latest version names no predecessor, so its storage layout is never checked against the
// version before it: this fails.

contract LatestUnannotated_v1 is Initializable {}

/// @custom:oz-upgrades-from test/fixtures/upgrade-references/LatestUnannotated.sol:LatestUnannotated_v1
contract LatestUnannotated_v2 is Initializable {}

contract LatestUnannotated_v3 is Initializable {}
