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

// ── ACCEPTED via INHERITANCE: a documented rename of a member in a namespace declared in an INHERITED base.
//    Neither the successor nor the predecessor declares the namespace directly — the tool must walk the
//    inheritance chain to find and compare it. ──
abstract contract InheritRenameBasePred {
    /// @custom:storage-location erc7201:test.inherit.rename
    struct S {
        uint128 a;
        uint128 oldName;
    }
}

contract InheritRenamePred is InheritRenameBasePred {}

abstract contract InheritRenameBaseSucc {
    /// @custom:storage-location erc7201:test.inherit.rename
    /// @custom:bao-renamed-from newName oldName
    struct S {
        uint128 a;
        uint128 newName;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:InheritRenamePred
contract InheritRenameSucc is InheritRenameBaseSucc {}

// ── REJECTED via INHERITANCE: an undocumented widen in a namespace declared in an INHERITED base. Without the
//    inheritance walk this pair is silently not compared (the namespace is invisible on the derived node). ──
abstract contract InheritBadBasePred {
    /// @custom:storage-location erc7201:test.inherit.bad
    struct S {
        uint104 amount;
    }
}

contract InheritBadPred is InheritBadBasePred {}

abstract contract InheritBadBaseSucc {
    /// @custom:storage-location erc7201:test.inherit.bad
    struct S {
        uint128 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:InheritBadPred
contract InheritBadSucc is InheritBadBaseSucc {}

// ── REJECTED: `@custom:bao-upgrades-from` names a predecessor absent from the build (a typo in the path or the
//    name). The link is still "checked" and must fail loudly ("not in build"), never be silently skipped. ──
/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:NoSuchPredecessor
contract MissingPredSucc {
    /// @custom:storage-location erc7201:test.missingpred
    struct S {
        uint128 amount;
    }
}

// ── REJECTED: the successor drops a namespace its predecessor declared (a removed `@custom:storage-location`).
//    The predecessor's storage still lives in the proxy, so losing the namespace loses that layout — the tool
//    must report "namespace ... gone", not pass by omission. ──
contract NamespaceGonePred {
    /// @custom:storage-location erc7201:test.namespacegone
    struct S {
        uint128 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:NamespaceGonePred
contract NamespaceGoneSucc {
    // the erc7201:test.namespacegone namespace is intentionally gone — no @custom:storage-location struct here
}
