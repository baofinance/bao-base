// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {DeploymentSnapLib} from "@bao-test/snap/DeploymentSnapLib.sol";

/// @title DeploymentDiffLib
/// @notice The writes forge recorded, named by the listing bin/snap writes: what a batch changed in storage.
/// @dev A slot written more than once counts once: the value before its first write and after its last. A slot that
/// ends as it began is no change. A write in a proxy of the listing is a change of that proxy, named by two layouts in
/// turn: first that of the code that made it, then, for the bytes that one names no value at, the layout the caller
/// gives for the proxy's storage. The code is that of the access the write is in, or for code the listing does not
/// name, such as an external library, the code of the access that delegate-called it. So a batch that upgrades a proxy
/// and then writes through the new implementation has each write named by the implementation that made it, and code
/// that declares none of the storage it writes, such as a one-shot implementation that empties a contract, has its
/// writes named by the proxy's own layout. The names:
/// - `ERC-1967 implementation`, the address and its type. A proxy whose slot ends on a pauser is paused by the batch.
/// - each `storage` value at the slot whose bytes changed, each packed value on its own;
/// - each `entry` value: the slot is an entry of a mapping whose key and parent forge's mapping recording gives, each
///   parent the entry of the mapping before it, the first the mapping's own slot. The label takes each key.
/// - each `element` value: the slot is in the elements of a dynamic array, from the hash of the array's slot. The label
///   takes the index.
/// - `slot <slot>`, its words in hex, for bytes that changed where no listed value is.
/// A write in any other account is listed as it is, not named.
/// The caller records with `vm.startMappingRecording` and `vm.startStateDiffRecording` before the writes, and calls this
/// before the mapping recording stops.
library DeploymentDiffLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant IMPLEMENTATION = "ERC-1967 implementation";

    struct Change {
        string contractKey;
        string label;
        string before;
        string afterwards;
    }

    struct Write {
        address account;
        bytes32 slot;
        bytes32 before;
        bytes32 afterwards;
    }

    struct Diff {
        Change[] changes;
        Write[] outside;
        /// each proxy whose implementation slot the batch left on a pauser
        address[] paused;
        /// each address a written entry is keyed by, once
        address[] keys;
    }

    /// The type a proxy's storage is laid out by.
    struct Layout {
        address proxy;
        string contractType;
    }

    /// A slot written: its value before the first write and after the last, and the access the last write is in.
    struct Written {
        address account;
        bytes32 slot;
        bytes32 first;
        bytes32 last;
        uint256 access;
    }

    /// A listed value: its label, keys and index filled in, and where it is in its slot.
    struct Value {
        string label;
        uint256 offset;
        uint256 size;
        string kind;
    }

    /// The diff being built, its arrays grown as they are added to, and the bytes of the slot being named that a layout
    /// before named.
    struct Building {
        Change[] changes;
        uint256 changeCount;
        address[] keys;
        uint256 keyCount;
        uint256 named;
    }

    error WriteOfNoListedLayout(string contractKey, bytes32 slot, address code);

    /// Each proxy of the listing the recorded accesses wrote a slot of, once, in the order first written.
    function proxiesWritten(
        DeploymentSnapLib.Listing memory parsed,
        Vm.AccountAccess[] memory accesses
    ) internal pure returns (address[] memory proxies) {
        (Written[] memory written, uint256 count) = _written(accesses);
        proxies = new address[](count);
        uint256 found;
        for (uint256 i = 0; i < count; ++i) {
            (bool listed, ) = _keyOf(parsed, written[i].account);
            bool seen;
            for (uint256 j = 0; j < found && !seen; ++j) {
                seen = proxies[j] == written[i].account;
            }
            if (listed && !seen) {
                proxies[found++] = written[i].account;
            }
        }
        assembly ("memory-safe") {
            mstore(proxies, found)
        }
    }

    /// The changes the recorded accesses made in the listing's proxies, each named by the layouts of the code that made
    /// it and of the proxy's storage, the writes in other accounts, the proxies they paused, and the address keys of
    /// the entries they wrote.
    function diff(
        DeploymentSnapLib.Listing memory parsed,
        Vm.AccountAccess[] memory accesses,
        Layout[] memory layouts
    ) internal view returns (Diff memory result) {
        (Written[] memory written, uint256 count) = _written(accesses);
        Building memory building = Building(new Change[](count + 1), 0, new address[](count + 1), 0, 0);
        result.outside = new Write[](count);
        result.paused = new address[](count);
        uint256 outsideCount;
        uint256 pausedCount;
        for (uint256 i = 0; i < count; ++i) {
            Written memory slot = written[i];
            if (slot.first == slot.last) {
                continue;
            }
            (bool listed, string memory key) = _keyOf(parsed, slot.account);
            if (!listed) {
                result.outside[outsideCount++] = Write(slot.account, slot.slot, slot.first, slot.last);
                continue;
            }
            if (slot.slot == ERC1967Utils.IMPLEMENTATION_SLOT) {
                if (DeploymentSnapLib.isPauser(_implementationChange(parsed, key, slot, building))) {
                    result.paused[pausedCount++] = slot.account;
                }
                continue;
            }
            _nameByBoth(parsed, accesses, layouts, key, slot, building);
        }
        _finish(result, building, outsideCount, pausedCount);
    }

    /// The changes of a written slot: the values the code's layout names, then those the proxy's storage layout names
    /// in bytes the first left; neither layout known stops the diff.
    function _nameByBoth(
        DeploymentSnapLib.Listing memory parsed,
        Vm.AccountAccess[] memory accesses,
        Layout[] memory layouts,
        string memory key,
        Written memory slot,
        Building memory building
    ) private view {
        (bool codeListed, string memory codeType) = _codeType(parsed, accesses, slot.access);
        (bool storageListed, string memory storageType) = _layoutOf(layouts, slot.account);
        if (!codeListed && !storageListed) {
            revert WriteOfNoListedLayout(key, slot.slot, accesses[slot.access].account);
        }
        uint256 covered;
        if (codeListed) {
            covered = _name(parsed, codeType, key, slot, covered, building);
        }
        if (storageListed && !DeploymentSnapLib.same(storageType, codeType)) {
            covered = _name(parsed, storageType, key, slot, covered, building);
        }
        if ((uint256(slot.first ^ slot.last) & ~covered) != 0) {
            Change memory change = Change(
                key,
                string.concat("slot ", vm.toString(slot.slot)),
                vm.toString(slot.first),
                vm.toString(slot.last)
            );
            _addChange(building, change);
        }
    }

    function _layoutOf(
        Layout[] memory layouts,
        address proxy
    ) private pure returns (bool found, string memory contractType) {
        for (uint256 i = 0; i < layouts.length; ++i) {
            if (layouts[i].proxy == proxy) {
                return (true, layouts[i].contractType);
            }
        }
    }

    /// The diff's arrays cut to what was added. Split from `diff`, which is otherwise too deep for the stack.
    function _finish(
        Diff memory result,
        Building memory building,
        uint256 outsideCount,
        uint256 pausedCount
    ) private pure {
        Change[] memory changes = building.changes;
        address[] memory keys = building.keys;
        Write[] memory outside = result.outside;
        address[] memory paused = result.paused;
        uint256 changeCount = building.changeCount;
        uint256 keyCount = building.keyCount;
        assembly ("memory-safe") {
            mstore(changes, changeCount)
            mstore(keys, keyCount)
            mstore(outside, outsideCount)
            mstore(paused, pausedCount)
        }
        result.changes = changes;
        result.keys = keys;
    }

    /// Each slot written, in the order of its first write, and their count.
    function _written(
        Vm.AccountAccess[] memory accesses
    ) private pure returns (Written[] memory written, uint256 count) {
        uint256 total;
        for (uint256 a = 0; a < accesses.length; ++a) {
            total += accesses[a].storageAccesses.length;
        }
        written = new Written[](total);
        for (uint256 a = 0; a < accesses.length; ++a) {
            for (uint256 s = 0; s < accesses[a].storageAccesses.length; ++s) {
                Vm.StorageAccess memory access = accesses[a].storageAccesses[s];
                if (!access.isWrite || access.reverted || accesses[a].reverted) {
                    continue;
                }
                uint256 index = _indexOf(written, count, access.account, access.slot);
                if (index == count) {
                    written[count++] = Written(access.account, access.slot, access.previousValue, access.newValue, a);
                } else {
                    written[index].last = access.newValue;
                    written[index].access = a;
                }
            }
        }
    }

    function _indexOf(
        Written[] memory written,
        uint256 count,
        address account,
        bytes32 slot
    ) private pure returns (uint256) {
        for (uint256 i = 0; i < count; ++i) {
            if (written[i].account == account && written[i].slot == slot) {
                return i;
            }
        }
        return count;
    }

    /// The key of the listing's proxy at `account`, if it is one.
    function _keyOf(
        DeploymentSnapLib.Listing memory parsed,
        address account
    ) private pure returns (bool listed, string memory key) {
        for (uint256 i = 0; i < parsed.proxies.length; ++i) {
            if (parsed.proxies[i].proxy == account) {
                return (true, parsed.proxies[i].key);
            }
        }
    }

    /// The change of a proxy's implementation, and the type it ends on.
    function _implementationChange(
        DeploymentSnapLib.Listing memory parsed,
        string memory key,
        Written memory slot,
        Building memory building
    ) private pure returns (string memory endsOn) {
        address before = address(uint160(uint256(slot.first)));
        address afterwards = address(uint160(uint256(slot.last)));
        string memory beganOn = _implementationType(parsed, key, before);
        endsOn = _implementationType(parsed, key, afterwards);
        Change memory change = Change(
            key,
            IMPLEMENTATION,
            DeploymentSnapLib.named(before, beganOn),
            DeploymentSnapLib.named(afterwards, endsOn)
        );
        _addChange(building, change);
    }

    function _implementationType(
        DeploymentSnapLib.Listing memory parsed,
        string memory key,
        address implementation
    ) private pure returns (string memory contractType) {
        bool found;
        (found, contractType) = DeploymentSnapLib.typeOf(parsed, implementation);
        if (!found) {
            revert DeploymentSnapLib.ImplementationInNoStateFile(key, implementation);
        }
    }

    /// The type of the code that made a write, if the listing names one: the code of its access, or, through each
    /// delegate call or resumption of code the listing does not name, of the access it ran for.
    function _codeType(
        DeploymentSnapLib.Listing memory parsed,
        Vm.AccountAccess[] memory accesses,
        uint256 access
    ) private pure returns (bool found, string memory contractType) {
        uint256 index = access;
        while (true) {
            (found, contractType) = DeploymentSnapLib.typeOf(parsed, accesses[index].account);
            if (found) {
                return (found, contractType);
            }
            VmSafe.AccountAccessKind kind = accesses[index].kind;
            bool sharesItsCallersStorage = kind == VmSafe.AccountAccessKind.DelegateCall ||
                kind == VmSafe.AccountAccessKind.Resume;
            (bool hasCaller, uint256 caller) = _callerOf(accesses, index);
            if (!sharesItsCallersStorage || !hasCaller) {
                return (false, "");
            }
            index = caller;
        }
    }

    /// The access that made the call `index` is: the latest one before it, one call shallower, that runs code.
    function _callerOf(
        Vm.AccountAccess[] memory accesses,
        uint256 index
    ) private pure returns (bool found, uint256 caller) {
        uint64 depth = accesses[index].depth;
        if (depth == 0) {
            return (false, 0);
        }
        for (uint256 i = index; i > 0; --i) {
            Vm.AccountAccess memory candidate = accesses[i - 1];
            if (candidate.depth + 1 == depth && _runsCode(candidate.kind)) {
                return (true, i - 1);
            }
        }
    }

    function _runsCode(VmSafe.AccountAccessKind kind) private pure returns (bool) {
        return
            kind == VmSafe.AccountAccessKind.Call ||
            kind == VmSafe.AccountAccessKind.DelegateCall ||
            kind == VmSafe.AccountAccessKind.CallCode ||
            kind == VmSafe.AccountAccessKind.StaticCall ||
            kind == VmSafe.AccountAccessKind.Create ||
            kind == VmSafe.AccountAccessKind.Resume;
    }

    // ── naming a slot ─────────────────────────────────────────────────────────────────────────────

    /// The changes of one written slot by the listed values of `contractType` it holds, but for values in bytes a layout
    /// before named, `named`; the bytes named after.
    function _name(
        DeploymentSnapLib.Listing memory parsed,
        string memory contractType,
        string memory key,
        Written memory slot,
        uint256 named,
        Building memory building
    ) private view returns (uint256 covered) {
        building.named = named;
        covered = named;
        for (uint256 i = 0; i < parsed.fields.length; ++i) {
            DeploymentSnapLib.Field memory field = parsed.fields[i];
            if (field.slot == uint256(slot.slot) && DeploymentSnapLib.same(field.contractType, contractType)) {
                covered |= _value(key, Value(field.label, field.offset, field.size, field.kind), slot, building);
            }
        }
        for (uint256 i = 0; i < parsed.entries.length; ++i) {
            DeploymentSnapLib.Entry memory entry = parsed.entries[i];
            if (DeploymentSnapLib.same(entry.contractType, contractType)) {
                covered |= _entryValue(key, entry, slot, building);
            }
        }
        for (uint256 i = 0; i < parsed.elements.length; ++i) {
            DeploymentSnapLib.Element memory element = parsed.elements[i];
            if (DeploymentSnapLib.same(element.contractType, contractType)) {
                covered |= _elementValues(key, element, slot, building);
            }
        }
    }

    /// The change of one value in the slot, when its bytes changed and no layout before named them; the bytes it
    /// covers either way.
    function _value(
        string memory key,
        Value memory value,
        Written memory slot,
        Building memory building
    ) private pure returns (uint256 covered) {
        covered = value.size >= 32 ? type(uint256).max : ((1 << (value.size * 8)) - 1) << (value.offset * 8);
        if ((uint256(slot.first ^ slot.last) & covered) == 0 || (covered & building.named) != 0) {
            return covered;
        }
        string memory before = DeploymentSnapLib.valueAt(slot.first, value.offset, value.size, value.kind);
        string memory afterwards = DeploymentSnapLib.valueAt(slot.last, value.offset, value.size, value.kind);
        _addChange(building, Change(key, value.label, before, afterwards));
    }

    /// The change of an entry's value, when the slot is that entry's: each key found by mapping recording, each
    /// parent the slot of the mapping before it, and the first the mapping's own.
    function _entryValue(
        string memory key,
        DeploymentSnapLib.Entry memory entry,
        Written memory slot,
        Building memory building
    ) private view returns (uint256) {
        (bool isEntry, bytes32[] memory keys) = _keysOf(slot.account, slot.slot, entry);
        if (!isEntry) {
            return 0;
        }
        uint256 levels = keys.length;
        string[] memory shown = new string[](levels);
        for (uint256 j = 0; j < levels; ++j) {
            shown[j] = _keyShown(entry.keyKinds[j], keys[j]);
            if (DeploymentSnapLib.same(entry.keyKinds[j], "address")) {
                _addKey(building, address(uint160(uint256(keys[j]))));
            }
        }
        Value memory value = Value(_filled(entry.label, shown), entry.offset, entry.size, entry.kind);
        return _value(key, value, slot, building);
    }

    /// The keys of the entry `slot` is in, outer first, when it is an entry of this mapping: each found by mapping
    /// recording, each parent the slot of the mapping before it, counted from that mapping's entry, and the outermost
    /// parent the mapping's own slot.
    function _keysOf(
        address account,
        bytes32 slot,
        DeploymentSnapLib.Entry memory entry
    ) private view returns (bool isEntry, bytes32[] memory keys) {
        uint256 levels = entry.slots.length;
        keys = new bytes32[](levels);
        uint256 base;
        unchecked {
            base = uint256(slot) - entry.slots[levels - 1];
        }
        for (uint256 j = levels; j > 0; --j) {
            (bool found, bytes32 key, bytes32 parent) = vm.getMappingKeyAndParentOf(account, bytes32(base));
            if (!found) {
                return (false, keys);
            }
            keys[j - 1] = key;
            if (j == 1) {
                return (uint256(parent) == entry.mappingSlot, keys);
            }
            unchecked {
                base = uint256(parent) - entry.slots[j - 2];
            }
        }
    }

    /// The changes of the values of an array's elements the slot holds, when it is in that array's elements: one,
    /// or for elements under 32 bytes, each packed in the slot.
    function _elementValues(
        string memory key,
        DeploymentSnapLib.Element memory element,
        Written memory slot,
        Building memory building
    ) private pure returns (uint256 covered) {
        uint256 data = uint256(keccak256(abi.encode(element.arraySlot)));
        uint256 relative;
        unchecked {
            relative = uint256(slot.slot) - data;
        }
        // an index this far from the array's data is another slot's
        if (relative >= 1 << 64) {
            return 0;
        }
        if (element.elementBytes >= 32) {
            uint256 span = (element.elementBytes + 31) / 32;
            if (relative % span != element.slot) {
                return 0;
            }
            Value memory value = Value(
                _indexed(element.label, relative / span),
                element.offset,
                element.size,
                element.kind
            );
            return _value(key, value, slot, building);
        }
        uint256 perSlot = 32 / element.elementBytes;
        for (uint256 j = 0; j < perSlot; ++j) {
            string memory label = _indexed(element.label, relative * perSlot + j);
            Value memory value = Value(label, j * element.elementBytes, element.elementBytes, element.kind);
            covered |= _value(key, value, slot, building);
        }
    }

    /// The label with its `{}` replaced by the index.
    function _indexed(string memory label, uint256 index) private pure returns (string memory) {
        string[] memory shown = new string[](1);
        shown[0] = vm.toString(index);
        return _filled(label, shown);
    }

    /// A key as its kind shows it: fixed bytes are the word's first bytes, and a raw key is the word.
    function _keyShown(string memory kind, bytes32 key) private pure returns (string memory) {
        if (
            DeploymentSnapLib.startsWith(kind, "bytes") &&
            !DeploymentSnapLib.same(kind, "bytes32") &&
            bytes(kind).length > 5
        ) {
            uint256 size = _digitsAfter(kind, 5);
            return DeploymentSnapLib.hexOf(uint256(key) >> ((32 - size) * 8), size);
        }
        return DeploymentSnapLib.formatted(kind, uint256(key), 32);
    }

    /// The label with each `{}` replaced, in order, by the next of `parts`.
    function _filled(string memory label, string[] memory parts) private pure returns (string memory filled) {
        string[] memory pieces = vm.split(label, "{}");
        filled = pieces[0];
        for (uint256 i = 1; i < pieces.length; ++i) {
            filled = string.concat(filled, i - 1 < parts.length ? parts[i - 1] : "{}", pieces[i]);
        }
    }

    function _digitsAfter(string memory text, uint256 start) private pure returns (uint256 number) {
        bytes memory raw = bytes(text);
        for (uint256 i = start; i < raw.length; ++i) {
            number = number * 10 + (uint8(raw[i]) - 48);
        }
    }

    function _addChange(Building memory building, Change memory change) private pure {
        if (building.changeCount == building.changes.length) {
            Change[] memory larger = new Change[](building.changes.length * 2 + 1);
            for (uint256 i = 0; i < building.changeCount; ++i) {
                larger[i] = building.changes[i];
            }
            building.changes = larger;
        }
        building.changes[building.changeCount++] = change;
    }

    function _addKey(Building memory building, address key) private pure {
        for (uint256 i = 0; i < building.keyCount; ++i) {
            if (building.keys[i] == key) {
                return;
            }
        }
        if (building.keyCount == building.keys.length) {
            address[] memory larger = new address[](building.keys.length * 2 + 1);
            for (uint256 i = 0; i < building.keyCount; ++i) {
                larger[i] = building.keys[i];
            }
            building.keys = larger;
        }
        building.keys[building.keyCount++] = key;
    }
}
