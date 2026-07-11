// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title ReentrancyGuardTransientUpgradeable
/// @notice Drop-in replacement for OpenZeppelin's `ReentrancyGuardTransientUpgradeable`, which OZ removed in 5.6.x
/// (transient storage needs neither namespaced storage nor initialization, so OZ consolidated onto the plain
/// `ReentrancyGuardTransient`). It re-exposes the empty `onlyInitializing` init on top of that non-upgradeable guard,
/// so contracts whose on-chain initializers call `__ReentrancyGuardTransient_init()` keep compiling and stay
/// byte-identical while moving off the deleted OZ file. Because it inherits the non-upgradeable guard, it shares that
/// guard's base with any contract that uses `ReentrancyGuardTransient` directly (e.g. via `TokenHolder`), so both can
/// be inherited without a duplicate `ReentrancyGuardReentrantCall` declaration.
abstract contract ReentrancyGuardTransientUpgradeable is Initializable, ReentrancyGuardTransient {
    function __ReentrancyGuardTransient_init() internal onlyInitializing {} // solhint-disable-line func-name-mixedcase,no-empty-blocks

    function __ReentrancyGuardTransient_init_unchained() internal onlyInitializing {} // solhint-disable-line func-name-mixedcase,no-empty-blocks
}
