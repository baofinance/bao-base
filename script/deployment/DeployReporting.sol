// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice The deploy's running commentary — the lines an operator watching a deploy sees go past.
/// @dev Separated from the deployment logic it describes so that test coverage measures the two apart.
///      Under `forge test` a deploy is silent, so every line here that prints is unreachable and every
///      `_shouldReport` branch is one-sided; left in with the deployment code those permanently-uncovered
///      lines mask the coverage of the code that actually deploys things. Its own file gives it its own
///      row in the coverage report, where a low number is expected rather than alarming.
///
///      Every message goes through a `_report*` method — no bare `console.log` in deployment code, here
///      or in a consuming repo — so the layout convention (which indent means which nesting level) is
///      owned in one place rather than hand-spelled at each site, and the decision to speak at all is
///      taken once.
///
///      Each message gets its own method even where only one call site emits it. That is a deliberate
///      exception to the usual "don't write a function for a single caller" rule, and it buys two
///      things: the `if (_shouldReport())` disappears from the deployment logic, leaving call sites that
///      read as statements of what happened; and every message becomes individually addressable by a
///      subclass.
///
///      Being addressable is what makes reporting testable at all. Console output cannot be read back
///      from inside a test: forge routes `console.log` past the point where `vm.expectCall` could
///      observe it, so there is no way to assert on the printed text from Solidity. A test checks a
///      report in two halves instead:
///      - WHAT a deploy reports: a test overrides the `_report*` method to capture its arguments. The
///        method is `view`, so the override cannot store them. It passes them to an external `view`
///        function instead, and the test asserts that call with `vm.expectCall`. An override that
///        always reverts would make the code after its call site unreachable, which the compiler
///        warns of. Hence `virtual` throughout.
///      - HOW it reads: where the wording depends on the arguments, a `pure` `_*Message` function
///        composes the text, and the `_report*` method only decides whether to speak and prints it. A
///        test calls the function and asserts the exact text an operator reads.
///
///      Consuming repos add their own vocabulary on top (a market, a pool) and inherit the predicate, so
///      a deploy is silent under `forge test` end to end rather than only in the layer nearest the top.
abstract contract DeployReporting {
    /// @dev Foundry VM cheatcode address, for the predicate below.
    /// @dev `private`, and so redeclared by each contract in the chain that needs it, because forge-std's
    ///      `CommonBase` declares an `internal constant vm` of its own: a test inheriting both a deployer
    ///      and `Test` would otherwise fail to compile on the duplicate identifier.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ========== THE PREDICATE ==========

    /// @notice Whether to report on the deploy. On for script runs, off under `forge test`.
    /// @dev Reporting is a script-run artifact — useful to an operator watching a deploy, noise in a
    ///      test that is only using the deploy to arrange a fixture. It is one of a family with
    ///      `_shouldPersistState` (state files) and `_shouldWriteBatchFiles` (Safe batch JSON), which
    ///      live with the deployment code because they gate real file writing rather than commentary.
    ///
    ///      Override, or set `DEPLOY_REPORT=true`, to force a non-default choice — a test that is ABOUT
    ///      the deploy wants the commentary back, whereas one merely using it as a fixture does not.
    ///
    ///      Note what this does NOT key off: forge exposes no verbosity accessor — `Vm.ForgeContext`
    ///      enumerates execution contexts only — so this cannot react to `-v` levels. forge already
    ///      hides console output below `-vv`; the problem is that AT `-vv`, which is what you use to
    ///      read your own test's logs, deploy commentary drowns them.
    function _shouldReport() internal view virtual returns (bool) {
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            return true;
        }
        return vm.envOr("DEPLOY_REPORT", false);
    }

    // ========== WHAT A DEPLOY PRODUCES ==========

    /// @notice Announce the run: what is being deployed, under which salt prefix, on which network.
    /// @param what What this run deploys, e.g. "Minter Contracts" or "Swap Stack". Passed rather than held,
    ///        so the pair below stays stateless and a consumer needs no reporting subclass of its own just
    ///        to name itself.
    /// @dev `saltPrefix_` is passed in rather than read from `saltPrefix()` because this is called before
    ///      `_setSaltPrefix` in some flows; the trailing underscore keeps it clear of that getter.
    function _reportRun(string memory what, string memory saltPrefix_, string memory network) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("=== Deploying %s ===", what);
        console.log("  Salt:    %s", saltPrefix_);
        console.log("  Network: %s", network);
    }

    /// @notice The run is over.
    /// @param what The same value given to `_reportRun`, so the two lines bracket the run by name.
    function _reportRunComplete(string memory what) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("=== %s Deployment Done ===", what);
    }

    /// @notice A top-level stage of the run.
    function _reportSection(string memory title) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("");
        console.log("--- %s ---", title);
    }

    /// @notice The contract whose deployment follows, named by its salt key.
    function _reportContract(string memory key) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("    > %s", key);
    }

    /// @notice An implementation address, under the contract that owns it.
    function _reportImplementation(address implementation) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("        Impl:   %s", implementation);
    }

    /// @notice A proxy address, under the contract that owns it.
    function _reportProxy(address proxy) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("        Proxy:  %s", proxy);
    }

    /// @notice A labelled detail line under the current contract.
    function _reportDetail(string memory label, address value) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("        %s %s", label, value);
    }

    /// @notice One contract's ownership handover, during the final transfer stage.
    function _reportOwnershipTransfer(
        string memory salt,
        string memory ownerLabel,
        bool alreadyOwned
    ) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log(_ownershipTransferMessage(salt, ownerLabel, alreadyOwned));
    }

    /// @notice The line `_reportOwnershipTransfer` prints.
    function _ownershipTransferMessage(
        string memory salt,
        string memory ownerLabel,
        bool alreadyOwned
    ) internal pure returns (string memory line) {
        line = string.concat("        ", salt, " -> ", ownerLabel);
        if (alreadyOwned) {
            line = string.concat(line, " (already owned)");
        }
    }

    // ========== WHAT A DEPLOY QUEUES ==========
    //
    // The nouns here — transactions, Safe batches — belong to `Deployer` rather than to the factory
    // layer above which the rest of this contract sits. They are declared here anyway so that all the
    // permanently-uncovered message bodies share one file, and one coverage row.

    /// @notice Nothing is queued since the last batch saved: how many the run saved before, how many of them it has
    ///         executed here, and who executes the rest - this run, as `executor`, or each batch's signer.
    function _reportNoTransactions(
        uint256 executed,
        uint256 awaiting,
        bool executesHere,
        string memory executor
    ) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log(_noTransactionsMessage(executed, awaiting, executesHere, executor));
    }

    /// @notice The lines `_reportNoTransactions` prints: one for each fact that applies. forge indents every line
    ///         of a log, so the lines read as separate logs would.
    function _noTransactionsMessage(
        uint256 executed,
        uint256 awaiting,
        bool executesHere,
        string memory executor
    ) internal pure returns (string memory message) {
        if (executed + awaiting == 0) {
            return "No transactions queued: no batch saved, nothing to execute";
        }
        message = string.concat(
            "No transactions queued since the last batch saved\n  Saved this run: ",
            LibString.toString(executed + awaiting)
        );
        if (executed != 0) {
            message = string.concat(message, "\n  Executed here: ", LibString.toString(executed));
        }
        if (awaiting == 0) {
            return message;
        }
        if (executesHere) {
            return string.concat(message, "\n  To execute here now, as ", executor, ": ", LibString.toString(awaiting));
        }
        return string.concat(message, "\n  For each batch's signer to execute: ", LibString.toString(awaiting));
    }

    /// @notice The Safe batch file just written, and how many transactions it carries.
    function _reportBatchSaved(string memory path, uint256 count) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("Safe batch saved to: %s", path);
        console.log("  Transactions:", count);
    }

    /// @notice One queued transaction, as it executes.
    function _reportExecuting(string memory description) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("Executing:", description);
    }
}
