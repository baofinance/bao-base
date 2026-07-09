// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Deployer} from "@bao-script/deployment/Deployer.sol";
import {FactoryDeployer, WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
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

/// @notice Records the order of calls it receives, so tests can assert execution sequence.
contract SequenceRecorder {
    uint256[] public calls;

    function poke(uint256 id) external {
        calls.push(id);
    }

    function callCount() external view returns (uint256) {
        return calls.length;
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

    function doExecuteQueued() external {
        _executeQueued();
    }

    function doStartSigner(address signer_) external {
        startSigner(signer_);
    }

    function doStopSigner() external {
        stopSigner();
    }

    function doBuildSafeJson(string calldata description) external view returns (string memory) {
        return _buildSafeJson(description);
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

/// @notice Deployer that forces batch-file writing on — exercises the Safe batch JSON file path
///         (written under ./results per the test-output convention, git-checked for regressions).
contract BatchWritingDeployer is TestableDeployer {
    constructor(address owner_) TestableDeployer(owner_) {}

    function _shouldWriteBatchFiles() internal pure override returns (bool) {
        return true;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// @notice Unit tests for Deployer.sol: queue, flush, _executeQueued, and run().
contract DeployerTest is BaoTest {
    using stdJson for string;

    TestableDeployer internal deployer;
    MockCallTarget internal mock;
    address internal testOwner;

    function setUp() public {
        testOwner = makeAddr("owner");
        deployer = new TestableDeployer(testOwner);
        mock = new MockCallTarget();
        // Batch-file env: identical values in every test's setUp — test functions run in parallel and
        // vm.setEnv is process-global, so per-test values would race. Filenames are made unique per test
        // via the flush suffix instead.
        vm.setEnv("DEPLOY_STATE_DIR", string.concat(vm.projectRoot(), "/results"));
        vm.setEnv("SAFE_BATCH_NAME", "deployer");
        vm.setEnv("SAFE_BATCH_TIMESTAMP", "fixed");
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
        // the 2-arg overload generates the target's hex address as the description
        deployer.doQueueAutoDesc(address(mock), abi.encodeCall(MockCallTarget.record, ()));
        (, , string memory desc) = deployer.getTransaction(0);
        assertEq(desc, LibString.toHexString(address(mock)), "description is the target's hex address");
    }

    function test_queue_keyOverload_beforePrefix_revertsSaltPrefixNotSet() public {
        // queue-by-key resolves the target from the salt prefix; with no prefix set it must fail loudly,
        // not queue a transaction against a wrong or zero address
        vm.expectRevert(FactoryDeployer.SaltPrefixNotSet.selector);
        deployer.doQueueKey("minter", hex"", "upgrade");
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

    // ── Safe batch JSON ─────────────────────────────────────────────────────────

    function test_buildSafeJson_encodesQueuedTransactions() public {
        // The Safe batch JSON carries the chainId, the meta description, and each queued tx's to/value/data
        // — the exact shape the Safe Transaction Builder imports.
        bytes memory data = abi.encodeCall(MockCallTarget.record, ());
        deployer.doQueue(address(mock), data, "record call");

        string memory json = deployer.doBuildSafeJson("grant roles");

        assertTrue(LibString.contains(json, '"chainId":"'), "includes chainId");
        assertTrue(LibString.contains(json, '"description":"grant roles"'), "includes the meta description");
        assertTrue(LibString.contains(json, '"value":"0"'), "tx value is 0");
        assertTrue(
            LibString.contains(json, LibString.toHexStringChecksummed(address(mock))),
            "includes the checksummed tx target"
        );
        assertTrue(LibString.contains(json, vm.toString(data)), "includes the tx calldata");
    }

    function test_buildSafeJson_emptyQueue_hasEmptyTransactionsArray() public view {
        // with nothing queued, the batch JSON still has the full envelope and an empty transactions array
        string memory json = deployer.doBuildSafeJson("empty batch");
        assertTrue(LibString.contains(json, '"transactions":[]'), "empty transactions array");
        assertTrue(LibString.contains(json, '"description":"empty batch"'), "includes the meta description");
    }

    function test_buildSafeJson_multipleTransactions_inQueueOrder() public {
        // each queued tx becomes its own entry, in queue order, and the envelope carries the exact
        // chainId and createdAt (unix timestamp in milliseconds) the Safe Transaction Builder expects
        MockCallTarget mock2 = new MockCallTarget();
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "first");
        deployer.doQueue(address(mock2), abi.encodeCall(MockCallTarget.record, ()), "second");

        string memory json = deployer.doBuildSafeJson("two txns");

        uint256 first = LibString.indexOf(json, LibString.toHexStringChecksummed(address(mock)));
        uint256 second = LibString.indexOf(json, LibString.toHexStringChecksummed(address(mock2)));
        assertTrue(first != LibString.NOT_FOUND, "first target present");
        assertTrue(second != LibString.NOT_FOUND, "second target present");
        assertLt(first, second, "entries appear in queue order");
        assertTrue(LibString.contains(json, '"},{"'), "entries are separate array elements");
        assertTrue(
            LibString.contains(json, string.concat('"chainId":"', vm.toString(block.chainid), '"')),
            "exact chainId"
        );
        assertTrue(
            LibString.contains(json, string.concat('"createdAt":', vm.toString(block.timestamp * 1000))),
            "createdAt is the block timestamp in milliseconds"
        );
    }

    // ── batch files ─────────────────────────────────────────────────────────────

    function test_flush_writesBatchFile_whenBatchFilesEnabled() public {
        // with batch files enabled, flush writes the Safe batch JSON to
        // <DEPLOY_STATE_DIR>/batch/<name>_<timestamp>_<suffix>@<signer>.json with the queued payload
        BatchWritingDeployer writer = new BatchWritingDeployer(testOwner);
        bytes memory data = abi.encodeCall(MockCallTarget.record, ());
        writer.doQueue(address(mock), data, "record call");
        writer.doFlush("01_roles", "batch file test");

        string memory path = string.concat(
            vm.projectRoot(),
            "/results/batch/deployer_fixed_01_roles@",
            LibString.toHexString(testOwner),
            ".json"
        );
        assertTrue(vm.exists(path), "batch file written at the derived path");
        // vm.writeJson re-formats, so assert the parsed values, not raw substrings
        string memory json = vm.readFile(path);
        assertEq(json.readString(".meta.description"), "batch file test", "file carries the description");
        assertEq(json.readAddress(".transactions[0].to"), address(mock), "file carries the tx target");
        assertEq(json.readBytes(".transactions[0].data"), data, "file carries the tx calldata");
    }

    function test_flush_batchFilename_usesSignerOverride() public {
        // startSigner routes the batch file to the signer's label; stopSigner restores owner()
        BatchWritingDeployer writer = new BatchWritingDeployer(testOwner);
        address signer = makeAddr("signer");

        writer.doStartSigner(signer);
        writer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "as signer");
        writer.doFlush("02_signer", "signer batch");
        assertTrue(
            vm.exists(
                string.concat(
                    vm.projectRoot(),
                    "/results/batch/deployer_fixed_02_signer@",
                    LibString.toHexString(signer),
                    ".json"
                )
            ),
            "batch file named for the signer override"
        );

        writer.doStopSigner();
        writer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "as owner");
        writer.doFlush("03_owner", "owner batch");
        assertTrue(
            vm.exists(
                string.concat(
                    vm.projectRoot(),
                    "/results/batch/deployer_fixed_03_owner@",
                    LibString.toHexString(testOwner),
                    ".json"
                )
            ),
            "after stopSigner the batch file is named for owner()"
        );
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

    // ── _executeQueued ─────────────────────────────────────────────────────────

    function test_executeQueued_emptyAllTransactions_isNoOp() public {
        // _executeQueued with nothing accumulated does not revert
        deployer.doExecuteQueued();
    }

    function test_executeQueued_pendingOnly_doesNotExecute() public {
        // transactions in _transactions (not yet flushed) are NOT executed by _executeQueued
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doExecuteQueued();
        assertEq(mock.callCount(), 0, "_executeQueued only runs accumulated (flushed) transactions");
    }

    function test_executeQueued_executesAccumulatedTransaction() public {
        // flush then execute: the target receives the call
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        deployer.doExecuteQueued();
        assertEq(mock.callCount(), 1);
    }

    function test_executeQueued_executesInOrder() public {
        // two transactions execute in the order they were queued
        MockCallTarget mock2 = new MockCallTarget();
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "first");
        deployer.doQueue(address(mock2), abi.encodeCall(MockCallTarget.record, ()), "second");
        deployer.doFlush("", "");
        deployer.doExecuteQueued();
        assertEq(mock.callCount(), 1);
        assertEq(mock2.callCount(), 1);
    }

    function test_executeQueued_failedTransaction_reverts() public {
        // a revert inside a queued transaction propagates out of _executeQueued
        mock.setRevert(true);
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        vm.expectRevert("MockCallTarget: forced revert");
        deployer.doExecuteQueued();
    }

    function test_executeQueued_pranksAsOwner() public {
        // in test context, transactions execute with msg.sender == owner()
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        deployer.doExecuteQueued();
        assertEq(mock.lastCaller(), testOwner, "transaction executed as owner");
    }

    function test_executeQueued_ordersAcrossFlushBatches() public {
        // transactions execute strictly in queue order across flush boundaries — batch 1 fully before
        // batch 2 — matching the order the multisig would execute the saved batches in production
        SequenceRecorder recorder = new SequenceRecorder();
        deployer.doQueue(address(recorder), abi.encodeCall(SequenceRecorder.poke, (1)), "batch1 tx1");
        deployer.doQueue(address(recorder), abi.encodeCall(SequenceRecorder.poke, (2)), "batch1 tx2");
        deployer.doFlush("", "batch 1");
        deployer.doQueue(address(recorder), abi.encodeCall(SequenceRecorder.poke, (3)), "batch2 tx1");
        deployer.doFlush("", "batch 2");

        deployer.doExecuteQueued();

        assertEq(recorder.callCount(), 3, "all transactions from both batches executed");
        assertEq(recorder.calls(0), 1, "batch 1 tx 1 first");
        assertEq(recorder.calls(1), 2, "batch 1 tx 2 second");
        assertEq(recorder.calls(2), 3, "batch 2 tx 1 last");
    }

    function test_executeQueued_drainsExecutedTransactions() public {
        // each _executeQueued runs only what has not been executed yet — mirroring the production multisig,
        // which executes every saved batch exactly once. A deploy that drains, queues more, and drains
        // again (the interleaved build→execute orchestration) must not re-run the earlier batch.
        SequenceRecorder recorder = new SequenceRecorder();
        deployer.doQueue(address(recorder), abi.encodeCall(SequenceRecorder.poke, (1)), "batch1");
        deployer.doFlush("", "batch 1");
        deployer.doExecuteQueued();

        deployer.doQueue(address(recorder), abi.encodeCall(SequenceRecorder.poke, (2)), "batch2");
        deployer.doFlush("", "batch 2");
        deployer.doExecuteQueued();

        assertEq(recorder.callCount(), 2, "batch 1 executed once, batch 2 executed once");
        assertEq(recorder.calls(0), 1, "batch 1 first");
        assertEq(recorder.calls(1), 2, "batch 2 second");
    }

    function test_executeQueued_codelessTarget_reverts() public {
        // a data-carrying call to an address with no code returns success without doing anything, so a
        // queued transaction whose target is still codeless at execution time is an error, not a silent pass
        address codeless = makeAddr("codeless");
        deployer.doQueue(codeless, abi.encodeCall(MockCallTarget.record, ()), "premature call");
        deployer.doFlush("", "");
        vm.expectRevert(abi.encodeWithSelector(Deployer.CallTargetHasNoCode.selector, codeless, "premature call"));
        deployer.doExecuteQueued();
    }

    function test_executeQueued_releasesOwnerPrank() public {
        // the owner prank is scoped to _executeQueued — a call made afterwards runs as the caller,
        // not as a leaked owner() prank
        deployer.doQueue(address(mock), abi.encodeCall(MockCallTarget.record, ()), "desc");
        deployer.doFlush("", "");
        deployer.doExecuteQueued();

        mock.record();
        assertEq(mock.lastCaller(), address(this), "no lingering prank after _executeQueued");
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

    function test_run_clearsPendingQueue() public {
        // run() consumes build()'s queued transactions through the same save-and-clear lifecycle as flush(),
        // leaving no pending transactions behind to leak into a later flush
        deployer.setBuildTarget(address(mock), abi.encodeCall(MockCallTarget.record, ()));
        deployer.run("test_v1");
        assertEq(deployer.transactionCount(), 0, "pending queue is empty after run()");
    }

    function test_run_secondRun_revertsSaltPrefixAlreadySet() public {
        // the salt prefix is write-once, so a deployer instance is single-run — a second run() with any
        // prefix fails loudly instead of silently mixing two runs' state
        deployer.run("test_v1");
        vm.expectRevert(abi.encodeWithSelector(FactoryDeployer.SaltPrefixAlreadySet.selector, "test_v1", "other_v1"));
        deployer.run("other_v1");
    }
}
