// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {DeploymentSnapLib} from "@bao-test/snap/DeploymentSnapLib.sol";
import {DeploymentDiffLib} from "@bao-test/snap/DeploymentDiffLib.sol";

/// @title DeploymentCheckLib
/// @notice A batch's check: every change it makes to a deployment is claimed, and every claim claims a change.
/// @dev `begin` is called before the batch runs and `end` after it, on the same fork. The batch runs between them: run
/// by a test as its signer would, or replayed from the chain where it ran (`replay`).
/// The changes are of two kinds:
/// - the readings of the proxies under the prefix that differ, or appear or go: their views, account facts and
///   implementations, read before and after the batch at the same known addresses. Those are the caller's, the
///   addresses the proxies' views with no argument return before or after, each address the batch wrote an entry for,
///   and each party to a transfer the batch logged.
/// - the storage values the batch changed in every proxy of the listing, named by DeploymentDiffLib: by the layout of
///   the code that wrote each, then by the layout of the implementation the proxy was read as before the batch.
/// A proxy the batch paused is read after it as it was read before it, so the two reads compare the same views, however
/// many implementations the batch ran it on in between. One paused before the batch is read on the implementation the
/// slot's history gives, before and after alike.
/// The transfer rule: for each token that logged a `Transfer`, `balanceOf` of each party and `totalSupply()` must move
/// by exactly what the logs say. For a token of the listing it claims those views and the storage values that hold the
/// same values before and after: a party's entry, and the supply.
/// A claim names a contract key and a label, each with `*` matching any run of characters, and what the change must be.
/// The check fails listing each change no claim or rule claims, each claim that claims nothing, each claim whose value
/// is not what the change ends with, and each token that moved other than its transfers. Either way it writes the reads
/// before and after, the changes and the writes outside the listing to the caller's folder, and ends at the state after
/// the batch.
library DeploymentCheckLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    /// What a reading or a value no longer has, or does not yet have.
    string internal constant NONE = "(none)";

    enum Expectation {
        Becomes,
        BecomesTheBlockTime,
        IncreasesBy,
        Reverts,
        Changes
    }

    struct Claim {
        string contractKey;
        string label;
        Expectation expectation;
        /// the value the change ends with; the increase; the revert data in hex; the reason a value is not stated
        string value;
    }

    /// A check: the snapshot `begin` took, the listing, the prefix of the proxies whose views are read, addresses to
    /// read address views at, implementations the listing does not name (deployed by the test), the claims, and the
    /// folder its files are written to.
    struct Check {
        uint256 before;
        string listing;
        string prefix;
        address[] known;
        DeploymentSnapLib.Implementation[] implementations;
        Claim[] claims;
        string folder;
    }

    /// A token's transfers: each party's net movement and the supply's, and what its views answer before and after.
    struct Token {
        address token;
        address[] parties;
        int256[] nets;
        int256 supply;
        uint256[] balancesBefore;
        uint256[] balancesAfter;
        uint256 supplyBefore;
        uint256 supplyAfter;
    }

    struct Reads {
        DeploymentSnapLib.Reading[] before;
        DeploymentSnapLib.Reading[] afterwards;
    }

    /// The changes, what covers each, and the failures.
    struct Judged {
        DeploymentDiffLib.Change[] changes;
        string[] coveredBy;
        string[] failures;
        uint256 failureCount;
    }

    /// What bin/run-campaign-test names in the environment: the listing's path, the folder each check writes its
    /// reads to, a folder of its own in it, and the end of each name a batch's transactions are given under. A
    /// campaign reads them through virtual functions of its own.
    string internal constant LISTING = "BAO_CHECK_LISTING";
    string internal constant FOLDER = "BAO_CHECK_FOLDER";
    string internal constant TRANSACTIONS = "_TRANSACTIONS";

    error ClaimsFailed(string report);
    error ATokenDoesNotAnswer(address token, bytes call);
    error TransferBeyondSignedRange(address token, uint256 value);
    error NotATransactionHash(string text);

    // ── claims ────────────────────────────────────────────────────────────────────────────────────

    /// The change ends with `value`, written as the read writes it.
    function becomes(
        string memory contractKey,
        string memory label,
        string memory value
    ) internal pure returns (Claim memory) {
        return Claim(contractKey, label, Expectation.Becomes, value);
    }

    function becomes(
        string memory contractKey,
        string memory label,
        uint256 value
    ) internal pure returns (Claim memory) {
        return Claim(contractKey, label, Expectation.Becomes, vm.toString(value));
    }

    function becomes(
        string memory contractKey,
        string memory label,
        address value
    ) internal pure returns (Claim memory) {
        return Claim(contractKey, label, Expectation.Becomes, vm.toString(value));
    }

    function becomes(string memory contractKey, string memory label, bool value) internal pure returns (Claim memory) {
        return Claim(contractKey, label, Expectation.Becomes, vm.toString(value));
    }

    /// The change ends with the time of the block the batch ran in.
    function becomesTheBlockTime(string memory contractKey, string memory label) internal pure returns (Claim memory) {
        return Claim(contractKey, label, Expectation.BecomesTheBlockTime, "");
    }

    /// The change is an increase by `amount`.
    function increasesBy(
        string memory contractKey,
        string memory label,
        uint256 amount
    ) internal pure returns (Claim memory) {
        return Claim(contractKey, label, Expectation.IncreasesBy, vm.toString(amount));
    }

    /// The view reverts after the batch, with exactly this revert data.
    function reverts(
        string memory contractKey,
        string memory label,
        bytes memory revertData
    ) internal pure returns (Claim memory) {
        return Claim(contractKey, label, Expectation.Reverts, vm.toString(revertData));
    }

    /// The change's value is not stated: `reason` says why it changes.
    function changes(
        string memory contractKey,
        string memory label,
        string memory reason
    ) internal pure returns (Claim memory) {
        return Claim(contractKey, label, Expectation.Changes, reason);
    }

    // ── the check ─────────────────────────────────────────────────────────────────────────────────

    /// Called before the batch: a snapshot of the state, then the recordings `end` reads.
    function begin() internal returns (uint256 before) {
        before = vm.snapshotState();
        vm.recordLogs();
        vm.startMappingRecording();
        vm.startStateDiffRecording();
    }

    /// Replays mined transactions in turn, on a fork made at the first of them: a batch where it ran, the one
    /// transaction of a Safe's execution on a network, or the transactions run-batch mined into one block of a local
    /// node, which follow each other in it.
    function replay(bytes32[] memory hashes) internal {
        for (uint256 i = 0; i < hashes.length; ++i) {
            vm.transact(hashes[i]);
        }
    }

    /// The transaction hashes of a comma-separated list, in its order; an empty list holds none. An entry that is not
    /// `0x` and 32 bytes in hex stops it.
    function transactions(string memory list) internal pure returns (bytes32[] memory hashes) {
        if (bytes(list).length == 0) {
            return hashes;
        }
        string[] memory entries = vm.split(list, ",");
        hashes = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; ++i) {
            bytes memory entry = bytes(entries[i]);
            bool isHash = entry.length == 66 && entry[0] == "0" && entry[1] == "x";
            for (uint256 c = 2; c < entry.length && isHash; ++c) {
                bytes1 digit = entry[c];
                isHash =
                    (digit >= "0" && digit <= "9") ||
                    (digit >= "a" && digit <= "f") ||
                    (digit >= "A" && digit <= "F");
            }
            if (!isHash) {
                revert NotATransactionHash(entries[i]);
            }
            hashes[i] = vm.parseBytes32(entries[i]);
        }
    }

    /// Called after the batch: checks it, a paused proxy's earlier implementation found on the chain. Returns the logs
    /// the batch made.
    function end(Check memory check) internal returns (Vm.Log[] memory logs) {
        return end(check, DeploymentSnapLib.implementationSlotOnChainAt);
    }

    /// Called after the batch: checks it, a paused proxy's earlier implementation found in the history `slotAt` gives.
    /// Returns the logs the batch made.
    function end(
        Check memory check,
        function(address, uint256) returns (bytes32) slotAt
    ) internal returns (Vm.Log[] memory logs) {
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        logs = vm.getRecordedLogs();
        uint256 blockTime = block.timestamp;
        DeploymentSnapLib.Listing memory parsed = _withImplementations(
            DeploymentSnapLib.parse(check.listing),
            check.implementations
        );
        Token[] memory tokens = _tokens(logs);
        Sides memory sides = _before(check, parsed, accesses, tokens, slotAt);
        DeploymentDiffLib.Diff memory diff = DeploymentDiffLib.diff(parsed, accesses, _layouts(sides.stored));
        vm.stopMappingRecording();
        Reads memory reads = _reads(check, parsed, diff, tokens, sides, slotAt);
        Judged memory judged = _judge(check.claims, parsed, diff, tokens, reads, blockTime);
        _write(check.folder, reads, judged, diff);
        if (judged.failureCount > 0) {
            revert ClaimsFailed(_joined(judged.failures, judged.failureCount));
        }
    }

    /// The listing's implementations and the caller's.
    function _withImplementations(
        DeploymentSnapLib.Listing memory parsed,
        DeploymentSnapLib.Implementation[] memory extra
    ) private pure returns (DeploymentSnapLib.Listing memory) {
        DeploymentSnapLib.Implementation[] memory all = new DeploymentSnapLib.Implementation[](
            parsed.implementations.length + extra.length
        );
        for (uint256 i = 0; i < parsed.implementations.length; ++i) {
            all[i] = parsed.implementations[i];
        }
        for (uint256 i = 0; i < extra.length; ++i) {
            all[parsed.implementations.length + i] = extra[i];
        }
        parsed.implementations = all;
        return parsed;
    }

    /// The state before the batch, as the check needs it: the proxies under the prefix, those the batch wrote, each with
    /// the implementation it is read as and its storage laid out by, the pauses found, and the known addresses so far.
    struct Sides {
        uint256 afterwards;
        DeploymentSnapLib.Target[] before;
        DeploymentSnapLib.Target[] stored;
        DeploymentSnapLib.Pause[] found;
        address[] known;
    }

    /// The targets and known addresses before the batch, and what the tokens answered then; ends at the state after it,
    /// whose snapshot it takes.
    function _before(
        Check memory check,
        DeploymentSnapLib.Listing memory parsed,
        Vm.AccountAccess[] memory accesses,
        Token[] memory tokens,
        function(address, uint256) returns (bytes32) slotAt
    ) private returns (Sides memory sides) {
        sides.afterwards = vm.snapshotState();
        vm.revertToState(check.before);
        DeploymentSnapLib.Pause[] memory none = new DeploymentSnapLib.Pause[](0);
        DeploymentSnapLib.Pause[] memory found;
        (sides.before, found) = DeploymentSnapLib.targets(parsed, check.prefix, none, slotAt);
        address[] memory written = DeploymentDiffLib.proxiesWritten(parsed, accesses);
        (sides.stored, sides.found) = DeploymentSnapLib.targetsOf(parsed, written, found, slotAt);
        sides.known = DeploymentSnapLib.union(DeploymentSnapLib.proxiesOf(sides.before), check.known);
        sides.known = DeploymentSnapLib.union(sides.known, DeploymentSnapLib.returnedAddresses(parsed, sides.before));
        _answers(tokens, true);
        vm.revertToState(sides.afterwards);
    }

    /// The type each written proxy's storage is laid out by: the implementation it was read as before the batch.
    function _layouts(
        DeploymentSnapLib.Target[] memory stored
    ) private pure returns (DeploymentDiffLib.Layout[] memory layouts) {
        layouts = new DeploymentDiffLib.Layout[](stored.length);
        for (uint256 i = 0; i < stored.length; ++i) {
            layouts[i] = DeploymentDiffLib.Layout(stored[i].proxy.proxy, stored[i].contractType);
        }
    }

    /// The reads before and after the batch, at the same known addresses, and what the tokens answer after it; ends at
    /// the state after it.
    function _reads(
        Check memory check,
        DeploymentSnapLib.Listing memory parsed,
        DeploymentDiffLib.Diff memory diff,
        Token[] memory tokens,
        Sides memory sides,
        function(address, uint256) returns (bytes32) slotAt
    ) private returns (Reads memory reads) {
        // the batch's own pauses first: a proxy it paused is read as it was read before the batch
        DeploymentSnapLib.Pause[] memory given = _joinedPauses(_batchPauses(diff.paused, sides.before), sides.found);
        (DeploymentSnapLib.Target[] memory later, ) = DeploymentSnapLib.targets(parsed, check.prefix, given, slotAt);
        address[] memory known = DeploymentSnapLib.union(
            sides.known,
            DeploymentSnapLib.returnedAddresses(parsed, later)
        );
        known = DeploymentSnapLib.union(known, diff.keys);
        known = DeploymentSnapLib.union(known, _parties(tokens));
        _answers(tokens, false);

        vm.revertToState(check.before);
        reads.before = DeploymentSnapLib.readings(parsed, sides.before, known, false);
        vm.revertToState(sides.afterwards);
        reads.afterwards = DeploymentSnapLib.readings(parsed, later, known, false);
    }

    /// A pause by the batch for each proxy under the prefix it paused, read as it was before the batch.
    function _batchPauses(
        address[] memory paused,
        DeploymentSnapLib.Target[] memory before
    ) private pure returns (DeploymentSnapLib.Pause[] memory pauses) {
        pauses = new DeploymentSnapLib.Pause[](paused.length);
        uint256 count;
        for (uint256 i = 0; i < paused.length; ++i) {
            for (uint256 t = 0; t < before.length; ++t) {
                if (before[t].proxy.proxy == paused[i]) {
                    pauses[count++] = DeploymentSnapLib.Pause(paused[i], before[t].readAs, 0, true);
                }
            }
        }
        assembly ("memory-safe") {
            mstore(pauses, count)
        }
    }

    function _joinedPauses(
        DeploymentSnapLib.Pause[] memory first,
        DeploymentSnapLib.Pause[] memory second
    ) private pure returns (DeploymentSnapLib.Pause[] memory joined) {
        joined = new DeploymentSnapLib.Pause[](first.length + second.length);
        for (uint256 i = 0; i < first.length; ++i) {
            joined[i] = first[i];
        }
        for (uint256 i = 0; i < second.length; ++i) {
            joined[first.length + i] = second[i];
        }
    }

    // ── the transfer rule ─────────────────────────────────────────────────────────────────────────

    /// Each token that logged a `Transfer`, its parties' net movements and its supply's, in the order logged.
    function _tokens(Vm.Log[] memory logs) private pure returns (Token[] memory tokens) {
        tokens = new Token[](logs.length);
        uint256 count;
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.topics.length != 3 || log.topics[0] != TRANSFER || log.data.length != 32) {
                continue;
            }
            uint256 index = count;
            for (uint256 t = 0; t < count; ++t) {
                if (tokens[t].token == log.emitter) {
                    index = t;
                }
            }
            if (index == count) {
                tokens[count++] = Token(
                    log.emitter,
                    new address[](0),
                    new int256[](0),
                    0,
                    new uint256[](0),
                    new uint256[](0),
                    0,
                    0
                );
            }
            uint256 value = abi.decode(log.data, (uint256));
            if (value > uint256(type(int256).max)) {
                revert TransferBeyondSignedRange(log.emitter, value);
            }
            address from = address(uint160(uint256(log.topics[1])));
            address to = address(uint160(uint256(log.topics[2])));
            _move(tokens[index], from, -int256(value));
            _move(tokens[index], to, int256(value));
        }
        assembly ("memory-safe") {
            mstore(tokens, count)
        }
    }

    /// A party's movement: the zero address is a mint or a burn, a movement of the supply the other way.
    function _move(Token memory token, address party, int256 amount) private pure {
        if (party == address(0)) {
            token.supply -= amount;
            return;
        }
        for (uint256 i = 0; i < token.parties.length; ++i) {
            if (token.parties[i] == party) {
                token.nets[i] += amount;
                return;
            }
        }
        address[] memory parties = new address[](token.parties.length + 1);
        int256[] memory nets = new int256[](token.parties.length + 1);
        for (uint256 i = 0; i < token.parties.length; ++i) {
            parties[i] = token.parties[i];
            nets[i] = token.nets[i];
        }
        parties[token.parties.length] = party;
        nets[token.parties.length] = amount;
        token.parties = parties;
        token.nets = nets;
    }

    /// What each token's `totalSupply()` and each party's `balanceOf` answer, as the ones before or after.
    function _answers(Token[] memory tokens, bool before) private view {
        for (uint256 t = 0; t < tokens.length; ++t) {
            Token memory token = tokens[t];
            uint256 supply = _ask(token.token, abi.encodeWithSignature("totalSupply()"));
            uint256[] memory balances = new uint256[](token.parties.length);
            for (uint256 i = 0; i < token.parties.length; ++i) {
                balances[i] = _ask(token.token, abi.encodeWithSignature("balanceOf(address)", token.parties[i]));
            }
            if (before) {
                (token.supplyBefore, token.balancesBefore) = (supply, balances);
            } else {
                (token.supplyAfter, token.balancesAfter) = (supply, balances);
            }
        }
    }

    function _ask(address token, bytes memory call) private view returns (uint256) {
        (bool answered, bytes memory answer) = token.staticcall{gas: DeploymentSnapLib.VIEW_GAS}(call);
        if (!answered || answer.length < 32) {
            revert ATokenDoesNotAnswer(token, call);
        }
        return abi.decode(answer, (uint256));
    }

    function _parties(Token[] memory tokens) private pure returns (address[] memory parties) {
        for (uint256 t = 0; t < tokens.length; ++t) {
            parties = DeploymentSnapLib.union(parties, tokens[t].parties);
        }
    }

    /// The rule's failures for one token: each view that moved other than the logs say.
    function _transferFailures(Token memory token, Judged memory judged) private pure {
        int256 supplyMoved = int256(token.supplyAfter) - int256(token.supplyBefore);
        if (supplyMoved != token.supply) {
            _fail(judged, _misreported(token.token, "totalSupply()", supplyMoved, token.supply));
        }
        for (uint256 i = 0; i < token.parties.length; ++i) {
            int256 moved = int256(token.balancesAfter[i]) - int256(token.balancesBefore[i]);
            if (moved != token.nets[i]) {
                string memory view_ = string.concat("balanceOf(", vm.toString(token.parties[i]), ")");
                _fail(judged, _misreported(token.token, view_, moved, token.nets[i]));
            }
        }
    }

    function _misreported(
        address token,
        string memory view_,
        int256 moved,
        int256 logged
    ) private pure returns (string memory) {
        string memory head = string.concat("transfers: ", vm.toString(token), " ", view_);
        return string.concat(head, " moved by ", vm.toString(moved), ", its transfers by ", vm.toString(logged));
    }

    /// Whether the transfer rule claims a change: a view of a listed token's supply or a party's balance, or a storage
    /// value of it that holds what that view answers before and after: the supply in a value at a fixed slot, which has
    /// no bracket in its label, and a balance in an entry keyed by the party.
    function _byTransfers(
        DeploymentDiffLib.Change memory change,
        DeploymentSnapLib.Listing memory parsed,
        Token[] memory tokens
    ) private pure returns (bool) {
        for (uint256 t = 0; t < tokens.length; ++t) {
            Token memory token = tokens[t];
            if (!_isKeyOf(parsed, change.contractKey, token.token)) {
                continue;
            }
            bool supplyValues = _same(change.before, vm.toString(token.supplyBefore)) &&
                _same(change.afterwards, vm.toString(token.supplyAfter));
            bool atAFixedSlot = !_contains(change.label, "[") && !_contains(change.label, "(");
            if (_same(change.label, "totalSupply()") || (supplyValues && atAFixedSlot)) {
                return true;
            }
            for (uint256 i = 0; i < token.parties.length; ++i) {
                string memory party = vm.toString(token.parties[i]);
                if (_same(change.label, string.concat("balanceOf(", party, ")"))) {
                    return true;
                }
                bool balanceValues = _same(change.before, vm.toString(token.balancesBefore[i])) &&
                    _same(change.afterwards, vm.toString(token.balancesAfter[i]));
                if (balanceValues && _contains(change.label, string.concat("[", party, "]"))) {
                    return true;
                }
            }
        }
        return false;
    }

    function _isKeyOf(
        DeploymentSnapLib.Listing memory parsed,
        string memory contractKey,
        address account
    ) private pure returns (bool) {
        for (uint256 i = 0; i < parsed.proxies.length; ++i) {
            if (parsed.proxies[i].proxy == account && _same(parsed.proxies[i].key, contractKey)) {
                return true;
            }
        }
        return false;
    }

    // ── judging ───────────────────────────────────────────────────────────────────────────────────

    function _judge(
        Claim[] memory claims,
        DeploymentSnapLib.Listing memory parsed,
        DeploymentDiffLib.Diff memory diff,
        Token[] memory tokens,
        Reads memory reads,
        uint256 blockTime
    ) private pure returns (Judged memory judged) {
        judged.changes = _changes(reads, diff.changes);
        judged.coveredBy = new string[](judged.changes.length);
        judged.failures = new string[](judged.changes.length * 2 + claims.length + _partyCount(tokens) + tokens.length);
        uint256[] memory claimed = new uint256[](claims.length);
        for (uint256 c = 0; c < judged.changes.length; ++c) {
            DeploymentDiffLib.Change memory change = judged.changes[c];
            if (_byTransfers(change, parsed, tokens)) {
                judged.coveredBy[c] = "transfers";
            }
            for (uint256 k = 0; k < claims.length; ++k) {
                if (!_matches(claims[k].contractKey, change.contractKey) || !_matches(claims[k].label, change.label)) {
                    continue;
                }
                ++claimed[k];
                (bool holds, string memory expected) = _holds(claims[k], change, blockTime);
                if (!holds) {
                    string memory where = string.concat(change.contractKey, "\t", change.label);
                    _fail(judged, string.concat("wrong: ", where, ": expected ", expected, ", found ", _found(change)));
                }
                judged.coveredBy[c] = _described(claims[k]);
            }
            if (bytes(judged.coveredBy[c]).length == 0) {
                _fail(judged, string.concat("unclaimed: ", _shown(change)));
            }
        }
        for (uint256 k = 0; k < claims.length; ++k) {
            if (claimed[k] == 0) {
                _fail(judged, string.concat("claimed nothing: ", claims[k].contractKey, "\t", claims[k].label));
            }
        }
        for (uint256 t = 0; t < tokens.length; ++t) {
            _transferFailures(tokens[t], judged);
        }
    }

    function _partyCount(Token[] memory tokens) private pure returns (uint256 count) {
        for (uint256 t = 0; t < tokens.length; ++t) {
            count += tokens[t].parties.length;
        }
    }

    /// Whether a change is what the claim says, and what the claim expected.
    function _holds(
        Claim memory claim,
        DeploymentDiffLib.Change memory change,
        uint256 blockTime
    ) private pure returns (bool, string memory) {
        if (claim.expectation == Expectation.Becomes) {
            return (_same(change.afterwards, claim.value), claim.value);
        }
        if (claim.expectation == Expectation.BecomesTheBlockTime) {
            string memory time = vm.toString(blockTime);
            return (_same(change.afterwards, time), string.concat(time, " (the block time)"));
        }
        if (claim.expectation == Expectation.IncreasesBy) {
            string memory expected = string.concat("an increase by ", claim.value);
            if (!_isNumber(change.before) || !_isNumber(change.afterwards)) {
                return (false, expected);
            }
            uint256 before = vm.parseUint(change.before);
            uint256 afterwards = vm.parseUint(change.afterwards);
            return (afterwards >= before && afterwards - before == vm.parseUint(claim.value), expected);
        }
        if (claim.expectation == Expectation.Reverts) {
            string memory reverted = string.concat("reverted ", claim.value);
            return (_same(change.afterwards, reverted), reverted);
        }
        return (true, "");
    }

    function _described(Claim memory claim) private pure returns (string memory) {
        if (claim.expectation == Expectation.Becomes) {
            return string.concat("becomes ", claim.value);
        }
        if (claim.expectation == Expectation.BecomesTheBlockTime) {
            return "becomes the block time";
        }
        if (claim.expectation == Expectation.IncreasesBy) {
            return string.concat("increases by ", claim.value);
        }
        if (claim.expectation == Expectation.Reverts) {
            return string.concat("reverts ", claim.value);
        }
        return string.concat("changes: ", claim.value);
    }

    /// The changes: each reading that differs, appears or goes, in the order read, then each storage change of the
    /// diff no reading has the same contract key and label as.
    function _changes(
        Reads memory reads,
        DeploymentDiffLib.Change[] memory stored
    ) private pure returns (DeploymentDiffLib.Change[] memory found) {
        DeploymentSnapLib.Reading[] memory before = reads.before;
        DeploymentSnapLib.Reading[] memory afterwards = reads.afterwards;
        found = new DeploymentDiffLib.Change[](before.length + afterwards.length + stored.length);
        uint256 count;
        bytes32[] memory afterIds = new bytes32[](afterwards.length);
        for (uint256 j = 0; j < afterwards.length; ++j) {
            afterIds[j] = _id(afterwards[j].contractKey, afterwards[j].label);
        }
        bool[] memory matched = new bool[](afterwards.length);
        uint256 cursor;
        for (uint256 i = 0; i < before.length; ++i) {
            (bool present, uint256 j) = _find(afterIds, _id(before[i].contractKey, before[i].label), cursor);
            string memory value = present ? afterwards[j].value : NONE;
            if (present) {
                matched[j] = true;
                cursor = j + 1;
            }
            if (!_same(before[i].value, value)) {
                found[count++] = DeploymentDiffLib.Change(
                    before[i].contractKey,
                    before[i].label,
                    before[i].value,
                    value
                );
            }
        }
        for (uint256 j = 0; j < afterwards.length; ++j) {
            if (!matched[j]) {
                DeploymentSnapLib.Reading memory appeared = afterwards[j];
                found[count++] = DeploymentDiffLib.Change(appeared.contractKey, appeared.label, NONE, appeared.value);
            }
        }
        uint256 read = count;
        for (uint256 s = 0; s < stored.length; ++s) {
            if (!_hasChange(found, read, stored[s])) {
                found[count++] = stored[s];
            }
        }
        assembly ("memory-safe") {
            mstore(found, count)
        }
    }

    /// The index of `id` among `ids`, searched from `cursor` on, then from the start: the reads keep one order.
    function _find(bytes32[] memory ids, bytes32 id, uint256 cursor) private pure returns (bool, uint256) {
        for (uint256 j = cursor; j < ids.length; ++j) {
            if (ids[j] == id) {
                return (true, j);
            }
        }
        for (uint256 j = 0; j < cursor && j < ids.length; ++j) {
            if (ids[j] == id) {
                return (true, j);
            }
        }
        return (false, 0);
    }

    function _hasChange(
        DeploymentDiffLib.Change[] memory found,
        uint256 count,
        DeploymentDiffLib.Change memory change
    ) private pure returns (bool) {
        bytes32 id = _id(change.contractKey, change.label);
        for (uint256 i = 0; i < count; ++i) {
            if (_id(found[i].contractKey, found[i].label) == id) {
                return true;
            }
        }
        return false;
    }

    function _id(string memory contractKey, string memory label) private pure returns (bytes32) {
        return keccak256(abi.encode(contractKey, label));
    }

    // ── the files ─────────────────────────────────────────────────────────────────────────────────

    /// `before.tsv` and `after.tsv`, a reading a line; `changes.tsv`, a change and what claims it a line; and
    /// `outside.tsv`, a write outside the listing a line, in hex.
    function _write(
        string memory folder,
        Reads memory reads,
        Judged memory judged,
        DeploymentDiffLib.Diff memory diff
    ) private {
        vm.createDir(folder, true);
        _writeReadings(string.concat(folder, "/before.tsv"), reads.before);
        _writeReadings(string.concat(folder, "/after.tsv"), reads.afterwards);
        string memory changesPath = string.concat(folder, "/changes.tsv");
        vm.writeFile(changesPath, "");
        for (uint256 c = 0; c < judged.changes.length; ++c) {
            DeploymentDiffLib.Change memory change = judged.changes[c];
            string memory claimedBy = bytes(judged.coveredBy[c]).length == 0 ? "unclaimed" : judged.coveredBy[c];
            string memory values = string.concat(change.before, "\t", change.afterwards, "\t", claimedBy);
            vm.writeLine(changesPath, string.concat(change.contractKey, "\t", change.label, "\t", values));
        }
        string memory outsidePath = string.concat(folder, "/outside.tsv");
        vm.writeFile(outsidePath, "");
        for (uint256 w = 0; w < diff.outside.length; ++w) {
            DeploymentDiffLib.Write memory write = diff.outside[w];
            string memory words = string.concat(vm.toString(write.before), "\t", vm.toString(write.afterwards));
            vm.writeLine(
                outsidePath,
                string.concat(vm.toString(write.account), "\t", vm.toString(write.slot), "\t", words)
            );
        }
    }

    function _writeReadings(string memory path, DeploymentSnapLib.Reading[] memory readings) private {
        vm.writeFile(path, "");
        for (uint256 i = 0; i < readings.length; ++i) {
            vm.writeLine(path, DeploymentSnapLib.line(readings[i]));
        }
    }

    // ── small helpers ─────────────────────────────────────────────────────────────────────────────

    function _fail(Judged memory judged, string memory failure) private pure {
        if (judged.failureCount == judged.failures.length) {
            string[] memory larger = new string[](judged.failures.length * 2 + 1);
            for (uint256 i = 0; i < judged.failureCount; ++i) {
                larger[i] = judged.failures[i];
            }
            judged.failures = larger;
        }
        judged.failures[judged.failureCount++] = failure;
    }

    function _shown(DeploymentDiffLib.Change memory change) private pure returns (string memory) {
        return string.concat(change.contractKey, "\t", change.label, "\t", change.before, " -> ", change.afterwards);
    }

    function _found(DeploymentDiffLib.Change memory change) private pure returns (string memory) {
        return string.concat(change.before, " -> ", change.afterwards);
    }

    function _joined(string[] memory lines, uint256 count) private pure returns (string memory joined) {
        for (uint256 i = 0; i < count; ++i) {
            joined = i == 0 ? lines[i] : string.concat(joined, "\n", lines[i]);
        }
    }

    /// Whether `text` matches `pattern`, in which `*` matches any run of characters, none included.
    function _matches(string memory pattern, string memory text) private pure returns (bool) {
        bytes memory p = bytes(pattern);
        bytes memory t = bytes(text);
        uint256 pi;
        uint256 ti;
        uint256 star = type(uint256).max;
        uint256 mark;
        while (ti < t.length) {
            if (pi < p.length && p[pi] != "*" && p[pi] == t[ti]) {
                ++pi;
                ++ti;
            } else if (pi < p.length && p[pi] == "*") {
                star = pi++;
                mark = ti;
            } else if (star != type(uint256).max) {
                pi = star + 1;
                ti = ++mark;
            } else {
                return false;
            }
        }
        while (pi < p.length && p[pi] == "*") {
            ++pi;
        }
        return pi == p.length;
    }

    function _isNumber(string memory text) private pure returns (bool) {
        bytes memory raw = bytes(text);
        if (raw.length == 0) {
            return false;
        }
        for (uint256 i = 0; i < raw.length; ++i) {
            if (raw[i] < "0" || raw[i] > "9") {
                return false;
            }
        }
        return true;
    }

    function _contains(string memory text, string memory part) private pure returns (bool) {
        bytes memory raw = bytes(text);
        bytes memory wanted = bytes(part);
        if (wanted.length > raw.length) {
            return false;
        }
        for (uint256 i = 0; i + wanted.length <= raw.length; ++i) {
            bool here = true;
            for (uint256 j = 0; j < wanted.length && here; ++j) {
                here = raw[i + j] == wanted[j];
            }
            if (here) {
                return true;
            }
        }
        return false;
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
