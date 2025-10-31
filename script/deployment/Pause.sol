// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Stem_v1} from "@bao/Stem_v1.sol";

/// @title Pause
/// @notice Minimal pause target for proxies owned by a single authority.
/// @dev Deploy a fresh instance whenever a different owner should control the upgrades.
contract Pause is Stem_v1 {
    constructor(address pauseOwner) Stem_v1(pauseOwner, 0) {}
}
