// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {TokenHolderTestBase} from "@bao-test/TokenHolderTestBase.t.sol";

/// @notice Canary mirroring downstream deployed consumers: it calls the reentrancy-guard initializer inside an
///         `initializer` context, so a change to TokenHolder that removes that init API (or drifts the guard bytecode)
///         fails the build here - surfacing a base change that would break the bytecode of downstream deployed
///         contracts that inherit TokenHolder and call the init in their own initializers.
contract DerivedTokenHolder is TokenHolder, BaoOwnable {
    function initialize(address owner) public initializer {
        _initializeOwner(owner);
        __ReentrancyGuardTransient_init();
        transferOwnership(owner);
    }
}

/// @notice Runs the shared TokenHolder sweep behaviour against the audited v1 (upgradeable guard via the shim).
contract TestTokenHolder is TokenHolderTestBase {
    address private holder;
    address private sweepToken;
    address private stranger;

    function setUp() public {
        stranger = makeAddr("stranger");
        sweepToken = address(new MockERC20("Mock", "MOCK", 18));
        DerivedTokenHolder h = new DerivedTokenHolder();
        h.initialize(address(this));
        holder = address(h);
    }

    function _tokenHolderTarget() internal view override returns (address) {
        return holder;
    }

    function _tokenHolderSweepToken() internal view override returns (address) {
        return sweepToken;
    }

    function _tokenHolderNonOwner() internal view override returns (address) {
        return stranger;
    }
}
