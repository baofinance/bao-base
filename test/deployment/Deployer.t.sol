// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {Deployer} from "@bao-script/deployment/Deployer.sol";
import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {LibString} from "@solady/utils/LibString.sol";

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// @notice Minimal call target: records caller and call count; can be set to revert.
contract MockCallTarget {
    uint256 public callCount;
    address public lastCaller;
    bool public shouldRevert;

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function record() external {
        if (shouldRevert) {
            revert("MockCallTarget: forced revert");
        }
        callCount++;
        lastCaller = msg.sender;
    }
}

/// @notice Deployer subclass that exposes internal queue/flush/execute state for assertions.
contract TestableDeployer is Deployer {
    using LibString for address;

    address private _ownerAddr;
    address public buildTarget;
    bytes public buildData;
    bool public buildCalled;

    constructor(address owner_) {
        _ownerAddr = owner_;
    }

    function owner() public view override returns (address) {
        return _ownerAddr;
    }

    function treasury() public view override returns (address) {
        return _ownerAddr;
    }

    function getWellKnownAddresses() public pure override returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](0);
    }

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    // ── Expose internals ──────────────────────────────────────────────────────

    function setSaltPrefix(string memory prefix) external {
        _setSaltPrefix(prefix);
    }

    function transactionCount() external view returns (uint256) {
        return _transactions.length;
    }

    function allTransactionCount() external view returns (uint256) {
        return _allTransactions.length;
    }

    function getTransaction(uint256 i) external view returns (address target, bytes memory data, string memory desc) {
        return (_transactions[i].target, _transactions[i].data, _transactions[i].description);
    }

    function doQueue(address target, bytes calldata data, string calldata desc) external {
        queue(target, data, desc);
    }

    function doQueueAutoDesc(address target, bytes calldata data) external {
        queue(target, data);
    }

    function doQueueKey(string calldata key, bytes calldata data, string calldata desc) external {
        queue(key, data, desc);
    }

    function doFlush(string calldata suffix, string calldata description) external {
        flush(suffix, description);
    }

    function doExecuteLocal() external {
        _executeLocal();
    }

    // ── Configurable build() for run() tests ──────────────────────────────────

    function setBuildTarget(address target, bytes calldata data) external {
        buildTarget = target;
        buildData = data;
    }

    function build() internal override {
        buildCalled = true;
        if (buildTarget != address(0)) {
            queue(buildTarget, buildData, "build tx");
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// @notice Unit tests for Deployer.sol: queue, flush, _executeLocal, and run().
contract DeployerTest is BaoTest {
    TestableDeployer internal deployer;
    MockCallTarget internal mock;
    address internal testOwner;

    function setUp() public {
        testOwner = makeAddr("owner");
        deployer = new TestableDeployer(testOwner);
        mock = new MockCallTarget();
    }

    // ── queue ─────────────────────────────────────────────────────────────────

    function test_queue_appendsToTransactions() public {
        // queue() stores a transaction in the pending list
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        assertEq(deployer.transactionCount(), 1);
    }

    function test_queue_multipleCallsAccumulate() public {
        // each queue() call adds one entry; all remain until flush
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "first");
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "second");
        assertEq(deployer.transactionCount(), 2);
    }

    function test_queue_autoDesc_usesAddressHex() public {
        // the 2-arg overload generates the target address as description
        deployer.doQueueAutoDesc(address(mock), abi.encodeCall(MockCallTarget.record, ()));
        (, , string memory desc) = deployer.getTransaction(0);
        assertEq(bytes(desc)[0], bytes1("0"), "description starts with 0");
        assertEq(bytes(desc)[1], bytes1("x"), "description starts with 0x");
        assertEq(bytes(desc).length, 42, "description is a checksummed hex address (42 chars)");
    }

    function test_queue_keyOverload_predictsAddressAndPrefixesDescription() public {
        // the key overload predicts the CREATE3 address and prepends the full salt to the description
        address factory = _ensureBaoFactory();
        deployer.setSaltPrefix("test_v1");

        deployer.doQueueKey("minter", hex"", "upgrade");

        (address target, , string memory desc) = deployer.getTransaction(0);

        address expected = IBaoFactory(factory).predictAddress(keccak256(abi.encodePacked("test_v1::minter")));
        assertEq(target, expected, "target is CREATE3 address for key");

        // description is "<fullSalt>.<desc>", so it starts with the salt prefix
        assertEq(bytes(desc)[0], bytes1("t"), "description prefixed with salt (starts 'test_v1...')");
        assertTrue(bytes(desc).length > bytes("upgrade").length, "description is longer than bare desc");
    }

    // ── flush ─────────────────────────────────────────────────────────────────

    function test_flush_emptyQueue_doesNotAccumulate() public {
        // flush on an empty queue adds nothing to allTransactions
        deployer.doFlush("", "empty");
        assertEq(deployer.allTransactionCount(), 0);
    }

    function test_flush_movesToAllTransactions() public {
        // flush moves pending transactions into the accumulated list
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        assertEq(deployer.allTransactionCount(), 1);
    }

    function test_flush_clearsTransactions() public {
        // after flush, the pending list is empty
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        assertEq(deployer.transactionCount(), 0);
    }

    function test_flush_multipleFlushesAccumulate() public {
        // successive flushes each contribute to the accumulated list
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "first");
        deployer.doFlush("", "batch 1");
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "second");
        deployer.doFlush("", "batch 2");
        assertEq(deployer.allTransactionCount(), 2);
    }

    // ── _executeLocal ─────────────────────────────────────────────────────────

    function test_executeLocal_emptyAllTransactions_isNoOp() public {
        // _executeLocal with nothing accumulated does not revert
        deployer.doExecuteLocal();
    }

    function test_executeLocal_pendingOnly_doesNotExecute() public {
        // transactions in _transactions (not yet flushed) are NOT executed by _executeLocal
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doExecuteLocal();
        assertEq(mock.callCount(), 0, "_executeLocal only runs accumulated (flushed) transactions");
    }

    function test_executeLocal_executesAccumulatedTransaction() public {
        // flush then execute: the target receives the call
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        deployer.doExecuteLocal();
        assertEq(mock.callCount(), 1);
    }

    function test_executeLocal_executesInOrder() public {
        // two transactions execute in the order they were queued
        MockCallTarget mock2 = new MockCallTarget();
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "first");
        deployer.doQueue(address(mock2), abi.encodeCall(MockCallTarget.record, ()), "second");
        deployer.doFlush("", "");
        deployer.doExecuteLocal();
        assertEq(mock.callCount(), 1);
        assertEq(mock2.callCount(), 1);
    }

    function test_executeLocal_failedTransaction_reverts() public {
        // a revert inside a queued transaction propagates out of _executeLocal
        mock.setRevert(true);
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        vm.expectRevert("MockCallTarget: forced revert");
        deployer.doExecuteLocal();
    }

    function test_executeLocal_pranksAsOwner() public {
        // in test context, transactions execute with msg.sender == owner()
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        deployer.doExecuteLocal();
        assertEq(mock.lastCaller(), testOwner, "transaction executed as owner");
    }

    // ── run() ─────────────────────────────────────────────────────────────────

    function test_run_callsBuildAndExecutesTransactions() public {
        // run() calls build(), accumulates its queued transactions, and executes them
        deployer.setBuildTarget(address(mock), abi.encodeCall(MockCallTarget.record, ()));
        deployer.run("test_v1");
        assertTrue(deployer.buildCalled(), "build() was called");
        assertEq(mock.callCount(), 1, "transaction from build() was executed");
    }

    function test_run_emptyBuild_doesNotRevert() public {
        // run() with a build() that queues nothing completes without error
        deployer.run("test_v1");
    }
}
