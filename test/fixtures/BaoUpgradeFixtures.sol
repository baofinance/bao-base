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

// ── ACCEPTED: a getter that returns a namespaced struct at the CORRECT hardcoded ERC-7201 slot. storage-successor
//    auto-detects it (via solc's assembly externalReferences — no annotation) and verifies the slot equals
//    `cast index-erc7201 test.slotgetter.good`. ──
contract SlotGetterGood {
    /// @custom:storage-location erc7201:test.slotgetter.good
    struct S {
        uint256 x;
    }

    bytes32 private constant _SLOT = 0x943d3d3fc26f81ba6fc8e9e463ad4208960dc4c24d8836531cae61e956cb8600;

    function value() external view returns (uint256) {
        return _s().x;
    }

    function _s() private pure returns (S storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SLOT
        }
    }
}

// ── REJECTED: the getter reaches namespace test.slotgetter.bad but hardcodes test.slotgetter.good's slot (a
//    copy-paste of the wrong namespace's slot). Auto-detected and flagged as a slot mismatch. ──
contract SlotGetterWrong {
    /// @custom:storage-location erc7201:test.slotgetter.bad
    struct S {
        uint256 x;
    }

    bytes32 private constant _SLOT = 0x943d3d3fc26f81ba6fc8e9e463ad4208960dc4c24d8836531cae61e956cb8600;

    function value() external view returns (uint256) {
        return _s().x;
    }

    function _s() private pure returns (S storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SLOT
        }
    }
}

// ── REJECTED: a misspelled bao tag (`bao-renamd-from`, a typo of bao-renamed-from). solc accepts it as a valid
//    custom tag, so it compiles — but the tool recognizes no such tag, so the intended rename check would be
//    silently skipped. The unrecognized-tag check catches it; the recognized tags alongside it stay unflagged. ──
contract MisspelledBaoTag {
    /// @custom:storage-location erc7201:test.misspelled
    /// @custom:bao-added a
    /// @custom:bao-renamd-from newName oldName
    struct S {
        uint128 a;
    }
}

// ── PARTIAL MIGRATOR: a light contract carrying @custom:bao-upgrades-from that REACHES a namespace by assembly
//    through ANOTHER contract's struct (one it does not declare itself) — the mark of a transient upgrader. It
//    touches only test.partial.a; storage-successor must byte-compare that reached struct against the
//    predecessor's same namespace, and must NOT flag test.partial.b (which it never touches) as "gone". ──
contract PartialPred {
    /// @custom:storage-location erc7201:test.partial.a
    struct A {
        uint128 x;
        uint128 y;
    }

    /// @custom:storage-location erc7201:test.partial.b
    struct B {
        uint256 z;
    }
}

// the real successor whose struct the migrator reaches; test.partial.a is unchanged (a byte-compatible successor).
contract PartialSucc {
    /// @custom:storage-location erc7201:test.partial.a
    struct A {
        uint128 x;
        uint128 y;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:PartialPred
contract PartialMigrator {
    bytes32 private constant _SLOT_A = 0x8a9f310f7d6993bc328438cd0b0d58f23c02c13f7a7079d2675aebd53eb72000;

    function value() external view returns (uint128) {
        return _a().x;
    }

    function _a() private pure returns (PartialSucc.A storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SLOT_A
        }
    }
}
