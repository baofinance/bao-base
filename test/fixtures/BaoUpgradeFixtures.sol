// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Fixtures for test/bin/test_bao_upgrade_check.py — one predecessor/successor pair per storage change, each in
// its own erc7201 namespace so they coexist in one build. The integration test builds this file and runs the
// real storage-successor.py over it: the DOCUMENTED widens (flat and nested) must pass; every other pair must
// be rejected. These are .sol (not hand-authored JSON) so the extract -> inject -> build -> compare path is
// exercised exactly as validate runs it, on real solc layouts.

// ── ACCEPTED: an integer widened in place AND documented on its owning struct ──
contract WidenPred {
    /// @custom:storage-location erc7201:test.widen
    struct S {
        uint128 product;
        uint104 amount;
        uint40 updatedAt;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:WidenPred
contract WidenSucc {
    /// @custom:storage-location erc7201:test.widen
    /// @custom:bao-retyped-from amount uint104
    struct S {
        uint128 product;
        uint128 amount;
        uint40 updatedAt;
    }
}

// ── REJECTED: the same widen, but NOT documented ──
contract UndocPred {
    /// @custom:storage-location erc7201:test.undoc
    struct S {
        uint128 product;
        uint104 amount;
        uint40 updatedAt;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:UndocPred
contract UndocSucc {
    /// @custom:storage-location erc7201:test.undoc
    struct S {
        uint128 product;
        uint128 amount;
        uint40 updatedAt;
    }
}

// ── REJECTED: narrowed ──
contract NarrowPred {
    /// @custom:storage-location erc7201:test.narrow
    struct S {
        uint128 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:NarrowPred
contract NarrowSucc {
    /// @custom:storage-location erc7201:test.narrow
    struct S {
        uint64 amount;
    }
}

// ── REJECTED: a documented widen that overflows its slot, relocating the next field ──
contract MovePred {
    /// @custom:storage-location erc7201:test.move
    struct S {
        uint128 a;
        uint128 b;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:MovePred
contract MoveSucc {
    /// @custom:storage-location erc7201:test.move
    /// @custom:bao-retyped-from a uint128
    struct S {
        uint256 a;
        uint128 b;
    }
}

// ── REJECTED: a documented widen so wide the field itself relocates (uint192 can't fit amount's slot) ──
contract OverflowPred {
    /// @custom:storage-location erc7201:test.overflow
    struct S {
        uint128 product;
        uint104 amount;
        uint40 updatedAt;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:OverflowPred
contract OverflowSucc {
    /// @custom:storage-location erc7201:test.overflow
    /// @custom:bao-retyped-from amount uint104
    struct S {
        uint128 product;
        uint192 amount;
        uint40 updatedAt;
    }
}

// ── REJECTED: type kind changed ──
contract KindPred {
    /// @custom:storage-location erc7201:test.kind
    struct S {
        bytes32 x;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:KindPred
contract KindSucc {
    /// @custom:storage-location erc7201:test.kind
    struct S {
        uint256 x;
    }
}

// ── REJECTED: a field removed ──
contract RemovePred {
    /// @custom:storage-location erc7201:test.remove
    struct S {
        uint128 a;
        uint40 b;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:RemovePred
contract RemoveSucc {
    /// @custom:storage-location erc7201:test.remove
    struct S {
        uint128 a;
    }
}

// ── REJECTED: a field added ──
contract AddPred {
    /// @custom:storage-location erc7201:test.add
    struct S {
        uint128 a;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:AddPred
contract AddSucc {
    /// @custom:storage-location erc7201:test.add
    struct S {
        uint128 a;
        uint128 b;
    }
}

// ── REJECTED: mapping key type changed ──
contract KeyPred {
    /// @custom:storage-location erc7201:test.key
    struct S {
        mapping(address => uint256) balances;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:KeyPred
contract KeySucc {
    /// @custom:storage-location erc7201:test.key
    struct S {
        mapping(bytes32 => uint256) balances;
    }
}

// ── ACCEPTED: a documented widen reached through a direct field, a mapping, and a dynamic array ──
contract NestGoodPred {
    struct Inner {
        uint128 product;
        uint104 amount;
        uint40 updatedAt;
    }

    /// @custom:storage-location erc7201:test.nest.good
    struct Root {
        Inner direct;
        mapping(address => Inner) byKey;
        Inner[] list;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:NestGoodPred
contract NestGoodSucc {
    /// @custom:bao-retyped-from amount uint104
    struct Inner {
        uint128 product;
        uint128 amount;
        uint40 updatedAt;
    }

    /// @custom:storage-location erc7201:test.nest.good
    struct Root {
        Inner direct;
        mapping(address => Inner) byKey;
        Inner[] list;
    }
}

// ── REJECTED: the same nested widen, undocumented (proves deep detection through containers) ──
contract NestBadPred {
    struct Inner {
        uint128 product;
        uint104 amount;
        uint40 updatedAt;
    }

    /// @custom:storage-location erc7201:test.nest.bad
    struct Root {
        Inner direct;
        mapping(address => Inner) byKey;
        Inner[] list;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:NestBadPred
contract NestBadSucc {
    struct Inner {
        uint128 product;
        uint128 amount;
        uint40 updatedAt;
    }

    /// @custom:storage-location erc7201:test.nest.bad
    struct Root {
        Inner direct;
        mapping(address => Inner) byKey;
        Inner[] list;
    }
}
