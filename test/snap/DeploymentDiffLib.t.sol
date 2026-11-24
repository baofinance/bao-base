// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {BaoERC1967Proxy} from "@bao/BaoERC1967Proxy.sol";
import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";
import {DeploymentSnapLib} from "@bao-test/snap/DeploymentSnapLib.sol";
import {DeploymentDiffLib} from "@bao-test/snap/DeploymentDiffLib.sol";

/// An external library that writes the storage of the contract that calls it.
library DiffLedgerLib {
    function credit(mapping(address => uint256) storage balances, address who, uint256 amount) public {
        balances[who] += amount;
    }
}

/// The implementation a diffed proxy runs: a value in each place a write can land.
contract DiffVault {
    struct Record {
        uint256 amount;
        uint64 at;
        bool open;
    }

    struct Split {
        address to;
        uint96 share;
        uint256 paid;
    }

    /// @custom:storage-location erc7201:bao.storage.DiffVault
    struct Spaced {
        uint256 total;
        mapping(address => uint256) owed;
    }

    error Refused();

    // keccak256(abi.encode(uint256(keccak256("bao.storage.DiffVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SPACED = 0xfe30ad3fcae86a916bd4b8d6c7cf66dac3118d9443c5751f74f7452728652200;

    uint64 public count;
    bool public open;
    address public token;
    mapping(address => uint256) public balances;
    mapping(uint256 => Record) public history;
    mapping(bytes32 => bool) public roles;
    mapping(address => mapping(uint256 => uint256)) public marks;
    Split[] public splits;
    uint64[] public stamps;

    function setCount(uint64 to) external {
        count = to;
    }

    function setOpen(bool to) external {
        open = to;
    }

    function credit(address who, uint256 amount) external {
        balances[who] += amount;
    }

    function creditThroughTheLibrary(address who, uint256 amount) external {
        DiffLedgerLib.credit(balances, who, amount);
    }

    function record(uint256 index, uint256 amount, uint64 at) external {
        history[index].amount = amount;
        history[index].at = at;
    }

    function grant(bytes32 role) external {
        roles[role] = true;
    }

    function mark(address who, uint256 index, uint256 value) external {
        marks[who][index] = value;
    }

    function addSplit(address to, uint96 share, uint256 paid) external {
        splits.push(Split(to, share, paid));
    }

    function stamp(uint64 value) external {
        stamps.push(value);
    }

    function setSpaced(uint256 total, address who, uint256 owed) external {
        Spaced storage $ = _spaced();
        $.total = total;
        $.owed[who] = owed;
    }

    function writeSlot(bytes32 slot, bytes32 value) external {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    /// Writes, then reverts: a call a batch makes and catches.
    function writeThenRevert() external {
        count = 9;
        revert Refused();
    }

    function upgradeTo(address next) external {
        ERC1967Utils.upgradeToAndCall(next, "");
    }

    function _spaced() private pure returns (Spaced storage $) {
        assembly ("memory-safe") {
            $.slot := SPACED
        }
    }
}

/// The vault's next version: a value at a slot the first has none at.
contract DiffVaultNext is DiffVault {
    uint256 public extra;

    function setExtra(uint256 to) external {
        extra = to;
    }
}

/// A one-shot implementation that empties the vault: it declares none of the storage it writes, so its layout names
/// none of it.
contract DiffVaultEmptier {
    function empty(address who) external {
        bytes32 entry = keccak256(abi.encode(who, uint256(1)));
        assembly ("memory-safe") {
            sstore(0, 0)
            sstore(entry, 0)
        }
    }
}

/// Calls the library externally, so a test can expect its reverts.
contract DiffHarness {
    function diff(
        string memory listing,
        Vm.AccountAccess[] memory accesses,
        DeploymentDiffLib.Layout[] memory layouts
    ) external view returns (DeploymentDiffLib.Diff memory) {
        return DeploymentDiffLib.diff(DeploymentSnapLib.parse(listing), accesses, layouts);
    }

    function proxiesWritten(
        string memory listing,
        Vm.AccountAccess[] memory accesses
    ) external pure returns (address[] memory) {
        return DeploymentDiffLib.proxiesWritten(DeploymentSnapLib.parse(listing), accesses);
    }
}

contract DeploymentDiffLibTest is Test {
    uint256 private constant SPACED = 0xfe30ad3fcae86a916bd4b8d6c7cf66dac3118d9443c5751f74f7452728652200;
    bytes32 private constant MINTER = keccak256("MINTER");

    address private harness;
    address private implementation;
    address private next;
    address private emptier;
    address private pauser;
    address private vault;
    address private silver;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        harness = address(new DiffHarness());
        implementation = address(new DiffVault());
        next = address(new DiffVaultNext());
        emptier = address(new DiffVaultEmptier());
        pauser = address(new HarborPauser_v1());
        vault = address(new BaoERC1967Proxy(implementation, ""));
        silver = address(new BaoERC1967Proxy(implementation, ""));
    }

    // ── the listing a test names writes by, as bin/snap writes one ────────────────────────────────

    function _proxies() private view returns (string memory) {
        string memory proxies = string.concat(
            string.concat("proxy\tGOLD::vault\t", vm.toString(vault), "\n"),
            string.concat("proxy\tSILVER::vault\t", vm.toString(silver), "\n")
        );
        return
            string.concat(
                proxies,
                string.concat("implementation\t", vm.toString(implementation), "\tDiffVault\n"),
                string.concat("implementation\t", vm.toString(next), "\tDiffVaultNext\n"),
                string.concat("implementation\t", vm.toString(emptier), "\tDiffVaultEmptier\n"),
                string.concat("implementation\t", vm.toString(pauser), "\tHarborPauser_v1\n")
            );
    }

    function _place(uint256 offset, uint256 size, string memory kind) private pure returns (string memory) {
        return string.concat(vm.toString(offset), "\t", vm.toString(size), "\t", kind, "\n");
    }

    /// A `storage` line: `place` is the value's offset, size and kind.
    function _storage(
        string memory contractType,
        string memory label,
        uint256 slot,
        string memory place
    ) private pure returns (string memory) {
        return string.concat("storage\t", contractType, "\t", label, "\t", vm.toString(bytes32(slot)), "\t", place);
    }

    /// An `entry` line: `where` is the key kinds and the slots, `place` the value's offset, size and kind.
    function _entry(
        string memory contractType,
        string memory label,
        uint256 mappingSlot,
        string memory where,
        string memory place
    ) private pure returns (string memory) {
        string memory head = string.concat(
            "entry\t",
            contractType,
            "\t",
            label,
            "\t",
            vm.toString(bytes32(mappingSlot))
        );
        return string.concat(head, "\t", where, "\t", place);
    }

    /// An `element` line: `where` is the element's bytes and the value's slot in it, `place` its offset, size and kind.
    function _element(
        string memory contractType,
        string memory label,
        uint256 arraySlot,
        string memory where,
        string memory place
    ) private pure returns (string memory) {
        string memory head = string.concat(
            "element\t",
            contractType,
            "\t",
            label,
            "\t",
            vm.toString(bytes32(arraySlot))
        );
        return string.concat(head, "\t", where, "\t", place);
    }

    /// The vault's values, as forge lays them out, for a type of it.
    function _layout(string memory t) private pure returns (string memory lines) {
        string memory word = _place(0, 32, "uint");
        lines = _storage(t, "count", 0, _place(0, 8, "uint"));
        lines = string.concat(lines, _storage(t, "open", 0, _place(8, 1, "bool")));
        lines = string.concat(lines, _storage(t, "token", 0, _place(9, 20, "address")));
        lines = string.concat(lines, _entry(t, "balances[{}]", 1, "address\t0", word));
        lines = string.concat(lines, _entry(t, "history[{}].amount", 2, "uint\t0", word));
        lines = string.concat(lines, _entry(t, "history[{}].at", 2, "uint\t1", _place(0, 8, "uint")));
        lines = string.concat(lines, _entry(t, "history[{}].open", 2, "uint\t1", _place(8, 1, "bool")));
        lines = string.concat(lines, _entry(t, "roles[{}]", 3, "bytes32\t0", _place(0, 1, "bool")));
        lines = string.concat(lines, _entry(t, "marks[{}][{}]", 4, "address,uint\t0,0", word));
        lines = string.concat(lines, _storage(t, "splits.length", 5, word));
        lines = string.concat(lines, _element(t, "splits[{}].to", 5, "64\t0", _place(0, 20, "address")));
        lines = string.concat(lines, _element(t, "splits[{}].share", 5, "64\t0", _place(20, 12, "uint")));
        lines = string.concat(lines, _element(t, "splits[{}].paid", 5, "64\t1", word));
        lines = string.concat(lines, _storage(t, "stamps.length", 6, word));
        lines = string.concat(lines, _element(t, "stamps[{}]", 6, "8\t0", _place(0, 8, "uint")));
        lines = string.concat(lines, _storage(t, "bao.storage.DiffVault.total", SPACED, word));
        lines = string.concat(lines, _entry(t, "bao.storage.DiffVault.owed[{}]", SPACED + 1, "address\t0", word));
    }

    function _listing() private view returns (string memory) {
        string memory nextOnly = _storage("DiffVaultNext", "extra", 7, _place(0, 32, "uint"));
        return string.concat(_proxies(), _layout("DiffVault"), _layout("DiffVaultNext"), nextOnly);
    }

    // ── recording and finding a change ────────────────────────────────────────────────────────────

    function _record() private {
        vm.startMappingRecording();
        vm.startStateDiffRecording();
    }

    /// Each vault's storage laid out by the vault's first version, as it was before the batch.
    function _layouts() private view returns (DeploymentDiffLib.Layout[] memory layouts) {
        layouts = new DeploymentDiffLib.Layout[](2);
        layouts[0] = DeploymentDiffLib.Layout(vault, "DiffVault");
        layouts[1] = DeploymentDiffLib.Layout(silver, "DiffVault");
    }

    function _diff() private returns (DeploymentDiffLib.Diff memory) {
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        return DiffHarness(harness).diff(_listing(), accesses, _layouts());
    }

    /// The before and after of the one change of `contractKey` labelled `label`.
    function _change(
        DeploymentDiffLib.Diff memory diff,
        string memory contractKey,
        string memory label
    ) private pure returns (string memory before, string memory afterwards) {
        uint256 found;
        for (uint256 i = 0; i < diff.changes.length; ++i) {
            DeploymentDiffLib.Change memory change = diff.changes[i];
            if (_same(change.contractKey, contractKey) && _same(change.label, label)) {
                (before, afterwards) = (change.before, change.afterwards);
                ++found;
            }
        }
        require(found == 1, string.concat(contractKey, " ", label, ": ", vm.toString(found), " changes"));
    }

    function _assertChange(
        DeploymentDiffLib.Diff memory diff,
        string memory label,
        string memory before,
        string memory afterwards
    ) private pure {
        (string memory found, string memory foundAfter) = _change(diff, "GOLD::vault", label);
        assertEq(found, before, label);
        assertEq(foundAfter, afterwards, label);
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _at(string memory name, address key) private pure returns (string memory) {
        return string.concat(name, "[", vm.toString(key), "]");
    }

    // ── fields ────────────────────────────────────────────────────────────────────────────────────

    function test_namesAFieldByItsLabelAndOnlyTheValuesThatChanged() public {
        // Two values packed in one slot are named each on its own; a third in the slot that did not change is not.
        _record();
        DiffVault(vault).setCount(5);
        DiffVault(vault).setOpen(true);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 2);
        _assertChange(diff, "count", "0", "5");
        _assertChange(diff, "open", "false", "true");
    }

    function test_aSlotWrittenTwiceCountsOnceAndARestoredOneNotAtAll() public {
        // A slot written twice is one change, from before its first write to after its last; a slot written back to
        // what it held is none.
        bytes32 aliceBalance = keccak256(abi.encode(alice, uint256(1)));
        _record();
        DiffVault(vault).setCount(5);
        DiffVault(vault).setCount(7);
        DiffVault(vault).credit(alice, 3);
        DiffVault(vault).writeSlot(aliceBalance, bytes32(0));
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 1);
        _assertChange(diff, "count", "0", "7");
        assertEq(diff.outside.length, 0);
    }

    function test_aWriteInACallThatRevertedIsNoChange() public {
        // A call the batch makes and that reverts writes nothing, though forge records its write; no later write
        // touches the slot it wrote.
        _record();
        try DiffVault(vault).writeThenRevert() {
            revert("writeThenRevert did not revert");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(DiffVault.Refused.selector));
        }
        DiffVault(vault).credit(alice, 3);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 1);
        _assertChange(diff, _at("balances", alice), "0", "3");
    }

    function test_aWriteNoValueCoversIsLabelledBySlot() public {
        // A slot the layout has no value at, and bytes of a slot no value takes, are named by the slot, in hex.
        bytes32 unused = bytes32(uint256(0x1234));
        _record();
        DiffVault(vault).writeSlot(unused, bytes32(uint256(0x99)));
        DiffVault(vault).writeSlot(bytes32(0), bytes32(uint256(1) << 248));
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 2);
        _assertChange(
            diff,
            string.concat("slot ", vm.toString(unused)),
            vm.toString(bytes32(0)),
            vm.toString(bytes32(uint256(0x99)))
        );
        _assertChange(
            diff,
            string.concat("slot ", vm.toString(bytes32(0))),
            vm.toString(bytes32(0)),
            vm.toString(bytes32(uint256(1) << 248))
        );
    }

    // ── mappings ──────────────────────────────────────────────────────────────────────────────────

    function test_namesAMappingEntryByItsKey() public {
        // An entry is named by its key, shown by the key's kind: an address, a number, fixed bytes.
        _record();
        DiffVault(vault).credit(alice, 3);
        DiffVault(vault).record(9, 100, 0);
        DiffVault(vault).grant(MINTER);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 3);
        _assertChange(diff, _at("balances", alice), "0", "3");
        _assertChange(diff, "history[9].amount", "0", "100");
        _assertChange(diff, string.concat("roles[", vm.toString(MINTER), "]"), "false", "true");
    }

    function test_namesANestedMappingEntryByEachKey() public {
        // An entry through two mappings is named by both keys, the outer first.
        _record();
        DiffVault(vault).mark(alice, 9, 4);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 1);
        _assertChange(diff, string.concat(_at("marks", alice), "[9]"), "0", "4");
    }

    function test_namesAMemberOfAStructInAnEntry() public {
        // A struct's members in an entry each by name, a member in the entry's second slot found from the entry.
        _record();
        DiffVault(vault).record(5, 100, 77);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 2);
        _assertChange(diff, "history[5].amount", "0", "100");
        _assertChange(diff, "history[5].at", "0", "77");
    }

    function test_namesAFieldOfANamespace() public {
        // An ERC-7201 namespace's value and its mapping's entry.
        _record();
        DiffVault(vault).setSpaced(31, alice, 37);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 2);
        _assertChange(diff, "bao.storage.DiffVault.total", "0", "31");
        _assertChange(diff, _at("bao.storage.DiffVault.owed", alice), "0", "37");
    }

    function test_givesTheAddressKeysTheBatchWrote() public {
        // Each address an entry written is keyed by, once, in the order first written; a key of another kind is not.
        _record();
        DiffVault(vault).credit(alice, 1);
        DiffVault(vault).mark(bob, 1, 1);
        DiffVault(vault).grant(MINTER);
        DiffVault(vault).setSpaced(1, alice, 1);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.keys.length, 2);
        assertEq(diff.keys[0], alice);
        assertEq(diff.keys[1], bob);
    }

    // ── arrays ────────────────────────────────────────────────────────────────────────────────────

    function test_namesAnElementOfADynamicArray() public {
        // An element is named by its index: a struct's members each, and elements under 32 bytes each in the slot
        // they share.
        _record();
        DiffVault(vault).addSplit(bob, 3, 9);
        DiffVault(vault).addSplit(alice, 4, 0);
        DiffVault(vault).stamp(11);
        DiffVault(vault).stamp(12);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 9);
        _assertChange(diff, "splits.length", "0", "2");
        _assertChange(diff, "splits[0].to", vm.toString(address(0)), vm.toString(bob));
        _assertChange(diff, "splits[0].share", "0", "3");
        _assertChange(diff, "splits[0].paid", "0", "9");
        _assertChange(diff, "splits[1].to", vm.toString(address(0)), vm.toString(alice));
        _assertChange(diff, "splits[1].share", "0", "4");
        _assertChange(diff, "stamps.length", "0", "2");
        _assertChange(diff, "stamps[0]", "0", "11");
        _assertChange(diff, "stamps[1]", "0", "12");
    }

    // ── the code that wrote ───────────────────────────────────────────────────────────────────────

    function test_namesEachWriteByTheImplementationThatMadeIt() public {
        // A batch that upgrades a proxy and then writes through the new implementation: each write is named by the
        // layout of the code that made it. The first version has no value at the slot the second writes; a value both
        // versions lay out is named once.
        _record();
        DiffVault(vault).setCount(1);
        DiffVault(vault).upgradeTo(next);
        DiffVaultNext(vault).setExtra(5);
        DiffVaultNext(vault).setCount(2);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 3);
        _assertChange(diff, "count", "0", "2");
        _assertChange(
            diff,
            DeploymentDiffLib.IMPLEMENTATION,
            string.concat(vm.toString(implementation), " (DiffVault)"),
            string.concat(vm.toString(next), " (DiffVaultNext)")
        );
        _assertChange(diff, "extra", "0", "5");
        assertEq(diff.paused.length, 0);
    }

    function test_aWriteByCodeWithoutALayoutIsNamedByTheProxysStorage() public {
        // A one-shot implementation that declares none of the storage it writes: its writes are named by the layout the
        // proxy's storage has, its first version's.
        DiffVault(vault).setCount(5);
        DiffVault(vault).credit(alice, 3);
        _record();
        DiffVault(vault).upgradeTo(emptier);
        DiffVaultEmptier(vault).empty(alice);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 3);
        _assertChange(
            diff,
            DeploymentDiffLib.IMPLEMENTATION,
            string.concat(vm.toString(implementation), " (DiffVault)"),
            string.concat(vm.toString(emptier), " (DiffVaultEmptier)")
        );
        _assertChange(diff, "count", "5", "0");
        _assertChange(diff, _at("balances", alice), "3", "0");
    }

    function test_givesEachListedProxyTheBatchWrote() public {
        // Each proxy of the listing written, once, in the order first written; an account the listing has no proxy at
        // is not one.
        address plain = address(new DiffVault());
        _record();
        DiffVault(silver).setCount(1);
        DiffVault(plain).setCount(1);
        DiffVault(vault).setCount(1);
        DiffVault(silver).setOpen(true);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        address[] memory written = DiffHarness(harness).proxiesWritten(_listing(), accesses);

        assertEq(written.length, 2);
        assertEq(written[0], silver);
        assertEq(written[1], vault);
    }

    function test_namesAWriteAnExternalLibraryMadeByItsCaller() public {
        // An external library runs in the storage of the implementation that delegate-called it, so its write is
        // named by that implementation's layout.
        _record();
        DiffVault(vault).creditThroughTheLibrary(alice, 3);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 1);
        _assertChange(diff, _at("balances", alice), "0", "3");
    }

    function test_theImplementationSlotIsNamedAndAProxyLeftOnAPauserIsPaused() public {
        // The implementation from before the batch to after it, through two upgrades; a proxy it ends on a pauser is
        // one the batch paused.
        _record();
        DiffVault(vault).upgradeTo(next);
        DiffVaultNext(vault).upgradeTo(pauser);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 1);
        _assertChange(
            diff,
            DeploymentDiffLib.IMPLEMENTATION,
            string.concat(vm.toString(implementation), " (DiffVault)"),
            string.concat(vm.toString(pauser), " (HarborPauser_v1)")
        );
        assertEq(diff.paused.length, 1);
        assertEq(diff.paused[0], vault);
    }

    function test_aWriteOfNoListedLayoutStopsTheDiff() public {
        // A write by code the listing names no type of, in a proxy given no layout, cannot be named: the diff stops,
        // naming the code. Given the proxy's layout, the same write is named by it.
        address stray = address(new DiffVault());
        vm.store(vault, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(stray))));
        _record();
        DiffVault(vault).setCount(5);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        string memory listing = _listing();
        DeploymentDiffLib.Layout[] memory none = new DeploymentDiffLib.Layout[](0);

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentDiffLib.WriteOfNoListedLayout.selector, "GOLD::vault", bytes32(0), stray)
        );
        DiffHarness(harness).diff(listing, accesses, none);

        DeploymentDiffLib.Diff memory diff = DiffHarness(harness).diff(listing, accesses, _layouts());
        assertEq(diff.changes.length, 1);
        _assertChange(diff, "count", "0", "5");
    }

    function test_anImplementationNoStateFileNamesStopsTheDiff() public {
        // An upgrade to an implementation the listing does not name cannot be named either.
        address stray = address(new DiffVault());
        _record();
        DiffVault(vault).upgradeTo(stray);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        string memory listing = _listing();
        DeploymentDiffLib.Layout[] memory layouts = _layouts();

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentSnapLib.ImplementationInNoStateFile.selector, "GOLD::vault", stray)
        );
        DiffHarness(harness).diff(listing, accesses, layouts);
    }

    // ── which accounts ────────────────────────────────────────────────────────────────────────────

    function test_writesOutsideTheListedProxiesAreListedNotNamed() public {
        // Every listed proxy's writes are named, whatever its key; a write in an account the listing has no proxy at
        // is listed as it is.
        address plain = address(new DiffVault());
        _record();
        DiffVault(plain).setCount(5);
        DiffVault(silver).setCount(6);
        DeploymentDiffLib.Diff memory diff = _diff();

        assertEq(diff.changes.length, 1);
        (string memory before, string memory afterwards) = _change(diff, "SILVER::vault", "count");
        assertEq(before, "0");
        assertEq(afterwards, "6");
        assertEq(diff.outside.length, 1);
        assertEq(diff.outside[0].account, plain);
        assertEq(diff.outside[0].slot, bytes32(0));
        assertEq(diff.outside[0].before, bytes32(0));
        assertEq(diff.outside[0].afterwards, bytes32(uint256(5)));
    }
}
