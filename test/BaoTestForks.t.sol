// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";

/// @notice BaoTest takes a fork only at a block or transaction its list names. `default` and a name resolve to the
///         block listed under them, `latest` to the highest block listed, a number or transaction the test derives
///         passes when listed, and anything else is refused naming the file. The list is a fixture and no fork is
///         created: these test the lookup every fork wrapper makes.
contract BaoTestForksTest is BaoTest {
    bytes32 internal constant LISTED = 0xb8701591c0fa3ee44a9f42379d167261f70e0532f7c0cea6fcda26ef999df3db;
    bytes32 internal constant UNLISTED = 0x0000000000000000000000000000000000000000000000000000000000000001;

    function forkBlocksFile() internal pure override returns (string memory) {
        return "test/fixtures/fork-blocks/three.toml";
    }

    /// @dev External, so a refusal is a revert of a call the test can expect.
    function listedBlockFromOutside(string memory name) external view returns (uint256) {
        return listedBlock(name);
    }

    /// @dev External, so a refusal is a revert of a call the test can expect.
    function listedBlockFromOutside(uint256 blockNumber) external view returns (uint256) {
        return listedBlock(blockNumber);
    }

    /// @dev External, so a refusal is a revert of a call the test can expect.
    function listedTransactionFromOutside(bytes32 transaction) external view returns (bytes32) {
        return listedTransaction(transaction);
    }

    /// The default is the block listed under `default`.
    function test_default_isTheBlockNamedDefault() public view {
        assertEq(listedBlock(FORK_DEFAULT), 100);
    }

    /// A name resolves to the block listed under it.
    function test_aName_isTheBlockListedUnderIt() public view {
        assertEq(listedBlock("older"), 50);
    }

    /// `latest` is the highest block listed, wherever it is written.
    function test_latest_isTheHighestBlockListed_notTheLastWritten() public view {
        assertEq(listedBlock(FORK_LATEST), 300);
    }

    /// A name the list does not hold is refused, naming the name and the file.
    function test_aNameNotListed_isRefusedNamingTheFile() public {
        vm.expectRevert(bytes('test/fixtures/fork-blocks/three.toml lists no block named "missing"'));
        this.listedBlockFromOutside("missing");
    }

    /// A number a test derives passes when some name lists it.
    function test_aNumberListed_passes() public view {
        assertEq(listedBlock(50), 50);
    }

    /// A number no name lists is refused, naming the number and the file.
    function test_aNumberNotListed_isRefusedNamingTheFile() public {
        vm.expectRevert(bytes("test/fixtures/fork-blocks/three.toml does not list block 51"));
        this.listedBlockFromOutside(51);
    }

    /// A transaction passes when some name lists it.
    function test_aTransactionListed_passes() public view {
        assertEq(listedTransaction(LISTED), LISTED);
    }

    /// A transaction no name lists is refused, naming the transaction and the file.
    function test_aTransactionNotListed_isRefusedNamingTheFile() public {
        vm.expectRevert(
            bytes(
                "test/fixtures/fork-blocks/three.toml does not list transaction "
                "0x0000000000000000000000000000000000000000000000000000000000000001"
            )
        );
        this.listedTransactionFromOutside(UNLISTED);
    }
}

/// @notice A list without a [transactions] table lists its blocks as any other and refuses every transaction.
contract BaoTestForksWithoutTransactionsTest is BaoTest {
    function forkBlocksFile() internal pure override returns (string memory) {
        return "test/fixtures/fork-blocks/blocks-only.toml";
    }

    /// @dev External, so a refusal is a revert of a call the test can expect.
    function listedTransactionFromOutside(bytes32 transaction) external view returns (bytes32) {
        return listedTransaction(transaction);
    }

    function test_default_isTheBlockNamedDefault() public view {
        assertEq(listedBlock(FORK_DEFAULT), 7);
    }

    function test_aTransaction_isRefused() public {
        vm.expectRevert(
            bytes(
                "test/fixtures/fork-blocks/blocks-only.toml does not list transaction "
                "0xb8701591c0fa3ee44a9f42379d167261f70e0532f7c0cea6fcda26ef999df3db"
            )
        );
        this.listedTransactionFromOutside(0xb8701591c0fa3ee44a9f42379d167261f70e0532f7c0cea6fcda26ef999df3db);
    }
}

/// @notice A list without a [blocks] table has no default, no latest and no block, and lists its transactions.
contract BaoTestForksWithoutBlocksTest is BaoTest {
    function forkBlocksFile() internal pure override returns (string memory) {
        return "test/fixtures/fork-blocks/transactions-only.toml";
    }

    /// @dev External, so a refusal is a revert of a call the test can expect.
    function listedBlockFromOutside(string memory name) external view returns (uint256) {
        return listedBlock(name);
    }

    /// @dev External, so a refusal is a revert of a call the test can expect.
    function listedBlockFromOutside(uint256 blockNumber) external view returns (uint256) {
        return listedBlock(blockNumber);
    }

    function test_default_isRefused() public {
        vm.expectRevert(bytes('test/fixtures/fork-blocks/transactions-only.toml lists no block named "default"'));
        this.listedBlockFromOutside(FORK_DEFAULT);
    }

    function test_latest_isRefused() public {
        vm.expectRevert(bytes("test/fixtures/fork-blocks/transactions-only.toml lists no blocks"));
        this.listedBlockFromOutside(FORK_LATEST);
    }

    function test_aNumber_isRefused() public {
        vm.expectRevert(bytes("test/fixtures/fork-blocks/transactions-only.toml does not list block 1"));
        this.listedBlockFromOutside(1);
    }

    function test_aTransactionListed_passes() public view {
        bytes32 listed = 0xb8701591c0fa3ee44a9f42379d167261f70e0532f7c0cea6fcda26ef999df3db;
        assertEq(listedTransaction(listed), listed);
    }
}
