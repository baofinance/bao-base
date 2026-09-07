// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @dev Remapping target for `@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol`, re-exporting
/// [`BaoUUPSUpgradeable`] under the name OZ used to declare here. It declares nothing of its own — the same shape
/// as OZ's own re-export files — so the flat artefact namespace still holds exactly one `UUPSUpgradeable`, and
/// `bin/lint-contract-names.py` sees no collision.
// solhint-disable-next-line no-unused-import
import {BaoUUPSUpgradeable as UUPSUpgradeable} from "@bao/openzeppelin-compat/BaoUUPSUpgradeable.sol";
