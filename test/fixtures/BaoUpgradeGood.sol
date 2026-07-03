// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// A build with ONLY a valid (widen) pair, so main() exits 0 — the pass-side of the exit-code contract that
// validate relies on. The mixed BaoUpgradeFixtures.sol covers the fail side (exit 1).

contract GoodPred {
    /// @custom:storage-location erc7201:test.bao.good
    struct S {
        uint128 product;
        uint104 amount;
        uint40 updatedAt;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeGood.sol:GoodPred
contract GoodSucc {
    /// @custom:storage-location erc7201:test.bao.good
    /// @custom:bao-retyped-from amount uint104
    struct S {
        uint128 product;
        uint128 amount;
        uint40 updatedAt;
    }
}
