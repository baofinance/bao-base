// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";

/// @title DeploymentSnapLib
/// @notice The readings of a deployment's contracts at the block the active fork is on: for a person to read, and for
/// a check to compare. bin/snap writes the listing it reads, and says what the listing's lines are.
/// @dev Each proxy of the listing whose key starts with the prefix is read. Its implementation is the one its ERC-1967
/// slot holds, named by the listing's `implementation` lines, which come from the state files. A proxy's readings, each
/// a contract key, a label and a value:
/// - `account balance`, `account nonce` and `account code hash`: the proxy's own;
/// - `ERC-1967 implementation`: the address its slot holds, and that implementation's type;
/// - each view of the type, labelled by its signature. A view that takes an address is read at each known address:
///   the proxies read, then each extra one not among them, then each address a view with no argument returns.
/// - each storage value of the type at a fixed slot, labelled by its field, and each value of a mapping keyed by an
///   address, at each known address.
/// A proxy on a pauser (HarborPauser_v1, BaoPauser_v1) answers no view. It is also read for `ERC-1967 implementation
/// before the pause`: the implementation its slot held before it took the pauser. A pause the caller gives is used as
/// given; another is found on the slot's history: first at each block a pause was already found at, then by bisection.
/// Every paused proxy read is put back on that implementation in the fork before any view is read, so a view that calls
/// another paused proxy answers, and each slot is restored after the views. Its storage is read as that
/// implementation's.
/// A value is decoded by its kind: an address checksummed, a bool, a number in decimal, fixed bytes in hex, a string
/// quoted with its quotes and control characters escaped, several outputs in brackets. A raw value is its bytes in hex,
/// and so is an answer too short for its outputs, marked. A view that reverts is read as `reverted` and its revert
/// data: that is the contract's answer at the block.
/// The read is three steps: the targets, the addresses their views return, the readings. A check calls them in turn on
/// the fork as it was before a batch and as it is after it. `read` makes all three at the fork's block.
library DeploymentSnapLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// The gas each view is called with: a block's worth.
    uint256 internal constant VIEW_GAS = 30_000_000;

    /// A pauser that is deployed, and no longer in the source.
    string internal constant BAO_PAUSER = "BaoPauser_v1";

    string private constant NOT_ITS_OUTPUTS = " (not its declared outputs)";

    struct Reading {
        string contractKey;
        string label;
        string value;
    }

    struct Proxy {
        string key;
        address proxy;
    }

    struct Implementation {
        address implementation;
        string contractType;
    }

    struct View {
        string contractType;
        string signature;
        bytes4 selector;
        bool takesAddress;
        /// the kinds, comma-separated; `raw` or `-`
        string outputs;
    }

    /// A value at a fixed slot.
    struct Field {
        string contractType;
        string label;
        uint256 slot;
        uint256 offset;
        uint256 size;
        string kind;
    }

    /// A value through one or more mappings: the first mapping's slot, each key's kind, and for each mapping the slot
    /// counted from its entry, of the next mapping or, for the last, of the value. The label has a `{}` for each key.
    struct Entry {
        string contractType;
        string label;
        uint256 mappingSlot;
        string[] keyKinds;
        uint256[] slots;
        uint256 offset;
        uint256 size;
        string kind;
    }

    /// A value in an element of a dynamic array: the array's slot, the bytes an element takes, and the value's slot
    /// counted from the element's first slot. The label has a `{}` for the index.
    struct Element {
        string contractType;
        string label;
        uint256 arraySlot;
        uint256 elementBytes;
        uint256 slot;
        uint256 offset;
        uint256 size;
        string kind;
    }

    struct Listing {
        Proxy[] proxies;
        Implementation[] implementations;
        string[] absent;
        View[] views;
        Field[] fields;
        Entry[] entries;
        Element[] elements;
    }

    /// The readings made so far, in an array grown as they are added.
    struct Readings {
        Reading[] items;
        uint256 length;
    }

    /// A paused proxy's implementation before the pause, and when the pause was made: at a block, or by the batch a
    /// check is checking.
    struct Pause {
        address proxy;
        address before;
        uint256 pausedAt;
        bool byTheBatch;
    }

    /// A proxy being read: the value its implementation slot holds and that implementation's type, and the
    /// implementation its views and storage are read as, which for a paused proxy is the one before the pause.
    struct Target {
        Proxy proxy;
        bytes32 held;
        string heldType;
        address readAs;
        string contractType;
        bool paused;
        Pause pause;
    }

    error NoProxyUnderThePrefix(string prefix);
    error ImplementationInNoStateFile(string contractKey, address implementation);
    error TypeNotInTheBuild(string contractKey, string contractType);
    error ListingLineNotRead(string line);
    error SlotHistoryDisagrees(address proxy, uint256 blockNumber, bytes32 onChain, bytes32 onTheFork);
    error AnswerNotASlot(address proxy, uint256 blockNumber, bytes answer);

    // ── the listing ───────────────────────────────────────────────────────────────────────────────

    /// The listing's lines, by kind. A line of another kind, or with fields missing, stops it.
    function parse(string memory listing) internal pure returns (Listing memory parsed) {
        string[] memory lines = vm.split(listing, "\n");
        parsed.proxies = new Proxy[](lines.length);
        parsed.implementations = new Implementation[](lines.length);
        parsed.absent = new string[](lines.length);
        parsed.views = new View[](lines.length);
        parsed.fields = new Field[](lines.length);
        parsed.entries = new Entry[](lines.length);
        parsed.elements = new Element[](lines.length);
        uint256[7] memory counts;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (bytes(lines[i]).length == 0) {
                continue;
            }
            string[] memory parts = vm.split(lines[i], "\t");
            bytes32 kind = keccak256(bytes(parts[0]));
            if (kind == keccak256("proxy") && parts.length == 3) {
                parsed.proxies[counts[0]++] = Proxy(parts[1], vm.parseAddress(parts[2]));
            } else if (kind == keccak256("implementation") && parts.length == 3) {
                parsed.implementations[counts[1]++] = Implementation(vm.parseAddress(parts[1]), parts[2]);
            } else if (kind == keccak256("absent") && parts.length == 2) {
                parsed.absent[counts[2]++] = parts[1];
            } else if (kind == keccak256("view") && parts.length == 6) {
                bytes4 selector = bytes4(vm.parseBytes(parts[3]));
                parsed.views[counts[3]++] = View(parts[1], parts[2], selector, same(parts[4], "address"), parts[5]);
            } else if (kind == keccak256("storage") && parts.length == 7) {
                parsed.fields[counts[4]++] = _field(parts);
            } else if (kind == keccak256("entry") && parts.length == 9) {
                parsed.entries[counts[5]++] = _entry(parts);
            } else if (kind == keccak256("element") && parts.length == 9) {
                parsed.elements[counts[6]++] = _element(parts);
            } else {
                revert ListingLineNotRead(lines[i]);
            }
        }
        _shorten(parsed, counts);
    }

    /// Each of the listing's arrays cut to the lines it has. Split from `parse`, which is otherwise too deep for the
    /// stack.
    function _shorten(Listing memory parsed, uint256[7] memory counts) private pure {
        Proxy[] memory proxies = parsed.proxies;
        Implementation[] memory implementations = parsed.implementations;
        string[] memory absent = parsed.absent;
        View[] memory views = parsed.views;
        Field[] memory fields = parsed.fields;
        Entry[] memory entries = parsed.entries;
        Element[] memory elements = parsed.elements;
        assembly ("memory-safe") {
            mstore(proxies, mload(counts))
            mstore(implementations, mload(add(counts, 0x20)))
            mstore(absent, mload(add(counts, 0x40)))
            mstore(views, mload(add(counts, 0x60)))
            mstore(fields, mload(add(counts, 0x80)))
            mstore(entries, mload(add(counts, 0xa0)))
            mstore(elements, mload(add(counts, 0xc0)))
        }
    }

    function _field(string[] memory parts) private pure returns (Field memory field) {
        field.contractType = parts[1];
        field.label = parts[2];
        field.slot = uint256(vm.parseBytes32(parts[3]));
        field.offset = vm.parseUint(parts[4]);
        field.size = vm.parseUint(parts[5]);
        field.kind = parts[6];
    }

    function _entry(string[] memory parts) private pure returns (Entry memory entry) {
        entry.contractType = parts[1];
        entry.label = parts[2];
        entry.mappingSlot = uint256(vm.parseBytes32(parts[3]));
        entry.keyKinds = vm.split(parts[4], ",");
        string[] memory slots = vm.split(parts[5], ",");
        entry.slots = new uint256[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            entry.slots[i] = vm.parseUint(slots[i]);
        }
        entry.offset = vm.parseUint(parts[6]);
        entry.size = vm.parseUint(parts[7]);
        entry.kind = parts[8];
    }

    function _element(string[] memory parts) private pure returns (Element memory element) {
        element.contractType = parts[1];
        element.label = parts[2];
        element.arraySlot = uint256(vm.parseBytes32(parts[3]));
        element.elementBytes = vm.parseUint(parts[4]);
        element.slot = vm.parseUint(parts[5]);
        element.offset = vm.parseUint(parts[6]);
        element.size = vm.parseUint(parts[7]);
        element.kind = parts[8];
    }

    // ── the read ──────────────────────────────────────────────────────────────────────────────────

    /// The readings of every proxy under `prefix`, a paused proxy's earlier implementation found on the chain.
    function read(
        string memory listing,
        string memory prefix,
        address[] memory extraKnown
    ) internal returns (Reading[] memory) {
        return read(listing, prefix, extraKnown, implementationSlotOnChainAt);
    }

    /// The readings of every proxy under `prefix`, storage included, a paused proxy's earlier implementation found in
    /// the history of its implementation slot that `slotAt` gives: the slot's value at a block.
    function read(
        string memory listing,
        string memory prefix,
        address[] memory extraKnown,
        function(address, uint256) returns (bytes32) slotAt
    ) internal returns (Reading[] memory) {
        Listing memory parsed = parse(listing);
        (Target[] memory found, ) = targets(parsed, prefix, new Pause[](0), slotAt);
        address[] memory known = union(proxiesOf(found), extraKnown);
        known = union(known, returnedAddresses(parsed, found));
        return readings(parsed, found, known, true);
    }

    /// Every proxy under `prefix`, with the implementation each is read as, and the pauses: those given, then those
    /// found. For a paused proxy the first pause given for it is used; another is found on its slot's history.
    function targets(
        Listing memory parsed,
        string memory prefix,
        Pause[] memory given,
        function(address, uint256) returns (bytes32) slotAt
    ) internal returns (Target[] memory, Pause[] memory) {
        address[] memory selected = new address[](parsed.proxies.length);
        uint256 count;
        for (uint256 i = 0; i < parsed.proxies.length; ++i) {
            if (startsWith(parsed.proxies[i].key, prefix)) {
                selected[count++] = parsed.proxies[i].proxy;
            }
        }
        if (count == 0) {
            revert NoProxyUnderThePrefix(prefix);
        }
        assembly ("memory-safe") {
            mstore(selected, count)
        }
        return targetsOf(parsed, selected, given, slotAt);
    }

    /// Each proxy of the listing among `proxies`, in the listing's order, with the implementation each is read as, and
    /// the pauses: those given, then those found, as `targets` gives them.
    function targetsOf(
        Listing memory parsed,
        address[] memory proxies,
        Pause[] memory given,
        function(address, uint256) returns (bytes32) slotAt
    ) internal returns (Target[] memory found, Pause[] memory pauses) {
        found = new Target[](parsed.proxies.length);
        pauses = new Pause[](given.length + parsed.proxies.length);
        for (uint256 i = 0; i < given.length; ++i) {
            pauses[i] = given[i];
        }
        uint256 pauseCount = given.length;
        uint256 count;
        for (uint256 i = 0; i < parsed.proxies.length; ++i) {
            if (!_holds(proxies, proxies.length, parsed.proxies[i].proxy)) {
                continue;
            }
            Target memory target = _target(parsed, parsed.proxies[i]);
            if (target.paused) {
                (bool known, Pause memory pause) = _pauseOf(pauses, pauseCount, target.proxy.proxy);
                if (!known) {
                    pause = _findPause(target.proxy.proxy, target.held, pauses, pauseCount, slotAt);
                    pauses[pauseCount++] = pause;
                }
                target.pause = pause;
                target.readAs = pause.before;
                target.contractType = _typeOf(parsed, target.proxy.key, pause.before);
            }
            for (uint256 j = 0; j < parsed.absent.length; ++j) {
                if (same(parsed.absent[j], target.contractType)) {
                    revert TypeNotInTheBuild(target.proxy.key, target.contractType);
                }
            }
            found[count++] = target;
        }
        assembly ("memory-safe") {
            mstore(found, count)
            mstore(pauses, pauseCount)
        }
    }

    /// A proxy's implementation, and whether it is a pauser.
    function _target(Listing memory parsed, Proxy memory proxy) private view returns (Target memory target) {
        target.proxy = proxy;
        target.held = vm.load(proxy.proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        target.readAs = address(uint160(uint256(target.held)));
        target.heldType = _typeOf(parsed, proxy.key, target.readAs);
        target.contractType = target.heldType;
        target.paused = isPauser(target.heldType);
    }

    /// The first of the first `count` pauses that is of `proxy`.
    function _pauseOf(
        Pause[] memory pauses,
        uint256 count,
        address proxy
    ) private pure returns (bool known, Pause memory pause) {
        for (uint256 i = 0; i < count; ++i) {
            if (pauses[i].proxy == proxy) {
                return (true, pauses[i]);
            }
        }
    }

    /// The pause of a proxy that holds `held`: at a block one of the first `count` pauses was made at, when two reads
    /// confirm the slot took its value there, and otherwise by bisection.
    function _findPause(
        address proxy,
        bytes32 held,
        Pause[] memory pauses,
        uint256 count,
        function(address, uint256) returns (bytes32) slotAt
    ) private returns (Pause memory) {
        for (uint256 i = 0; i < count; ++i) {
            uint256 at = pauses[i].pausedAt;
            if (pauses[i].byTheBatch || at == 0 || _triedBefore(pauses, i, at)) {
                continue;
            }
            if (slotAt(proxy, at) != held) {
                continue;
            }
            bytes32 before = slotAt(proxy, at - 1);
            if (before != held) {
                return Pause(proxy, address(uint160(uint256(before))), at, false);
            }
        }
        (address earlier, uint256 pausedAt) = implementationBeforePause(proxy, slotAt);
        return Pause(proxy, earlier, pausedAt, false);
    }

    /// Whether a pause before the `index`th was made at the same block, so it was tried already.
    function _triedBefore(Pause[] memory pauses, uint256 index, uint256 at) private pure returns (bool) {
        for (uint256 i = 0; i < index; ++i) {
            if (!pauses[i].byTheBatch && pauses[i].pausedAt == at) {
                return true;
            }
        }
        return false;
    }

    /// Every distinct address other than zero that a view with no argument of the targets returns, at an output
    /// declared an address.
    function returnedAddresses(
        Listing memory parsed,
        Target[] memory found
    ) internal returns (address[] memory addresses) {
        addresses = new address[](parsed.views.length * 4);
        uint256 count;
        _putBack(found);
        for (uint256 i = 0; i < found.length; ++i) {
            for (uint256 j = 0; j < parsed.views.length; ++j) {
                View memory view_ = parsed.views[j];
                if (view_.takesAddress || !same(view_.contractType, found[i].contractType)) {
                    continue;
                }
                (addresses, count) = _addReturned(found[i].proxy.proxy, view_, addresses, count);
            }
        }
        _restore(found);
        assembly ("memory-safe") {
            mstore(addresses, count)
        }
    }

    /// The addresses one view returns, added to the first `count` of `addresses` when not among them; the array grown
    /// when full.
    function _addReturned(
        address target,
        View memory view_,
        address[] memory addresses,
        uint256 count
    ) private view returns (address[] memory, uint256) {
        if (same(view_.outputs, "raw") || same(view_.outputs, "-")) {
            return (addresses, count);
        }
        string[] memory kinds = vm.split(view_.outputs, ",");
        (bool answered, bytes memory answer) = target.staticcall{gas: VIEW_GAS}(abi.encodePacked(view_.selector));
        if (!answered || answer.length < 32 * kinds.length) {
            return (addresses, count);
        }
        for (uint256 k = 0; k < kinds.length; ++k) {
            uint256 word = _wordAt(answer, 32 * k);
            address returned = address(uint160(word));
            bool isAddress = same(kinds[k], "address") && word >> 160 == 0 && returned != address(0);
            if (isAddress && !_holds(addresses, count, returned)) {
                if (count == addresses.length) {
                    addresses = _grown(addresses);
                }
                addresses[count++] = returned;
            }
        }
        return (addresses, count);
    }

    /// The readings of the targets: their account facts and implementations, their views at the known addresses, and
    /// with `withStorage` their storage.
    function readings(
        Listing memory parsed,
        Target[] memory found,
        address[] memory known,
        bool withStorage
    ) internal returns (Reading[] memory) {
        Readings memory read_ = Readings(new Reading[](64), 0);
        for (uint256 i = 0; i < found.length; ++i) {
            _accountReadings(found[i], read_);
        }
        // Every paused proxy is put back before any view is read, so a view that calls another paused proxy answers.
        _putBack(found);
        for (uint256 i = 0; i < found.length; ++i) {
            for (uint256 j = 0; j < parsed.views.length; ++j) {
                if (same(parsed.views[j].contractType, found[i].contractType)) {
                    _readView(found[i].proxy, parsed.views[j], known, read_);
                }
            }
        }
        _restore(found);
        if (withStorage) {
            for (uint256 i = 0; i < found.length; ++i) {
                _storageReadings(parsed, found[i], known, read_);
            }
        }
        Reading[] memory items = read_.items;
        uint256 length = read_.length;
        assembly ("memory-safe") {
            mstore(items, length)
        }
        return items;
    }

    function _accountReadings(Target memory target, Readings memory read_) private view {
        Proxy memory proxy = target.proxy;
        address held = address(uint160(uint256(target.held)));
        _add(read_, proxy.key, "account balance", vm.toString(proxy.proxy.balance));
        _add(read_, proxy.key, "account nonce", vm.toString(vm.getNonce(proxy.proxy)));
        _add(read_, proxy.key, "account code hash", vm.toString(proxy.proxy.codehash));
        _add(read_, proxy.key, "ERC-1967 implementation", named(held, target.heldType));
        if (target.paused) {
            string memory when = target.pause.byTheBatch
                ? "by the batch"
                : string.concat("at block ", vm.toString(target.pause.pausedAt));
            string memory before = string.concat(named(target.readAs, target.contractType), ", paused ", when);
            _add(read_, proxy.key, "ERC-1967 implementation before the pause", before);
        }
    }

    function _storageReadings(
        Listing memory parsed,
        Target memory target,
        address[] memory known,
        Readings memory read_
    ) private view {
        for (uint256 j = 0; j < parsed.fields.length; ++j) {
            Field memory field = parsed.fields[j];
            if (same(field.contractType, target.contractType)) {
                bytes32 word = vm.load(target.proxy.proxy, bytes32(field.slot));
                _add(read_, target.proxy.key, field.label, valueAt(word, field.offset, field.size, field.kind));
            }
        }
        for (uint256 j = 0; j < parsed.entries.length; ++j) {
            Entry memory entry = parsed.entries[j];
            bool byAddress = entry.keyKinds.length == 1 && same(entry.keyKinds[0], "address");
            if (byAddress && same(entry.contractType, target.contractType)) {
                _readEntry(target.proxy, entry, known, read_);
            }
        }
    }

    /// Each put back on the implementation it is read as, when paused.
    function _putBack(Target[] memory found) private {
        for (uint256 i = 0; i < found.length; ++i) {
            if (found[i].paused) {
                bytes32 readAs = bytes32(uint256(uint160(found[i].readAs)));
                vm.store(found[i].proxy.proxy, ERC1967Utils.IMPLEMENTATION_SLOT, readAs);
            }
        }
    }

    /// Each left holding what its slot held, when paused.
    function _restore(Target[] memory found) private {
        for (uint256 i = 0; i < found.length; ++i) {
            if (found[i].paused) {
                vm.store(found[i].proxy.proxy, ERC1967Utils.IMPLEMENTATION_SLOT, found[i].held);
            }
        }
    }

    /// The readings of one view: once, or at each known address for one that takes an address.
    function _readView(
        Proxy memory proxy,
        View memory view_,
        address[] memory known,
        Readings memory read_
    ) private view {
        if (!view_.takesAddress) {
            _add(
                read_,
                proxy.key,
                view_.signature,
                _call(proxy.proxy, view_.outputs, abi.encodePacked(view_.selector))
            );
            return;
        }
        string memory name = _nameOf(view_.signature);
        for (uint256 i = 0; i < known.length; ++i) {
            string memory label = string.concat(name, "(", vm.toString(known[i]), ")");
            bytes memory data = abi.encodeWithSelector(view_.selector, known[i]);
            _add(read_, proxy.key, label, _call(proxy.proxy, view_.outputs, data));
        }
    }

    /// The readings of a value of a mapping keyed by an address, at each known address.
    function _readEntry(
        Proxy memory proxy,
        Entry memory entry,
        address[] memory known,
        Readings memory read_
    ) private view {
        for (uint256 i = 0; i < known.length; ++i) {
            uint256 slot = uint256(keccak256(abi.encode(known[i], entry.mappingSlot))) + entry.slots[0];
            string memory label = vm.replace(entry.label, "{}", vm.toString(known[i]));
            bytes32 word = vm.load(proxy.proxy, bytes32(slot));
            _add(read_, proxy.key, label, valueAt(word, entry.offset, entry.size, entry.kind));
        }
    }

    /// The implementation slot's history: the block it took the value it holds at the fork's block, and the value it
    /// held before. It is found by bisection over [0, the fork's block], the slot being empty at block 0, and assumes the
    /// slot has held its value since that block. The chain's value at the fork's block must be the fork's.
    function implementationBeforePause(
        address proxy,
        function(address, uint256) returns (bytes32) slotAt
    ) internal returns (address before, uint256 pausedAt) {
        bytes32 held = vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        uint256 high = block.number;
        bytes32 onChain = slotAt(proxy, high);
        if (onChain != held) {
            revert SlotHistoryDisagrees(proxy, high, onChain, held);
        }
        uint256 low;
        bytes32 atLow;
        while (high - low > 1) {
            uint256 middle = (low + high) / 2;
            bytes32 atMiddle = slotAt(proxy, middle);
            if (atMiddle == held) {
                high = middle;
            } else {
                (low, atLow) = (middle, atMiddle);
            }
        }
        if (low == 0) {
            atLow = slotAt(proxy, 0);
        }
        (before, pausedAt) = (address(uint160(uint256(atLow))), high);
    }

    /// The chain's value of a proxy's implementation slot at a block, asked of the active fork's node.
    function implementationSlotOnChainAt(address proxy, uint256 blockNumber) internal returns (bytes32) {
        string memory parameters = string.concat(
            '["',
            vm.toString(proxy),
            '","',
            vm.toString(ERC1967Utils.IMPLEMENTATION_SLOT),
            '","',
            _quantity(blockNumber),
            '"]'
        );
        bytes memory answer = vm.rpc("eth_getStorageAt", parameters);
        if (answer.length != 32) {
            revert AnswerNotASlot(proxy, blockNumber, answer);
        }
        return bytes32(answer);
    }

    /// A reading as one line of a snap file: `<contract key>\t<label>\t<value>`.
    function line(Reading memory reading) internal pure returns (string memory) {
        return string.concat(reading.contractKey, "\t", reading.label, "\t", reading.value);
    }

    // ── values ────────────────────────────────────────────────────────────────────────────────────

    /// A view's answer, or `reverted` and its revert data.
    function _call(address target, string memory outputs, bytes memory data) private view returns (string memory) {
        (bool answered, bytes memory answer) = target.staticcall{gas: VIEW_GAS}(data);
        if (!answered) {
            return string.concat("reverted ", vm.toString(answer));
        }
        if (same(outputs, "raw")) {
            return vm.toString(answer);
        }
        if (same(outputs, "-")) {
            return answer.length == 0 ? "()" : string.concat(vm.toString(answer), NOT_ITS_OUTPUTS);
        }
        string[] memory kinds = vm.split(outputs, ",");
        if (answer.length < 32 * kinds.length) {
            return string.concat(vm.toString(answer), NOT_ITS_OUTPUTS);
        }
        string memory joined;
        for (uint256 i = 0; i < kinds.length; ++i) {
            uint256 word = _wordAt(answer, 32 * i);
            string memory part;
            if (same(kinds[i], "string") || same(kinds[i], "bytes")) {
                (bool whole, bytes memory value) = _dynamicAt(answer, word);
                if (!whole) {
                    return string.concat(vm.toString(answer), NOT_ITS_OUTPUTS);
                }
                part = same(kinds[i], "string") ? _quoted(string(value)) : vm.toString(value);
            } else if (startsWith(kinds[i], "bytes")) {
                // fixed bytes are the word's first bytes
                uint256 size = _digitsAfter(kinds[i], 5);
                part = formatted(kinds[i], word >> ((32 - size) * 8), size);
            } else {
                part = formatted(kinds[i], word, 32);
            }
            joined = i == 0 ? part : string.concat(joined, ", ", part);
        }
        return kinds.length == 1 ? joined : string.concat("(", joined, ")");
    }

    /// A storage value: its bytes at its offset in the slot's word, a signed one sign-extended.
    function valueAt(
        bytes32 word,
        uint256 offset,
        uint256 size,
        string memory kind
    ) internal pure returns (string memory) {
        return formatted(kind, bytesAt(word, offset, size, same(kind, "int")), size);
    }

    /// The `size` bytes at `offset` in a slot's word, sign-extended when `signed`.
    function bytesAt(bytes32 word, uint256 offset, uint256 size, bool signed) internal pure returns (uint256 value) {
        value = uint256(word) >> (offset * 8);
        if (size < 32) {
            uint256 mask = (1 << (size * 8)) - 1;
            value &= mask;
            if (signed && (value >> (size * 8 - 1)) == 1) {
                value |= ~mask;
            }
        }
    }

    /// A value of `size` bytes, read as `kind`.
    function formatted(string memory kind, uint256 value, uint256 size) internal pure returns (string memory) {
        if (same(kind, "address")) {
            return vm.toString(address(uint160(value)));
        }
        if (same(kind, "bool") && value <= 1) {
            return vm.toString(value == 1);
        }
        if (same(kind, "uint")) {
            return vm.toString(value);
        }
        if (same(kind, "int")) {
            return vm.toString(int256(value));
        }
        // fixed bytes, a raw value, and a bool that is neither 0 nor 1
        return hexOf(value, size);
    }

    /// The bytes a head word points to in an ABI answer, or false when they run past its end.
    function _dynamicAt(bytes memory answer, uint256 offset) private pure returns (bool whole, bytes memory value) {
        if (offset > answer.length || answer.length - offset < 32) {
            return (false, value);
        }
        uint256 length = _wordAt(answer, offset);
        if (length > answer.length - offset - 32) {
            return (false, value);
        }
        value = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            value[i] = answer[offset + 32 + i];
        }
        return (true, value);
    }

    function _wordAt(bytes memory data, uint256 offset) private pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), offset))
        }
    }

    /// The low `size` bytes of `value`, in hex.
    function hexOf(uint256 value, uint256 size) internal pure returns (string memory) {
        bytes memory raw = new bytes(size);
        for (uint256 i = 0; i < size; ++i) {
            raw[size - 1 - i] = bytes1(uint8(value >> (8 * i)));
        }
        return vm.toString(raw);
    }

    /// A string in double quotes, a quote, a backslash and each control character escaped.
    function _quoted(string memory text) private pure returns (string memory) {
        bytes memory raw = bytes(text);
        bytes memory escaped = new bytes(raw.length * 4 + 2);
        bytes16 digits = "0123456789abcdef";
        uint256 length;
        escaped[length++] = '"';
        for (uint256 i = 0; i < raw.length; ++i) {
            bytes1 character = raw[i];
            if (character == '"' || character == "\\") {
                escaped[length++] = "\\";
                escaped[length++] = character;
            } else if (character == "\n") {
                escaped[length++] = "\\";
                escaped[length++] = "n";
            } else if (character == "\t") {
                escaped[length++] = "\\";
                escaped[length++] = "t";
            } else if (character == "\r") {
                escaped[length++] = "\\";
                escaped[length++] = "r";
            } else if (uint8(character) < 0x20 || uint8(character) == 0x7f) {
                escaped[length++] = "\\";
                escaped[length++] = "x";
                escaped[length++] = digits[uint8(character) >> 4];
                escaped[length++] = digits[uint8(character) & 0x0f];
            } else {
                escaped[length++] = character;
            }
        }
        escaped[length++] = '"';
        assembly ("memory-safe") {
            mstore(escaped, length)
        }
        return string(escaped);
    }

    // ── small helpers ─────────────────────────────────────────────────────────────────────────────

    /// The type the listing names an implementation by, if it names one.
    function typeOf(
        Listing memory parsed,
        address implementation
    ) internal pure returns (bool found, string memory contractType) {
        for (uint256 i = 0; i < parsed.implementations.length; ++i) {
            if (parsed.implementations[i].implementation == implementation) {
                return (true, parsed.implementations[i].contractType);
            }
        }
    }

    /// The type the listing names an implementation by; a type no state file names stops the read.
    function _typeOf(
        Listing memory parsed,
        string memory contractKey,
        address implementation
    ) private pure returns (string memory contractType) {
        bool found;
        (found, contractType) = typeOf(parsed, implementation);
        if (!found) {
            revert ImplementationInNoStateFile(contractKey, implementation);
        }
    }

    /// Whether a type is one of the pausers, which answer no view.
    function isPauser(string memory contractType) internal pure returns (bool) {
        return same(contractType, type(HarborPauser_v1).name) || same(contractType, BAO_PAUSER);
    }

    /// An implementation by its address and type.
    function named(address implementation, string memory contractType) internal pure returns (string memory) {
        return string.concat(vm.toString(implementation), " (", contractType, ")");
    }

    /// The proxies of the targets.
    function proxiesOf(Target[] memory found) internal pure returns (address[] memory proxies) {
        proxies = new address[](found.length);
        for (uint256 i = 0; i < found.length; ++i) {
            proxies[i] = found[i].proxy.proxy;
        }
    }

    /// The addresses of `first`, then each of `second` not among them, each once.
    function union(address[] memory first, address[] memory second) internal pure returns (address[] memory joined) {
        joined = new address[](first.length + second.length);
        uint256 count;
        for (uint256 i = 0; i < first.length; ++i) {
            if (!_holds(joined, count, first[i])) {
                joined[count++] = first[i];
            }
        }
        for (uint256 i = 0; i < second.length; ++i) {
            if (!_holds(joined, count, second[i])) {
                joined[count++] = second[i];
            }
        }
        assembly ("memory-safe") {
            mstore(joined, count)
        }
    }

    function _add(Readings memory read_, string memory key, string memory label, string memory value) private pure {
        if (read_.length == read_.items.length) {
            Reading[] memory larger = new Reading[](read_.items.length * 2);
            for (uint256 i = 0; i < read_.length; ++i) {
                larger[i] = read_.items[i];
            }
            read_.items = larger;
        }
        read_.items[read_.length++] = Reading(key, label, value);
    }

    function _grown(address[] memory addresses) private pure returns (address[] memory larger) {
        larger = new address[](addresses.length * 2 + 1);
        for (uint256 i = 0; i < addresses.length; ++i) {
            larger[i] = addresses[i];
        }
    }

    /// A signature's name: what comes before its bracket.
    function _nameOf(string memory signature) private pure returns (string memory) {
        bytes memory raw = bytes(signature);
        uint256 length;
        while (length < raw.length && raw[length] != "(") {
            ++length;
        }
        bytes memory name = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            name[i] = raw[i];
        }
        return string(name);
    }

    /// The number written in `text` from `start` on.
    function _digitsAfter(string memory text, uint256 start) private pure returns (uint256 number) {
        bytes memory raw = bytes(text);
        for (uint256 i = start; i < raw.length; ++i) {
            number = number * 10 + (uint8(raw[i]) - 48);
        }
    }

    /// A block number as a JSON-RPC quantity: hex, with no leading zeros.
    function _quantity(uint256 number) private pure returns (string memory) {
        if (number == 0) {
            return "0x0";
        }
        bytes16 digits = "0123456789abcdef";
        bytes memory reversed = new bytes(64);
        uint256 length;
        while (number != 0) {
            reversed[length++] = digits[number & 0x0f];
            number >>= 4;
        }
        bytes memory quantity = new bytes(length + 2);
        quantity[0] = "0";
        quantity[1] = "x";
        for (uint256 i = 0; i < length; ++i) {
            quantity[2 + i] = reversed[length - 1 - i];
        }
        return string(quantity);
    }

    function _holds(address[] memory addresses, uint256 count, address wanted) private pure returns (bool) {
        for (uint256 i = 0; i < count; ++i) {
            if (addresses[i] == wanted) {
                return true;
            }
        }
        return false;
    }

    function startsWith(string memory text, string memory start) internal pure returns (bool) {
        bytes memory raw = bytes(text);
        bytes memory head = bytes(start);
        if (head.length > raw.length) {
            return false;
        }
        for (uint256 i = 0; i < head.length; ++i) {
            if (raw[i] != head[i]) {
                return false;
            }
        }
        return true;
    }

    function same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
