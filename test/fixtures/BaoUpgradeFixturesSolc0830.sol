// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Fixtures for test/bin/test_bao_upgrade_check.py, pinned to solc 0.8.30: see BaoUpgradeFixturesSolc0828.sol.

// ── ACCEPTED: a documented widen, in the 0.8.30 compilation ──
contract NewerCompilerPred {
    /// @custom:storage-location erc7201:test.newercompiler
    struct S {
        uint128 product;
        uint104 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixturesSolc0830.sol:NewerCompilerPred
contract NewerCompilerSucc {
    /// @custom:storage-location erc7201:test.newercompiler
    /// @custom:bao-retyped-from amount uint104
    struct S {
        uint128 product;
        uint128 amount;
    }
}
