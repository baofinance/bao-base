// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Fixtures for test/bin/test_bao_upgrade_check.py, pinned to solc 0.8.28. Built together with
// BaoUpgradeFixturesSolc0830.sol, which is pinned to 0.8.30, they make forge write one compiled build-info for each
// compiler version. The link in each must be checked.

// ── REJECTED: a narrowing, in the 0.8.28 compilation ──
contract OlderCompilerPred {
    /// @custom:storage-location erc7201:test.oldercompiler
    struct S {
        uint128 product;
        uint104 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixturesSolc0828.sol:OlderCompilerPred
contract OlderCompilerSucc {
    /// @custom:storage-location erc7201:test.oldercompiler
    struct S {
        uint128 product;
        uint64 amount;
    }
}
