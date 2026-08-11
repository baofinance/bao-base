// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

// ═══════════════════════════════════════════════════════════════
// What a fork switch does to the BaoFactory, and the primitive that
// accounts for it.
//
// A factory stood up before a fork is selected is of no use after it,
// so a suite that ensures the factory and then forks looks correct and
// is not: whatever deploys next reverts `Unauthorized()` at its first
// `factory.deploy`, a failure that surfaces nowhere near the ordering
// that caused it.
//
// It fails that way for two independent reasons, which is worth knowing
// because it rules out the obvious shortcuts. `vm.createSelectFork`
// replaces account state, so the registration is simply not there. And
// the registration is an expiry compared against `block.timestamp`,
// which is 1 in the bare test EVM and a real mainnet timestamp on the
// far side - so an expiry set to `now + 365 days` before the fork has
// lapsed by decades after it. Carrying the account across (persisting
// it) therefore does not rescue the ordering: it defeats the first
// reason and not the second, while replacing the deployed factory with
// a local rebuild.
//
// These assert the effect rather than either mechanism, since both are
// real and either alone is sufficient.
// ═══════════════════════════════════════════════════════════════

contract BaoFactoryAcrossForksTest is BaoTest {
    /// Ensuring the factory before selecting a fork does not carry into it: the caller is an operator
    /// beforehand and is not one afterwards. This is the mechanism the ordering rule exists for.
    function test_aFactoryEnsuredBeforeTheForkDoesNotSurviveIt() public {
        address factory = _ensureBaoFactory();
        assertTrue(IBaoFactory(factory).isCurrentOperator(address(this)), "operator registered before the fork");

        forkMainnet();

        assertFalse(
            IBaoFactory(factory).isCurrentOperator(address(this)),
            "the operator registration must not survive the fork"
        );
    }

    /// The paired primitive puts the two steps in the only order that works, so a suite cannot interleave
    /// them wrongly: afterwards the factory is present on the fork and the caller may deploy through it.
    function test_forkMainnetWithBaoFactoryLeavesTheCallerRegisteredOnTheFork() public {
        address factory = forkMainnetWithBaoFactory();

        assertGt(factory.code.length, 0, "the factory is present on the fork");
        assertTrue(IBaoFactory(factory).isCurrentOperator(address(this)), "the caller is registered on the fork");
    }

    /// The primitive repairs the wrong order rather than merely avoiding it, so a suite converted onto it
    /// needs nothing removed first: an earlier pre-fork ensure is discarded by the fork, and the primitive's
    /// own ensure re-registers the caller on the far side.
    function test_forkMainnetWithBaoFactoryRegistersEvenAfterAnEarlierPreForkEnsure() public {
        _ensureBaoFactory();

        address factory = forkMainnetWithBaoFactory();

        assertTrue(IBaoFactory(factory).isCurrentOperator(address(this)), "the caller is registered on the fork");
    }
}
