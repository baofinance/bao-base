// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {TokenHolderTestBase} from "@bao-test/helpers/TokenHolderTestBase.t.sol";

/// @notice v2 counterpart to DerivedTokenHolder. v2's non-upgradeable ReentrancyGuardTransient needs no initializer,
///         so - in deliberate contrast to the v1 canary - `initialize` does owner-setup only, with no
///         __ReentrancyGuardTransient_init call.
contract DerivedTokenHolder_v2 is Initializable, TokenHolder_v2, BaoOwnable {
    function initialize(address owner) public initializer {
        _initializeOwner(owner);
        transferOwnership(owner);
    }
}

/// @notice Runs the shared TokenHolder sweep behaviour against v2 (non-upgradeable guard, no remapping dependency).
contract TestTokenHolder_v2 is TokenHolderTestBase {
    address private holder;
    address private sweepToken;
    address private stranger;

    function setUp() public {
        stranger = makeAddr("stranger");
        sweepToken = address(new MockERC20("Mock", "MOCK", 18));
        DerivedTokenHolder_v2 h = new DerivedTokenHolder_v2();
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
