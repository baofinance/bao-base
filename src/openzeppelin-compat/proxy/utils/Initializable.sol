// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @dev Re-export of OpenZeppelin's `Initializable`, unchanged — 5.7.0 reduced the upgradeable copy to exactly this,
/// and nothing here needs it to differ.
///
/// It exists only so that the whole `@openzeppelin/contracts-upgradeable/proxy/utils/` PREFIX can be remapped into
/// this directory. A prefix is what forge's dependency pre-pass honours; an exact-file remapping it resolves
/// literally, compiling OZ's own re-export anyway and with it a second `UUPSUpgradeable` for the collision check to
/// reject. Redirecting the prefix keeps OZ's copies of both files out of the build entirely.
// solhint-disable-next-line no-unused-import
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
