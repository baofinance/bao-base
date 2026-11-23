// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {BaoERC1967Proxy} from "@bao/BaoERC1967Proxy.sol";
import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";
import {DeploymentSnapLib} from "@bao-test/snap/DeploymentSnapLib.sol";

/// The implementation the snapped proxies run: a view of each kind a reading decodes.
contract SnapTarget {
    error Refused(uint256 code);

    function count() external pure returns (uint256) {
        return 42;
    }

    function token() external pure returns (address) {
        return address(0xA11CE);
    }

    function open() external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return 'Gold "anchor"\n';
    }

    function tag() external pure returns (bytes4) {
        return 0x12345678;
    }

    function drift() external pure returns (int24) {
        return -7;
    }

    function pair() external pure returns (uint112, address) {
        return (5, address(0xB0B));
    }

    function both() external pure returns (string memory, bytes memory) {
        return ("a\tb", hex"beef");
    }

    function list() external pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = 1;
        values[1] = 2;
    }

    /// Answers 4 bytes where it declares a uint256.
    function short() external pure returns (uint256 value) {
        value = 0x11223344;
        assembly {
            mstore(0, value)
            return(28, 4)
        }
    }

    function nothing() external pure {}

    /// The proxy's slot 5: what it answers depends on whose storage it runs in.
    function stored() external view returns (uint256 value) {
        assembly {
            value := sload(5)
        }
    }

    function balanceOf(address account) external pure returns (uint256) {
        return uint256(uint160(account)) % 1000;
    }

    /// The count of the contract whose address is in the proxy's slot 6: a view that calls another contract.
    function peerCount() external view returns (uint256) {
        address peer;
        assembly {
            peer := sload(6)
        }
        return SnapTarget(peer).count();
    }

    function fails() external pure returns (uint256) {
        revert Refused(9);
    }
}

/// Calls the library externally, so a test can expect its reverts, and answers the history of each proxy's
/// implementation slot in place of the chain: one value before a block, another from it on.
contract SnapHarness {
    struct Change {
        bytes32 before;
        bytes32 afterwards;
        uint256 changedAt;
    }

    mapping(address => Change) private _history;
    uint256 public historyReads;

    function setHistory(address proxy, address before, address afterwards, uint256 changedAt) external {
        _history[proxy] = Change(bytes32(uint256(uint160(before))), bytes32(uint256(uint160(afterwards))), changedAt);
    }

    function read(
        string memory listing,
        string memory prefix,
        address[] memory extraKnown
    ) external returns (DeploymentSnapLib.Reading[] memory) {
        return DeploymentSnapLib.read(listing, prefix, extraKnown, _slotAt);
    }

    function implementationBeforePause(address proxy) external returns (address before, uint256 pausedAt) {
        (before, pausedAt) = DeploymentSnapLib.implementationBeforePause(proxy, _slotAt);
    }

    function _slotAt(address proxy, uint256 blockNumber) internal returns (bytes32) {
        ++historyReads;
        Change memory change = _history[proxy];
        return blockNumber < change.changedAt ? change.before : change.afterwards;
    }
}

contract DeploymentSnapLibTest is Test {
    uint256 private constant FORK_BLOCK = 5_000;
    uint256 private constant PAUSED_AT = 1_000;

    address private harness;
    address private target;
    address private pauser;
    address private pool;
    address private paused;
    address private silver;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        vm.roll(FORK_BLOCK);
        harness = address(new SnapHarness());
        target = address(new SnapTarget());
        pauser = address(new HarborPauser_v1());
        pool = address(new BaoERC1967Proxy(target, ""));
        paused = address(new BaoERC1967Proxy(target, ""));
        silver = address(new BaoERC1967Proxy(target, ""));
        vm.store(paused, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(pauser))));
        SnapHarness(harness).setHistory(paused, target, pauser, PAUSED_AT);
    }

    // ── the listing a test reads, as bin/snap writes one ──────────────────────────────────────────

    function _proxies() private view returns (string memory) {
        string memory proxies = string.concat(
            string.concat("proxy\tGOLD::pool\t", vm.toString(pool), "\n"),
            string.concat("proxy\tGOLD::paused\t", vm.toString(paused), "\n"),
            string.concat("proxy\tSILVER::pool\t", vm.toString(silver), "\n")
        );
        return
            string.concat(
                proxies,
                string.concat("implementation\t", vm.toString(target), "\tSnapTarget\n"),
                string.concat("implementation\t", vm.toString(pauser), "\tHarborPauser_v1\n")
            );
    }

    function _view(
        string memory signature,
        bytes4 selector,
        string memory argument,
        string memory outputs
    ) private pure returns (string memory) {
        string memory head = string.concat(
            "view\tSnapTarget\t",
            signature,
            "\t",
            vm.toString(abi.encodePacked(selector))
        );
        return string.concat(head, "\t", argument, "\t", outputs, "\n");
    }

    function _views() private pure returns (string memory views) {
        views = _view("count()", SnapTarget.count.selector, "none", "uint");
        views = string.concat(views, _view("token()", SnapTarget.token.selector, "none", "address"));
        views = string.concat(views, _view("open()", SnapTarget.open.selector, "none", "bool"));
        views = string.concat(views, _view("name()", SnapTarget.name.selector, "none", "string"));
        views = string.concat(views, _view("tag()", SnapTarget.tag.selector, "none", "bytes4"));
        views = string.concat(views, _view("drift()", SnapTarget.drift.selector, "none", "int"));
        views = string.concat(views, _view("pair()", SnapTarget.pair.selector, "none", "uint,address"));
        views = string.concat(views, _view("both()", SnapTarget.both.selector, "none", "string,bytes"));
        views = string.concat(views, _view("list()", SnapTarget.list.selector, "none", "raw"));
        views = string.concat(views, _view("short()", SnapTarget.short.selector, "none", "uint"));
        views = string.concat(views, _view("nothing()", SnapTarget.nothing.selector, "none", "-"));
        views = string.concat(views, _view("stored()", SnapTarget.stored.selector, "none", "uint"));
        views = string.concat(views, _view("balanceOf(address)", SnapTarget.balanceOf.selector, "address", "uint"));
        views = string.concat(views, _view("fails()", SnapTarget.fails.selector, "none", "uint"));
        views = string.concat(views, _view("peerCount()", SnapTarget.peerCount.selector, "none", "uint"));
    }

    function _field(
        string memory label,
        string memory mappingSlot,
        uint256 slot,
        uint256 offset,
        uint256 size,
        string memory kind
    ) private pure returns (string memory) {
        string memory head = string.concat("storage\tSnapTarget\t", label, "\t", mappingSlot);
        string memory place = string.concat(
            vm.toString(bytes32(slot)),
            "\t",
            vm.toString(offset),
            "\t",
            vm.toString(size)
        );
        return string.concat(head, "\t", place, "\t", kind, "\n");
    }

    uint256 private constant BALANCES_SLOT = 7;
    uint256 private constant DEPOSITS_SLOT = 8;

    function _fields() private pure returns (string memory fields) {
        string memory balances = vm.toString(bytes32(BALANCES_SLOT));
        string memory deposits = vm.toString(bytes32(DEPOSITS_SLOT));
        fields = _field("count", "-", 0, 0, 8, "uint");
        fields = string.concat(fields, _field("open", "-", 0, 8, 1, "bool"));
        fields = string.concat(fields, _field("token", "-", 0, 9, 20, "address"));
        fields = string.concat(fields, _field("drift", "-", 1, 0, 16, "int"));
        fields = string.concat(fields, _field("tag", "-", 1, 16, 4, "bytes4"));
        fields = string.concat(fields, _field("blob", "-", 2, 0, 32, "raw"));
        fields = string.concat(fields, _field("balances[{}]", balances, 0, 0, 32, "uint"));
        fields = string.concat(fields, _field("deposits[{}].amount", deposits, 0, 0, 32, "uint"));
        fields = string.concat(fields, _field("deposits[{}].since", deposits, 1, 0, 8, "uint"));
    }

    function _listing() private view returns (string memory) {
        return string.concat(_proxies(), _views(), _fields());
    }

    function _read(
        string memory prefix,
        address[] memory extraKnown
    ) private returns (DeploymentSnapLib.Reading[] memory) {
        return SnapHarness(harness).read(_listing(), prefix, extraKnown);
    }

    function _none() private pure returns (address[] memory) {
        return new address[](0);
    }

    // ── finding a reading ─────────────────────────────────────────────────────────────────────────

    /// The value of the one reading of `contractKey` labelled `label`.
    function _value(
        DeploymentSnapLib.Reading[] memory readings,
        string memory contractKey,
        string memory label
    ) private pure returns (string memory value) {
        uint256 found;
        for (uint256 i = 0; i < readings.length; ++i) {
            if (_same(readings[i].contractKey, contractKey) && _same(readings[i].label, label)) {
                value = readings[i].value;
                ++found;
            }
        }
        require(found == 1, string.concat(contractKey, " ", label, ": ", vm.toString(found), " readings"));
    }

    function _labelsStartingWith(
        DeploymentSnapLib.Reading[] memory readings,
        string memory contractKey,
        string memory start
    ) private pure returns (uint256 found) {
        for (uint256 i = 0; i < readings.length; ++i) {
            bytes memory label = bytes(readings[i].label);
            if (!_same(readings[i].contractKey, contractKey) || label.length < bytes(start).length) {
                continue;
            }
            bytes memory head = new bytes(bytes(start).length);
            for (uint256 j = 0; j < head.length; ++j) {
                head[j] = label[j];
            }
            if (_same(string(head), start)) {
                ++found;
            }
        }
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ── the proxies read ──────────────────────────────────────────────────────────────────────────

    function test_readsEveryProxyUnderThePrefixAndNoOther() public {
        // The prefix picks the proxies by their key: both GOLD proxies are read, and SILVER's is not.
        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", _none());

        assertGt(_labelsStartingWith(readings, "GOLD::pool", ""), 0);
        assertGt(_labelsStartingWith(readings, "GOLD::paused", ""), 0);
        assertEq(_labelsStartingWith(readings, "SILVER::pool", ""), 0);
        for (uint256 i = 0; i < readings.length; ++i) {
            assertTrue(_same(readings[i].contractKey, "GOLD::pool") || _same(readings[i].contractKey, "GOLD::paused"));
        }
    }

    function test_aPrefixNoProxyHasStopsTheRead() public {
        // A prefix no key starts with reads nothing: a snap of nothing is refused, not written empty.
        string memory listing = _listing();
        address[] memory extraKnown = _none();
        vm.expectRevert(abi.encodeWithSelector(DeploymentSnapLib.NoProxyUnderThePrefix.selector, "BRONZE::"));
        SnapHarness(harness).read(listing, "BRONZE::", extraKnown);
    }

    function test_readsTheAccountFactsAndTheImplementation() public {
        // Each proxy's ETH balance, nonce and code hash, and the implementation its ERC-1967 slot holds, by type.
        vm.deal(pool, 7 ether);
        vm.setNonce(pool, 3);

        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", _none());

        assertEq(_value(readings, "GOLD::pool", "account balance"), "7000000000000000000");
        assertEq(_value(readings, "GOLD::pool", "account nonce"), "3");
        assertEq(_value(readings, "GOLD::pool", "account code hash"), vm.toString(pool.codehash));
        assertEq(
            _value(readings, "GOLD::pool", "ERC-1967 implementation"),
            string.concat(vm.toString(target), " (SnapTarget)")
        );
    }

    // ── views ─────────────────────────────────────────────────────────────────────────────────────

    function test_readsEachViewDecodedByItsKind() public {
        // Each output decoded by its kind; strings quoted, their quotes and control characters escaped; several
        // outputs in brackets.
        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", _none());

        assertEq(_value(readings, "GOLD::pool", "count()"), "42");
        assertEq(_value(readings, "GOLD::pool", "token()"), vm.toString(address(0xA11CE)));
        assertEq(_value(readings, "GOLD::pool", "open()"), "true");
        assertEq(_value(readings, "GOLD::pool", "name()"), '"Gold \\"anchor\\"\\n"');
        assertEq(_value(readings, "GOLD::pool", "tag()"), "0x12345678");
        assertEq(_value(readings, "GOLD::pool", "drift()"), "-7");
        assertEq(_value(readings, "GOLD::pool", "pair()"), string.concat("(5, ", vm.toString(address(0xB0B)), ")"));
        assertEq(_value(readings, "GOLD::pool", "both()"), '("a\\tb", 0xbeef)');
        assertEq(_value(readings, "GOLD::pool", "nothing()"), "()");
    }

    function test_aRevertIsTheAnswer() public {
        // A view that reverts is read as its revert data: it is the contract's answer at that block.
        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", _none());

        assertEq(
            _value(readings, "GOLD::pool", "fails()"),
            string.concat("reverted ", vm.toString(abi.encodeWithSelector(SnapTarget.Refused.selector, 9)))
        );
    }

    function test_rawOutputsAndShortAnswersAreHex() public {
        // An output that is not elementary is read as the answer's bytes; so is an answer shorter than its outputs,
        // marked as such.
        uint256[] memory values = new uint256[](2);
        values[0] = 1;
        values[1] = 2;

        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", _none());

        assertEq(_value(readings, "GOLD::pool", "list()"), vm.toString(abi.encode(values)));
        assertEq(_value(readings, "GOLD::pool", "short()"), "0x11223344 (not its declared outputs)");
    }

    function test_readsEachAddressViewAtEveryKnownAddress() public {
        // The known addresses are the proxies under the prefix, then each extra one not among them: none, one, two,
        // and one that is a proxy, read once.
        address[] memory one = new address[](1);
        one[0] = alice;
        address[] memory two = new address[](2);
        two[0] = alice;
        two[1] = bob;
        address[] memory aProxy = new address[](2);
        aProxy[0] = alice;
        aProxy[1] = pool;

        assertEq(_labelsStartingWith(_read("GOLD::", _none()), "GOLD::pool", "balanceOf("), 2);
        assertEq(_labelsStartingWith(_read("GOLD::", one), "GOLD::pool", "balanceOf("), 3);
        assertEq(_labelsStartingWith(_read("GOLD::", aProxy), "GOLD::pool", "balanceOf("), 3);

        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", two);
        assertEq(_labelsStartingWith(readings, "GOLD::pool", "balanceOf("), 4);
        address[4] memory known = [pool, paused, alice, bob];
        for (uint256 i = 0; i < known.length; ++i) {
            string memory label = string.concat("balanceOf(", vm.toString(known[i]), ")");
            assertEq(_value(readings, "GOLD::pool", label), vm.toString(uint256(uint160(known[i])) % 1000));
        }
    }

    // ── storage ───────────────────────────────────────────────────────────────────────────────────

    function test_readsStorageFieldsAtTheirOffsets() public {
        // Values packed into a slot are read at their offsets and sizes: a signed one sign-extended, fixed bytes as
        // their bytes, a raw one as the slot's word.
        uint256 first = 0x0102 | (1 << 64) | (uint256(uint160(address(0xA11CE))) << 72);
        uint256 second = uint256(uint128(int128(-5))) | (uint256(0xdeadbeef) << 128);
        bytes32 blob = keccak256("blob");
        vm.store(pool, bytes32(uint256(0)), bytes32(first));
        vm.store(pool, bytes32(uint256(1)), bytes32(second));
        vm.store(pool, bytes32(uint256(2)), blob);

        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", _none());

        assertEq(_value(readings, "GOLD::pool", "count"), "258");
        assertEq(_value(readings, "GOLD::pool", "open"), "true");
        assertEq(_value(readings, "GOLD::pool", "token"), vm.toString(address(0xA11CE)));
        assertEq(_value(readings, "GOLD::pool", "drift"), "-5");
        assertEq(_value(readings, "GOLD::pool", "tag"), "0xdeadbeef");
        assertEq(_value(readings, "GOLD::pool", "blob"), vm.toString(blob));
    }

    function test_readsMappingEntriesAtEveryKnownAddress() public {
        // An address-keyed mapping is read at each known address, its entry's slot the hash of the key and the
        // mapping's slot, a struct value by member counted from it.
        address[] memory one = new address[](1);
        one[0] = alice;
        uint256 aliceBalance = uint256(keccak256(abi.encode(alice, BALANCES_SLOT)));
        uint256 aliceDeposit = uint256(keccak256(abi.encode(alice, DEPOSITS_SLOT)));
        vm.store(pool, bytes32(aliceBalance), bytes32(uint256(11)));
        vm.store(pool, bytes32(aliceDeposit), bytes32(uint256(12)));
        vm.store(pool, bytes32(aliceDeposit + 1), bytes32(uint256(13)));

        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", one);

        string memory key = vm.toString(alice);
        assertEq(_value(readings, "GOLD::pool", string.concat("balances[", key, "]")), "11");
        assertEq(_value(readings, "GOLD::pool", string.concat("deposits[", key, "].amount")), "12");
        assertEq(_value(readings, "GOLD::pool", string.concat("deposits[", key, "].since")), "13");
        assertEq(_value(readings, "GOLD::pool", string.concat("balances[", vm.toString(pool), "]")), "0");
        assertEq(_labelsStartingWith(readings, "GOLD::pool", "balances["), 3);
    }

    // ── a paused proxy ────────────────────────────────────────────────────────────────────────────

    function test_aPausedProxyIsReadOnItsImplementationBeforeThePause() public {
        // A proxy on a pauser answers no view. It is read on the implementation its slot held before the pause, in its
        // own storage, and is left on the pauser.
        vm.store(paused, bytes32(uint256(5)), bytes32(uint256(77)));

        DeploymentSnapLib.Reading[] memory readings = _read("GOLD::", _none());

        assertEq(
            _value(readings, "GOLD::paused", "ERC-1967 implementation"),
            string.concat(vm.toString(pauser), " (HarborPauser_v1)")
        );
        assertEq(
            _value(readings, "GOLD::paused", "ERC-1967 implementation before the pause"),
            string.concat(vm.toString(target), " (SnapTarget), paused at block 1000")
        );
        assertEq(_value(readings, "GOLD::paused", "count()"), "42");
        assertEq(_value(readings, "GOLD::paused", "stored()"), "77");
        assertEq(vm.load(paused, ERC1967Utils.IMPLEMENTATION_SLOT), bytes32(uint256(uint160(pauser))));
        // a proxy that is not paused has no implementation before a pause
        assertEq(_labelsStartingWith(readings, "GOLD::pool", "ERC-1967 implementation before"), 0);
    }

    function test_pausedProxiesAreReadTogetherOnTheirImplementationsBeforeThePause() public {
        // A view of one paused proxy that calls another paused proxy answers: every paused proxy read is put back
        // before any view is read, and each is left on the pauser after.
        address peer = address(new BaoERC1967Proxy(target, ""));
        vm.store(peer, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(pauser))));
        SnapHarness(harness).setHistory(peer, target, pauser, PAUSED_AT);
        vm.store(paused, bytes32(uint256(6)), bytes32(uint256(uint160(peer))));
        vm.store(peer, bytes32(uint256(6)), bytes32(uint256(uint160(paused))));
        string memory listing = string.concat(_listing(), "proxy\tGOLD::peer\t", vm.toString(peer), "\n");

        DeploymentSnapLib.Reading[] memory readings = SnapHarness(harness).read(listing, "GOLD::", _none());

        assertEq(_value(readings, "GOLD::paused", "peerCount()"), "42");
        assertEq(_value(readings, "GOLD::peer", "peerCount()"), "42");
        assertEq(vm.load(paused, ERC1967Utils.IMPLEMENTATION_SLOT), bytes32(uint256(uint160(pauser))));
        assertEq(vm.load(peer, ERC1967Utils.IMPLEMENTATION_SLOT), bytes32(uint256(uint160(pauser))));
    }

    function test_theBisectionFindsTheBlockTheSlotTookItsValue() public {
        // The block the slot took the value it holds at the fork's block, from 1 to the fork's block itself, found in
        // a number of reads that grows with the logarithm of the block.
        uint256[3] memory changes = [uint256(1), 2_345, FORK_BLOCK];
        for (uint256 i = 0; i < changes.length; ++i) {
            SnapHarness(harness).setHistory(paused, target, pauser, changes[i]);
            uint256 readsBefore = SnapHarness(harness).historyReads();

            (address before, uint256 pausedAt) = SnapHarness(harness).implementationBeforePause(paused);

            assertEq(before, target);
            assertEq(pausedAt, changes[i]);
            // one read at the fork's block, one per halving of [0, 5000], and one at block 0 when the change is at 1
            assertLe(SnapHarness(harness).historyReads() - readsBefore, 1 + 13 + 1);
        }
    }

    function test_aSlotHistoryThatDisagreesWithTheForkStopsTheRead() public {
        // The chain's slot at the fork's block must be what the fork holds: otherwise the search would find the
        // history of another value.
        SnapHarness(harness).setHistory(paused, target, address(0xBAD), PAUSED_AT);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentSnapLib.SlotHistoryDisagrees.selector,
                paused,
                FORK_BLOCK,
                bytes32(uint256(0xBAD)),
                bytes32(uint256(uint160(pauser)))
            )
        );
        SnapHarness(harness).implementationBeforePause(paused);
    }

    // ── what stops a read ─────────────────────────────────────────────────────────────────────────

    function test_anImplementationNoStateFileNamesStopsTheRead() public {
        address stray = address(new SnapTarget());
        vm.store(pool, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(stray))));
        string memory listing = _listing();
        address[] memory extraKnown = _none();

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentSnapLib.ImplementationInNoStateFile.selector, "GOLD::pool", stray)
        );
        SnapHarness(harness).read(listing, "GOLD::", extraKnown);
    }

    function test_aTypeTheBuildLacksStopsTheRead() public {
        string memory listing = string.concat(_proxies(), "absent\tSnapTarget\n");
        address[] memory extraKnown = _none();

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentSnapLib.TypeNotInTheBuild.selector, "GOLD::pool", "SnapTarget")
        );
        SnapHarness(harness).read(listing, "GOLD::", extraKnown);
    }

    function test_aListingLineNotUnderstoodStopsTheRead() public {
        // A line of a kind the listing does not have, or with fields missing.
        string[2] memory lines = ["slot\tSnapTarget\tcount", "view\tSnapTarget\tcount()"];
        for (uint256 i = 0; i < lines.length; ++i) {
            string memory listing = string.concat(_proxies(), lines[i], "\n");
            address[] memory extraKnown = _none();

            vm.expectRevert(abi.encodeWithSelector(DeploymentSnapLib.ListingLineNotRead.selector, lines[i]));
            SnapHarness(harness).read(listing, "GOLD::", extraKnown);
        }
    }

    function test_aReadingIsWrittenAsOneTabSeparatedLine() public pure {
        assertEq(
            DeploymentSnapLib.line(DeploymentSnapLib.Reading("GOLD::pool", "count()", "42")),
            "GOLD::pool\tcount()\t42"
        );
    }
}
