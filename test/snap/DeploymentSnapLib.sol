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
///   the proxies read, then each extra one not among them.
/// - each storage value of the type, labelled by its field. A mapping keyed by an address is read at each known
///   address.
/// A proxy on a pauser (HarborPauser_v1, BaoPauser_v1) answers no view. It is also read for `ERC-1967 implementation
/// before the pause`: the implementation its slot held before the block it took the pauser, found by bisection on the
/// slot's history. Every paused proxy read is put back on that implementation in the fork before any view is read, so a
/// view that calls another paused proxy answers, and each slot is restored after the views. Its storage is read as that
/// implementation's.
/// A value is decoded by its kind: an address checksummed, a bool, a number in decimal, fixed bytes in hex, a string
/// quoted with its quotes and control characters escaped, several outputs in brackets. A raw value is its bytes in hex,
/// and so is an answer too short for its outputs, marked. A view that reverts is read as `reverted` and its revert
/// data: that is the contract's answer at the block.
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

    struct Field {
        string contractType;
        string label;
        bool keyed;
        uint256 mappingSlot;
        /// counted from the entry's slot when keyed
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
    }

    /// The readings made so far, in an array grown as they are added.
    struct Readings {
        Reading[] items;
        uint256 length;
    }

    /// A proxy being read: the value its implementation slot holds, and the implementation its views and storage are
    /// read as, which for a paused proxy is the one before the pause.
    struct Target {
        Proxy proxy;
        bytes32 held;
        address readAs;
        string contractType;
        bool paused;
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
        uint256[5] memory counts;
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
                parsed.views[counts[3]++] = View(parts[1], parts[2], selector, _same(parts[4], "address"), parts[5]);
            } else if (kind == keccak256("storage") && parts.length == 8) {
                parsed.fields[counts[4]++] = _field(parts);
            } else {
                revert ListingLineNotRead(lines[i]);
            }
        }
        Proxy[] memory proxies = parsed.proxies;
        Implementation[] memory implementations = parsed.implementations;
        string[] memory absent = parsed.absent;
        View[] memory views = parsed.views;
        Field[] memory fields = parsed.fields;
        assembly ("memory-safe") {
            mstore(proxies, mload(counts))
            mstore(implementations, mload(add(counts, 0x20)))
            mstore(absent, mload(add(counts, 0x40)))
            mstore(views, mload(add(counts, 0x60)))
            mstore(fields, mload(add(counts, 0x80)))
        }
    }

    /// A `storage` line's field. Split from `parse`, which is otherwise too deep for the stack.
    function _field(string[] memory parts) private pure returns (Field memory field) {
        field.contractType = parts[1];
        field.label = parts[2];
        field.keyed = !_same(parts[3], "-");
        if (field.keyed) {
            field.mappingSlot = uint256(vm.parseBytes32(parts[3]));
        }
        field.slot = uint256(vm.parseBytes32(parts[4]));
        field.offset = vm.parseUint(parts[5]);
        field.size = vm.parseUint(parts[6]);
        field.kind = parts[7];
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

    /// The readings of every proxy under `prefix`, a paused proxy's earlier implementation found in the history of its
    /// implementation slot that `slotAt` gives: the slot's value at a block.
    function read(
        string memory listing,
        string memory prefix,
        address[] memory extraKnown,
        function(address, uint256) returns (bytes32) slotAt
    ) internal returns (Reading[] memory) {
        Listing memory parsed = parse(listing);
        Readings memory readings = Readings(new Reading[](64), 0);
        Target[] memory targets = new Target[](parsed.proxies.length);
        address[] memory known = new address[](parsed.proxies.length + extraKnown.length);
        uint256 count;
        for (uint256 i = 0; i < parsed.proxies.length; ++i) {
            if (_startsWith(parsed.proxies[i].key, prefix)) {
                targets[count] = _target(parsed, parsed.proxies[i], readings, slotAt);
                known[count++] = parsed.proxies[i].proxy;
            }
        }
        if (count == 0) {
            revert NoProxyUnderThePrefix(prefix);
        }
        assembly ("memory-safe") {
            mstore(targets, count)
        }
        for (uint256 i = 0; i < extraKnown.length; ++i) {
            if (!_holds(known, count, extraKnown[i])) {
                known[count++] = extraKnown[i];
            }
        }
        assembly ("memory-safe") {
            mstore(known, count)
        }

        // Every paused proxy is put back before any view is read, so a view that calls another paused proxy answers.
        for (uint256 i = 0; i < targets.length; ++i) {
            if (targets[i].paused) {
                bytes32 readAs = bytes32(uint256(uint160(targets[i].readAs)));
                vm.store(targets[i].proxy.proxy, ERC1967Utils.IMPLEMENTATION_SLOT, readAs);
            }
        }
        for (uint256 i = 0; i < targets.length; ++i) {
            for (uint256 j = 0; j < parsed.views.length; ++j) {
                if (_same(parsed.views[j].contractType, targets[i].contractType)) {
                    _readView(targets[i].proxy, parsed.views[j], known, readings);
                }
            }
        }
        for (uint256 i = 0; i < targets.length; ++i) {
            if (targets[i].paused) {
                vm.store(targets[i].proxy.proxy, ERC1967Utils.IMPLEMENTATION_SLOT, targets[i].held);
            }
        }
        for (uint256 i = 0; i < targets.length; ++i) {
            for (uint256 j = 0; j < parsed.fields.length; ++j) {
                if (_same(parsed.fields[j].contractType, targets[i].contractType)) {
                    _readField(targets[i].proxy, parsed.fields[j], known, readings);
                }
            }
        }

        Reading[] memory items = readings.items;
        uint256 length = readings.length;
        assembly ("memory-safe") {
            mstore(items, length)
        }
        return items;
    }

    /// A proxy's account and implementation readings, and the implementation it is read as. Split from `read`, which is
    /// otherwise too deep for the stack.
    function _target(
        Listing memory parsed,
        Proxy memory proxy,
        Readings memory readings,
        function(address, uint256) returns (bytes32) slotAt
    ) private returns (Target memory target) {
        target.proxy = proxy;
        target.held = vm.load(proxy.proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        target.readAs = address(uint160(uint256(target.held)));
        target.contractType = _typeOf(parsed, proxy.key, target.readAs);
        _add(readings, proxy.key, "account balance", vm.toString(proxy.proxy.balance));
        _add(readings, proxy.key, "account nonce", vm.toString(vm.getNonce(proxy.proxy)));
        _add(readings, proxy.key, "account code hash", vm.toString(proxy.proxy.codehash));
        _add(readings, proxy.key, "ERC-1967 implementation", _named(target.readAs, target.contractType));

        target.paused =
            _same(target.contractType, type(HarborPauser_v1).name) || _same(target.contractType, BAO_PAUSER);
        if (target.paused) {
            uint256 pausedAt;
            (target.readAs, pausedAt) = implementationBeforePause(proxy.proxy, slotAt);
            target.contractType = _typeOf(parsed, proxy.key, target.readAs);
            string memory before = string.concat(
                _named(target.readAs, target.contractType),
                ", paused at block ",
                vm.toString(pausedAt)
            );
            _add(readings, proxy.key, "ERC-1967 implementation before the pause", before);
        }
        for (uint256 i = 0; i < parsed.absent.length; ++i) {
            if (_same(parsed.absent[i], target.contractType)) {
                revert TypeNotInTheBuild(proxy.key, target.contractType);
            }
        }
    }

    /// The readings of one view: once, or at each known address for one that takes an address.
    function _readView(
        Proxy memory proxy,
        View memory view_,
        address[] memory known,
        Readings memory readings
    ) private view {
        if (!view_.takesAddress) {
            _add(
                readings,
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
            _add(readings, proxy.key, label, _call(proxy.proxy, view_.outputs, data));
        }
    }

    /// The readings of one storage field: once, or at each known address for a keyed one.
    function _readField(
        Proxy memory proxy,
        Field memory field,
        address[] memory known,
        Readings memory readings
    ) private view {
        if (!field.keyed) {
            _add(readings, proxy.key, field.label, _stored(proxy.proxy, field, field.slot));
            return;
        }
        for (uint256 i = 0; i < known.length; ++i) {
            uint256 slot = uint256(keccak256(abi.encode(known[i], field.mappingSlot))) + field.slot;
            string memory label = vm.replace(field.label, "{}", vm.toString(known[i]));
            _add(readings, proxy.key, label, _stored(proxy.proxy, field, slot));
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
        if (_same(outputs, "raw")) {
            return vm.toString(answer);
        }
        if (_same(outputs, "-")) {
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
            if (_same(kinds[i], "string") || _same(kinds[i], "bytes")) {
                (bool whole, bytes memory value) = _dynamicAt(answer, word);
                if (!whole) {
                    return string.concat(vm.toString(answer), NOT_ITS_OUTPUTS);
                }
                part = _same(kinds[i], "string") ? _quoted(string(value)) : vm.toString(value);
            } else if (_startsWith(kinds[i], "bytes")) {
                // fixed bytes are the word's first bytes
                uint256 size = _digitsAfter(kinds[i], 5);
                part = _static(kinds[i], word >> ((32 - size) * 8), size);
            } else {
                part = _static(kinds[i], word, 32);
            }
            joined = i == 0 ? part : string.concat(joined, ", ", part);
        }
        return kinds.length == 1 ? joined : string.concat("(", joined, ")");
    }

    /// A storage value: its bytes at its offset in the slot's word, a signed one sign-extended.
    function _stored(address target, Field memory field, uint256 slot) private view returns (string memory) {
        uint256 value = uint256(vm.load(target, bytes32(slot))) >> (field.offset * 8);
        if (field.size < 32) {
            uint256 mask = (1 << (field.size * 8)) - 1;
            value &= mask;
            if (_same(field.kind, "int") && (value >> (field.size * 8 - 1)) == 1) {
                value |= ~mask;
            }
        }
        return _static(field.kind, value, field.size);
    }

    /// A value of `size` bytes, read as `kind`.
    function _static(string memory kind, uint256 value, uint256 size) private pure returns (string memory) {
        if (_same(kind, "address")) {
            return vm.toString(address(uint160(value)));
        }
        if (_same(kind, "bool") && value <= 1) {
            return vm.toString(value == 1);
        }
        if (_same(kind, "uint")) {
            return vm.toString(value);
        }
        if (_same(kind, "int")) {
            return vm.toString(int256(value));
        }
        // fixed bytes, a raw value, and a bool that is neither 0 nor 1
        return _hex(value, size);
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
    function _hex(uint256 value, uint256 size) private pure returns (string memory) {
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

    /// The type the listing names an implementation by; a type no state file names stops the read.
    function _typeOf(
        Listing memory parsed,
        string memory contractKey,
        address implementation
    ) private pure returns (string memory) {
        for (uint256 i = 0; i < parsed.implementations.length; ++i) {
            if (parsed.implementations[i].implementation == implementation) {
                return parsed.implementations[i].contractType;
            }
        }
        revert ImplementationInNoStateFile(contractKey, implementation);
    }

    function _named(address implementation, string memory contractType) private pure returns (string memory) {
        return string.concat(vm.toString(implementation), " (", contractType, ")");
    }

    function _add(Readings memory readings, string memory key, string memory label, string memory value) private pure {
        if (readings.length == readings.items.length) {
            Reading[] memory larger = new Reading[](readings.items.length * 2);
            for (uint256 i = 0; i < readings.length; ++i) {
                larger[i] = readings.items[i];
            }
            readings.items = larger;
        }
        readings.items[readings.length++] = Reading(key, label, value);
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

    function _startsWith(string memory text, string memory start) private pure returns (bool) {
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

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
