// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title BaoUUPSUpgradeable
/// @notice Drop-in replacement for OpenZeppelin's upgradeable `UUPSUpgradeable`, which OZ reduced to a bare
/// re-export of the non-upgradeable contract in 5.7.0. That reduction removed two things contracts here rely
/// on: the empty `__UUPSUpgradeable_init()` shims, and `Initializable` in the base list — which is how a
/// deriving contract reaches `initializer`, `onlyInitializing` and `_disableInitializers()` without naming
/// `Initializable` itself. Restoring both keeps contracts whose on-chain initializers call
/// `__UUPSUpgradeable_init()`, and whose constructors call `_disableInitializers()`, compiling and
/// byte-identical.
///
/// Reached through a remapping of the OZ import path rather than by editing imports, so deployed sources keep
/// the exact import they were audited with — and so `verify-audit`, which compiles a tag's source against
/// HEAD's `foundry.toml`, can still build those revisions.
///
/// Named `BaoUUPSUpgradeable` rather than `UUPSUpgradeable` because the artefact namespace is flat and core
/// still declares a `UUPSUpgradeable`; a second declaration of that name is what `bin/lint-contract-names.py`
/// exists to reject. The neighbouring `UUPSUpgradeable.sol` re-exports this contract under the OZ name and
/// declares nothing itself, which is what the remapping targets.
abstract contract BaoUUPSUpgradeable is Initializable, UUPSUpgradeable {
    /// These exist only to be called by a deriving contract's initializer, so nothing inside this repo's `src`
    /// calls them and the dead-code detector cannot see their callers.
    // slither-disable-next-line dead-code
    function __UUPSUpgradeable_init() internal onlyInitializing {} // solhint-disable-line func-name-mixedcase,no-empty-blocks

    // slither-disable-next-line dead-code
    function __UUPSUpgradeable_init_unchained() internal onlyInitializing {} // solhint-disable-line func-name-mixedcase,no-empty-blocks
}
