// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title BaoERC1967Proxy
/// @notice OpenZeppelin's `ERC1967Proxy` with the constructor guard 5.6.0 added turned back off, so a proxy may
/// again be deployed with empty `initData`.
///
/// That guard assumes every implementation has an initializer to call. Two things here have none, by design:
/// a `HarborFixedOwnable` or `BaoFixedOwnable` contract takes its owner as an immutable constructor argument
/// and so has nothing to initialise, and `UUPSProxyDeployStub` is a bootstrap that is upgraded away
/// immediately afterwards. For both, an uninitialised proxy is the correct and intended state rather than the
/// half-finished deployment OZ is protecting against.
///
/// Only the CONSTRUCTOR differs. The guard is `if (!_unsafeAllowUninitialized() && _data.length == 0)`, so
/// overriding a `pure` function to return true lets the optimiser drop the branch entirely; the deployed
/// runtime — the delegating fallback, which is all a proxy is once built — is byte-for-byte OZ's. Proxies
/// deployed through this are therefore indistinguishable on chain from those already deployed, which is what
/// lets it be adopted without a migration.
///
/// The name carries the `Bao` prefix because the artefact namespace is flat and OZ still declares an
/// `ERC1967Proxy`; a second declaration of that name is what `bin/lint-contract-names.py` exists to reject.
contract BaoERC1967Proxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data) payable ERC1967Proxy(implementation, data) {}

    /// @inheritdoc ERC1967Proxy
    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
