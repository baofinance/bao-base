// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// A fixture for test/bin/test_bao_upgrade_check.py: a successor pinned to solc 0.8.30 whose predecessor, in
// BaoUpgradeFixturesSolc0828.sol, is pinned to 0.8.28. The tool lays the two out in one compilation, which no compiler
// version satisfies, so the run stops naming the link.
/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixturesSolc0828.sol:OlderCompilerPred
contract AcrossCompilersSucc {
    /// @custom:storage-location erc7201:test.oldercompiler
    struct S {
        uint128 product;
        uint104 amount;
    }
}
