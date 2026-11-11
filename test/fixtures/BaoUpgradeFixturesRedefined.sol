// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// Successors of fixtures in BaoUpgradeFixtures.sol, which imports this file so that both are in one build. They are
// in a file of their own to declare again a name that file declares: a type, an enum, a contract.

// The successor of RedefinedKeyPred. That file's `Id` is a bytes4, this one a uint32. The two have one label in a
// storage layout, and a key of one is not hashed as a key of the other.
type Id is uint32;

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:RedefinedKeyPred
contract RedefinedKeySucc {
    /// @custom:storage-location erc7201:test.redefinedkey
    struct S {
        mapping(Id => uint256) byId;
    }
}

// The successor of EnumRedefinedPred. That file's `RedefinedMode` is {Idle, Active, Closed}; this one's puts Closed
// first. The two have one label in a storage layout, and a stored number names another member in each.
enum RedefinedMode {
    Closed,
    Idle
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:EnumRedefinedPred
contract EnumRedefinedSucc {
    /// @custom:storage-location erc7201:test.enumredefined
    struct S {
        RedefinedMode mode;
    }
}

// The successor of SameNamePred, with a base of the same name as that file's. The two bases' structs have one
// canonical name, `SameNameBase.S`; this one documents the widen.
abstract contract SameNameBase {
    /// @custom:storage-location erc7201:test.samename
    /// @custom:bao-retyped-from amount uint104
    struct S {
        uint128 product;
        uint128 amount;
    }
}

/// @custom:bao-upgrades-from test/fixtures/BaoUpgradeFixtures.sol:SameNamePred
contract SameNameSucc is SameNameBase {}
