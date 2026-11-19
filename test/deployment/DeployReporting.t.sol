// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeployReporting} from "@bao-script/deployment/DeployReporting.sol";

/// @notice Exposes the text each report composes from its arguments.
contract ReportingHarness is DeployReporting {
    function noTransactionsMessage(
        uint256 executed,
        uint256 awaiting,
        bool executesHere,
        string memory executor
    ) external pure returns (string memory) {
        return _noTransactionsMessage(executed, awaiting, executesHere, executor);
    }

    function ownershipTransferMessage(
        string memory salt,
        string memory ownerLabel,
        bool alreadyOwned
    ) external pure returns (string memory) {
        return _ownershipTransferMessage(salt, ownerLabel, alreadyOwned);
    }
}

/// @notice The text an operator reads, for each report whose wording depends on its arguments.
contract DeployReportingTest is BaoTest {
    ReportingHarness internal reporting;

    function setUp() public {
        reporting = new ReportingHarness();
    }

    // ── an empty flush ────────────────────────────────────────────────────────

    function test_noTransactionsMessage_nothingSaved() public view {
        // a run that saved no batch says so in one line, whoever would have executed it
        string memory expected = "No transactions queued: no batch saved, nothing to execute";
        assertEq(reporting.noTransactionsMessage(0, 0, true, "deployer"), expected, "executing here");
        assertEq(reporting.noTransactionsMessage(0, 0, false, "deployer"), expected, "left for each batch's signer");
    }

    function test_noTransactionsMessage_allExecutedHere() public view {
        // a run that executed everything it saved gives both counts and names no one to execute the rest
        assertEq(
            reporting.noTransactionsMessage(3, 0, true, "deployer"),
            "No transactions queued since the last batch saved\n  Saved this run: 3\n  Executed here: 3"
        );
    }

    function test_noTransactionsMessage_awaitingExecutionHere() public view {
        // a run that executes here names the account it executes the saved transactions as
        assertEq(
            reporting.noTransactionsMessage(0, 2, true, "deployer"),
            "No transactions queued since the last batch saved\n  Saved this run: 2\n  To execute here now, as deployer: 2"
        );
    }

    function test_noTransactionsMessage_awaitingEachBatchSigner() public view {
        // a run that leaves its saved transactions for each batch's signer names no account
        assertEq(
            reporting.noTransactionsMessage(0, 2, false, "deployer"),
            "No transactions queued since the last batch saved\n  Saved this run: 2\n  For each batch's signer to execute: 2"
        );
    }

    function test_noTransactionsMessage_someExecutedSomeAwaiting() public view {
        // the count saved is the executed and the awaiting together, and each of those has its own line
        assertEq(
            reporting.noTransactionsMessage(1, 2, true, "deployer"),
            string.concat(
                "No transactions queued since the last batch saved\n  Saved this run: 3\n  Executed here: 1",
                "\n  To execute here now, as deployer: 2"
            )
        );
    }

    // ── an ownership handover ─────────────────────────────────────────────────

    function test_ownershipTransferMessage_transferred() public view {
        // a handover names the contract by its salt, and the owner it goes to
        assertEq(
            reporting.ownershipTransferMessage("bao_v1::minter", "multisig", false),
            "        bao_v1::minter -> multisig"
        );
    }

    function test_ownershipTransferMessage_alreadyOwned() public view {
        // a contract the owner already holds is named, and marked as already owned
        assertEq(
            reporting.ownershipTransferMessage("bao_v1::minter", "multisig", true),
            "        bao_v1::minter -> multisig (already owned)"
        );
    }
}
