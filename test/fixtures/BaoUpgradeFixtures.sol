// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// brings the successors that declare a name again into this build: they live in a file of their own so that each
// can declare another type, enum or contract of a name this file declares
// solhint-disable-next-line no-unused-import
import {RedefinedKeySucc} from "@bao-test/fixtures/BaoUpgradeFixturesRedefined.sol";

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

// ── ACCEPTED: an unsigned mapping key widened in place AND documented on its owning struct — here the inner key of
//    a mapping of mappings ──
contract KeyWidenPred {
    /// @custom:storage-location erc7201:test.keywiden
    struct S {
        mapping(address => mapping(uint8 => uint256)) integrals;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:KeyWidenPred
contract KeyWidenSucc {
    /// @custom:storage-location erc7201:test.keywiden
    /// @custom:bao-rekeyed-from integrals uint8
    struct S {
        mapping(address => mapping(uint256 => uint256)) integrals;
    }
}

// ── REJECTED: the same key widen, with no @custom:bao-rekeyed-from ──
contract KeyWidenUndocPred {
    /// @custom:storage-location erc7201:test.keywidenundoc
    struct S {
        mapping(address => mapping(uint8 => uint256)) integrals;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:KeyWidenUndocPred
contract KeyWidenUndocSucc {
    /// @custom:storage-location erc7201:test.keywidenundoc
    struct S {
        mapping(address => mapping(uint256 => uint256)) integrals;
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

// ── REJECTED: a key of a user-defined value type NAMED like an integer. `uint7` is not a Solidity type, so the
//    name is free: this one is a bytes1, which is padded on the other side when a key is hashed, so its entries
//    are not where a uint256 key of the same number looks. Its label reads `uint7`; its type id says what it is. ──
type uint7 is bytes1;

contract KeyNamedLikeAnIntegerPred {
    /// @custom:storage-location erc7201:test.keynamedlikeaninteger
    struct S {
        mapping(uint7 => uint256) byKey;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:KeyNamedLikeAnIntegerPred
contract KeyNamedLikeAnIntegerSucc {
    /// @custom:storage-location erc7201:test.keynamedlikeaninteger
    /// @custom:bao-rekeyed-from byKey uint7
    struct S {
        mapping(uint256 => uint256) byKey;
    }
}

// ── REJECTED: a FIELD of a user-defined value type named like an integer. `type uint9 is int8;` is a signed byte:
//    widened to uint16 as if it were an unsigned integer, a stored -1 would read 255. Its type id says what it is. ──
type uint9 is int8;

contract FieldNamedLikeAnIntegerPred {
    /// @custom:storage-location erc7201:test.fieldnamedlikeaninteger
    struct S {
        uint9 value;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:FieldNamedLikeAnIntegerPred
contract FieldNamedLikeAnIntegerSucc {
    /// @custom:storage-location erc7201:test.fieldnamedlikeaninteger
    /// @custom:bao-retyped-from value uint9
    struct S {
        uint16 value;
    }
}

// ── REJECTED: a mapping key of a user-defined value type that is ANOTHER DECLARATION of the same name. Here `Id` is
//    four bytes of bytes; the successor's file declares `Id` over a uint32, which is padded on the other side when
//    a key is hashed. The two have one label. The successor is in BaoUpgradeFixturesRedefined.sol. ──
type Id is bytes4;

contract RedefinedKeyPred {
    /// @custom:storage-location erc7201:test.redefinedkey
    struct S {
        mapping(Id => uint256) byId;
    }
}

// ── ACCEPTED: a struct that holds itself through a mapping, with a documented widen inside it. The walk meets the
//    struct again inside its own comparison and must end. ──
contract RecursivePred {
    struct Node {
        mapping(uint256 => Node) children;
        uint104 amount;
    }

    /// @custom:storage-location erc7201:test.recursive
    struct S {
        Node root;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:RecursivePred
contract RecursiveSucc {
    /// @custom:bao-retyped-from amount uint104
    struct Node {
        mapping(uint256 => Node) children;
        uint128 amount;
    }

    /// @custom:storage-location erc7201:test.recursive
    struct S {
        Node root;
    }
}

// ── ACCEPTED: the changed struct is declared in a LIBRARY, and carries its own declaration there ──
library LibraryStructLibPred {
    struct Inner {
        uint104 amount;
    }
}

library LibraryStructLibSucc {
    /// @custom:bao-retyped-from amount uint104
    struct Inner {
        uint128 amount;
    }
}

contract LibraryStructPred {
    /// @custom:storage-location erc7201:test.librarystruct
    struct S {
        LibraryStructLibPred.Inner inner;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:LibraryStructPred
contract LibraryStructSucc {
    /// @custom:storage-location erc7201:test.librarystruct
    struct S {
        LibraryStructLibSucc.Inner inner;
    }
}

// ── ACCEPTED: the changed struct is declared at FILE LEVEL, and carries its own declaration there ──
struct FileStructInnerPred {
    uint104 amount;
}

/// @custom:bao-retyped-from amount uint104
struct FileStructInnerSucc {
    uint128 amount;
}

contract FileStructPred {
    /// @custom:storage-location erc7201:test.filestruct
    struct S {
        FileStructInnerPred inner;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:FileStructPred
contract FileStructSucc {
    /// @custom:storage-location erc7201:test.filestruct
    struct S {
        FileStructInnerSucc inner;
    }
}

// ── REJECTED: a declaration on ANOTHER struct of the same bare name. The successor declares its own `Inner` and
//    documents a widen on it, but the struct in its storage is a library's `Inner`, widened with no declaration.
//    A struct takes its own declarations, looked up by where it is declared. ──
library BorrowedTagLibPred {
    struct Inner {
        uint104 amount;
    }
}

library BorrowedTagLibSucc {
    struct Inner {
        uint128 amount;
    }
}

contract BorrowedTagPred {
    /// @custom:storage-location erc7201:test.borrowedtag
    struct S {
        BorrowedTagLibPred.Inner inner;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:BorrowedTagPred
contract BorrowedTagSucc {
    /// @custom:bao-retyped-from amount uint104
    struct Inner {
        uint128 amount;
    }

    /// @custom:storage-location erc7201:test.borrowedtag
    struct S {
        BorrowedTagLibSucc.Inner inner;
    }
}

// ── ACCEPTED: a field renamed AND widened in one step. Its @custom:bao-retyped-from names it as the successor does. ──
contract RenameRetypePred {
    /// @custom:storage-location erc7201:test.renameretype
    struct S {
        uint128 product;
        uint104 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:RenameRetypePred
contract RenameRetypeSucc {
    /// @custom:storage-location erc7201:test.renameretype
    /// @custom:bao-renamed-from balance amount
    /// @custom:bao-retyped-from balance uint104
    struct S {
        uint128 product;
        uint128 balance;
    }
}

// ── REJECTED: a @custom:bao-upgrades-from that is not a whole declaration (a space where the colon belongs). Read
//    as no link, the contract would not be checked at all; the malformed-tag check reports it. ──
contract MalformedUpgradeReferencePred {
    /// @custom:storage-location erc7201:test.malformedupgradereference
    struct S {
        uint104 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol MalformedUpgradeReferencePred
contract MalformedUpgradeReference {
    /// @custom:storage-location erc7201:test.malformedupgradereference
    struct S {
        uint128 amount;
    }
}

// ── ACCEPTED via INHERITANCE: the documented key widen in a namespace declared in an INHERITED base, beside the
//    struct's other declarations ──
abstract contract InheritKeyWidenBasePred {
    /// @custom:storage-location erc7201:test.inherit.keywiden
    struct S {
        mapping(address => address) receiver;
        mapping(address => mapping(uint8 => uint256)) integrals;
    }
}

contract InheritKeyWidenPred is InheritKeyWidenBasePred {}

abstract contract InheritKeyWidenBaseSucc {
    /// @custom:storage-location erc7201:test.inherit.keywiden
    /// @custom:bao-renamed-from receiverNotUsed receiver
    /// @custom:bao-rekeyed-from integrals uint8
    /// @custom:bao-added snapshots
    struct S {
        mapping(address => address) receiverNotUsed;
        mapping(address => mapping(uint256 => uint256)) integrals;
        mapping(address => uint256) snapshots;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:InheritKeyWidenPred
contract InheritKeyWidenSucc is InheritKeyWidenBaseSucc {}

// ── REJECTED: a @custom:bao-rekeyed-from that is not a whole declaration (it gives no old key type). Read as
//    nothing it would pass unseen here, where the key did not change; the malformed-tag check reports it. ──
contract MalformedRekeyedTag {
    /// @custom:storage-location erc7201:test.malformedrekeyed
    /// @custom:bao-rekeyed-from byKey
    struct S {
        mapping(uint8 => uint256) byKey;
    }
}

// ── PARTIAL MIGRATOR over a widened key: the struct it reaches documents its key widen with
//    @custom:bao-rekeyed-from, on the real successor that owns the struct. The migrator's link is checked with that
//    owner's declaration, so it passes. ──
contract PartialKeyPred {
    /// @custom:storage-location erc7201:test.partialkey
    struct K {
        mapping(address => mapping(uint8 => uint256)) integrals;
    }
}

// the real successor whose struct the migrator reaches: the inner key widened, and documented on the struct.
contract PartialKeySucc {
    /// @custom:storage-location erc7201:test.partialkey
    /// @custom:bao-rekeyed-from integrals uint8
    struct K {
        mapping(address => mapping(uint256 => uint256)) integrals;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:PartialKeyPred
contract PartialKeyMigrator {
    bytes32 private constant _SLOT_K = 0x84c67d0f28d6faf8940c78a1e111fb7b1edee96b2615771074b55e7e2d9fc200;

    function value(address token, uint256 exponent) external view returns (uint256) {
        return _k().integrals[token][exponent];
    }

    function _k() private pure returns (PartialKeySucc.K storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SLOT_K
        }
    }
}

// ── REJECTED: the NAMESPACE struct holds itself through an array and gains a member. At the top level the member
//    takes fresh storage. Inside `children` an element grows from two slots to three, so every element after the
//    first moves. ──
contract SelfRootPred {
    /// @custom:storage-location erc7201:test.selfroot
    struct Node {
        Node[] children;
        uint256 value;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:SelfRootPred
contract SelfRootSucc {
    /// @custom:storage-location erc7201:test.selfroot
    /// @custom:bao-added extra
    struct Node {
        Node[] children;
        uint256 value;
        uint256 extra;
    }
}

// ── REJECTED: the same through a second struct. The namespace struct holds T, T holds an array of the namespace
//    struct, and the namespace struct gains a member. ──
contract MutualPred {
    struct T {
        S[] parents;
    }

    /// @custom:storage-location erc7201:test.mutual
    struct S {
        mapping(uint256 => T) ts;
        uint256 value;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:MutualPred
contract MutualSucc {
    struct T {
        S[] parents;
    }

    /// @custom:storage-location erc7201:test.mutual
    /// @custom:bao-added extra
    struct S {
        mapping(uint256 => T) ts;
        uint256 value;
        uint256 extra;
    }
}

// ── REJECTED: a SIGNED integer widened in place, documented. The bytes the wider type adds are zero in storage, so
//    a stored -1 would read 2**104 - 1. ──
contract SignedWidenPred {
    /// @custom:storage-location erc7201:test.signedwiden
    struct S {
        uint128 product;
        int104 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:SignedWidenPred
contract SignedWidenSucc {
    /// @custom:storage-location erc7201:test.signedwiden
    /// @custom:bao-retyped-from amount int104
    struct S {
        uint128 product;
        int128 amount;
    }
}

// ── REJECTED: an enum that is ANOTHER DECLARATION of the same name. Here a stored 0 is Idle; the successor's file
//    declares `RedefinedMode {Closed, Idle}`, where it is Closed. The two have one label. The successor is in
//    BaoUpgradeFixturesRedefined.sol. ──
enum RedefinedMode {
    Idle,
    Active,
    Closed
}

contract EnumRedefinedPred {
    /// @custom:storage-location erc7201:test.enumredefined
    struct S {
        RedefinedMode mode;
    }
}

// ── ACCEPTED: three versions in a chain. The middle one keeps the declaration of what it changed from the first,
//    which is not its successor's to answer for. ──
contract ChainV1 {
    /// @custom:storage-location erc7201:test.chain
    struct S {
        uint128 product;
        uint96 amount;
        mapping(uint8 => uint256) integrals;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:ChainV1
contract ChainV2 {
    /// @custom:storage-location erc7201:test.chain
    /// @custom:bao-retyped-from amount uint96
    /// @custom:bao-renamed-from rewardIntegrals integrals
    /// @custom:bao-rekeyed-from rewardIntegrals uint8
    /// @custom:bao-added extra
    struct S {
        uint128 product;
        uint104 amount;
        mapping(uint256 => uint256) rewardIntegrals;
        uint256 extra;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:ChainV2
contract ChainV3 {
    /// @custom:storage-location erc7201:test.chain
    /// @custom:bao-retyped-from amount uint104
    struct S {
        uint128 product;
        uint128 amount;
        mapping(uint256 => uint256) rewardIntegrals;
        uint256 extra;
    }
}

// ── ACCEPTED twice: a library's struct documents the change one family's upgrade makes, and another family holds
//    that struct before and after an upgrade of its own. In the second link the struct is one declaration on both
//    sides: it is not compared, and its declaration is not judged. ──
library SharedStructLibPred {
    struct Reward {
        uint128 rate;
        uint104 amount;
    }
}

library SharedStructLibSucc {
    /// @custom:bao-retyped-from amount uint104
    struct Reward {
        uint128 rate;
        uint128 amount;
    }
}

contract SharedStructPoolPred {
    /// @custom:storage-location erc7201:test.sharedstruct.pool
    struct S {
        mapping(address => SharedStructLibPred.Reward) rewards;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:SharedStructPoolPred
contract SharedStructPoolSucc {
    /// @custom:storage-location erc7201:test.sharedstruct.pool
    struct S {
        mapping(address => SharedStructLibSucc.Reward) rewards;
    }
}

contract SharedStructVaultPred {
    /// @custom:storage-location erc7201:test.sharedstruct.vault
    struct S {
        mapping(address => SharedStructLibSucc.Reward) rewards;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:SharedStructVaultPred
contract SharedStructVaultSucc {
    /// @custom:storage-location erc7201:test.sharedstruct.vault
    /// @custom:bao-added total
    struct S {
        mapping(address => SharedStructLibSucc.Reward) rewards;
        uint256 total;
    }
}

// ── ACCEPTED: a user-defined value type of ONE declaration on both sides, as a field and as a mapping key, beside
//    a documented widen ──
contract SameUserDefinedTypePred {
    /// @custom:storage-location erc7201:test.sameuserdefinedtype
    struct S {
        Id id;
        uint104 amount;
        mapping(Id => uint256) byId;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:SameUserDefinedTypePred
contract SameUserDefinedTypeSucc {
    /// @custom:storage-location erc7201:test.sameuserdefinedtype
    /// @custom:bao-retyped-from amount uint104
    struct S {
        Id id;
        uint128 amount;
        mapping(Id => uint256) byId;
    }
}

// ── ACCEPTED: two contracts of ONE NAME in two files, each with the namespace struct, so the two structs have one
//    canonical name. The link's own declarations are those of the struct its successor holds. The successor and its
//    base are in BaoUpgradeFixturesRedefined.sol. ──
abstract contract SameNameBase {
    /// @custom:storage-location erc7201:test.samename
    struct S {
        uint128 product;
        uint104 amount;
    }
}

contract SameNamePred is SameNameBase {}

// ── REJECTED: a whole @custom:bao-upgrades-from written on the STRUCT, with its other tags. It is read only on a
//    contract, so it makes no link and the narrowing below would not be checked; the tag check reports it. ──
contract UpgradeReferenceOnItsStructPred {
    /// @custom:storage-location erc7201:test.upgradereferenceonitsstruct
    struct S {
        uint128 product;
        uint104 amount;
    }
}

contract UpgradeReferenceOnItsStruct {
    /// @custom:storage-location erc7201:test.upgradereferenceonitsstruct
    /// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:UpgradeReferenceOnItsStructPred
    struct S {
        uint128 product;
        uint64 amount;
    }
}

// ── REJECTED: a struct's tags, each whole, written where they are not read: on the contract, on an event and on a
//    function. They document nothing; the tag check reports each. ──
/// @custom:bao-retyped-from amount uint96
/// @custom:bao-rekeyed-from integrals uint8
contract StructTagsOnOtherNodes {
    /// @custom:bao-added extra
    event Happened(uint256 value);

    /// @custom:bao-renamed-from newName oldName
    function run() external pure returns (uint256) {
        return 1;
    }
}
