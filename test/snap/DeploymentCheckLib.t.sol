// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {BaoERC1967Proxy} from "@bao/BaoERC1967Proxy.sol";
import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";
import {DeploymentSnapLib} from "@bao-test/snap/DeploymentSnapLib.sol";
import {DeploymentCheckLib} from "@bao-test/snap/DeploymentCheckLib.sol";

/// A pool a batch changes: values its views and its storage both show, and one view that reverts when it is empty.
contract CheckPool {
    error Empty(uint256 stamp);

    uint256 public count;
    uint256 public stamp;
    address public owner;
    bool public open;
    mapping(address => uint256) public credits;

    function setCount(uint256 to) external {
        count = to;
    }

    function bump(uint256 by) external {
        count += by;
    }

    function touch() external {
        stamp = block.timestamp;
    }

    function setOwner(address to) external {
        owner = to;
    }

    function setOpen(bool to) external {
        open = to;
    }

    function credit(address who, uint256 amount) external {
        credits[who] += amount;
    }

    function fails() external view returns (uint256) {
        if (count == 0) {
            revert Empty(stamp);
        }
        return count;
    }

    function upgradeTo(address next) external {
        ERC1967Utils.upgradeToAndCall(next, "");
    }

    /// What a UUPS upgrade asks of the implementation it upgrades to.
    function proxiableUUID() external pure returns (bytes32) {
        return ERC1967Utils.IMPLEMENTATION_SLOT;
    }
}

/// A one-shot implementation that empties the pool and pauses it: it declares none of the storage it writes.
contract CheckPoolEmptier {
    function emptyAndPause(address pauser) external {
        assembly ("memory-safe") {
            sstore(0, 0)
        }
        ERC1967Utils.upgradeToAndCall(pauser, "");
    }
}

/// A token that logs each transfer, and can be made to log a mint as one less than it is.
contract CheckToken {
    event Transfer(address indexed from, address indexed to, uint256 value);

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function mintMislogged(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount - 1);
    }
}

/// Calls the library externally, so a test can expect its reverts, and answers the history of each proxy's
/// implementation slot in place of the chain: one value before a block, another from it on.
contract CheckHarness {
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

    function begin() external returns (uint256) {
        return DeploymentCheckLib.begin();
    }

    function transactions(string memory list) external pure returns (bytes32[] memory) {
        return DeploymentCheckLib.transactions(list);
    }

    function end(DeploymentCheckLib.Check memory check) external returns (Vm.Log[] memory) {
        return DeploymentCheckLib.end(check, _slotAt);
    }

    function _slotAt(address proxy, uint256 blockNumber) internal returns (bytes32) {
        ++historyReads;
        Change memory change = _history[proxy];
        return blockNumber < change.changedAt ? change.before : change.afterwards;
    }
}

contract DeploymentCheckLibTest is Test {
    address private constant MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    string private constant REASON = "the batch resets it";

    address private harness;
    address private poolImplementation;
    address private tokenImplementation;
    address private emptier;
    address private pauser;
    address private pool;
    address private token;
    address private silver;
    address private outsideToken;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private dave = makeAddr("dave");

    function setUp() public {
        vm.roll(100);
        harness = address(new CheckHarness());
        poolImplementation = address(new CheckPool());
        tokenImplementation = address(new CheckToken());
        emptier = address(new CheckPoolEmptier());
        pauser = address(new HarborPauser_v1());
        pool = address(new BaoERC1967Proxy(poolImplementation, ""));
        token = address(new BaoERC1967Proxy(tokenImplementation, ""));
        silver = address(new BaoERC1967Proxy(poolImplementation, ""));
        outsideToken = address(new CheckToken());
    }

    // ── the listing, the check, and what it reports ───────────────────────────────────────────────

    function _line(string memory head, string memory rest) private pure returns (string memory) {
        return string.concat(head, "\t", rest, "\n");
    }

    function _proxies() private view returns (string memory) {
        string memory proxies = string.concat(
            _line("proxy\tGOLD::pool", vm.toString(pool)),
            _line("proxy\tGOLD::token", vm.toString(token)),
            _line("proxy\tSILVER::pool", vm.toString(silver))
        );
        return
            string.concat(
                proxies,
                _line(string.concat("implementation\t", vm.toString(poolImplementation)), "CheckPool"),
                _line(string.concat("implementation\t", vm.toString(tokenImplementation)), "CheckToken"),
                _line(string.concat("implementation\t", vm.toString(emptier)), "CheckPoolEmptier"),
                _line(string.concat("implementation\t", vm.toString(pauser)), "HarborPauser_v1")
            );
    }

    /// A `view` line, its selector from its signature; `rest` is its argument and its outputs.
    function _view(
        string memory contractType,
        string memory signature,
        string memory rest
    ) private pure returns (string memory) {
        string memory head = string.concat("view\t", contractType, "\t", signature);
        bytes4 selector = bytes4(keccak256(bytes(signature)));
        return _line(string.concat(head, "\t", vm.toString(abi.encodePacked(selector))), rest);
    }

    function _views() private pure returns (string memory views) {
        views = _view("CheckPool", "count()", "none\tuint");
        views = string.concat(views, _view("CheckPool", "stamp()", "none\tuint"));
        views = string.concat(views, _view("CheckPool", "owner()", "none\taddress"));
        views = string.concat(views, _view("CheckPool", "open()", "none\tbool"));
        views = string.concat(views, _view("CheckPool", "credits(address)", "address\tuint"));
        views = string.concat(views, _view("CheckPool", "fails()", "none\tuint"));
        views = string.concat(views, _view("CheckToken", "balanceOf(address)", "address\tuint"));
        views = string.concat(views, _view("CheckToken", "totalSupply()", "none\tuint"));
    }

    function _storage() private pure returns (string memory lines) {
        lines = _line(string.concat("storage\tCheckPool\tcount\t", vm.toString(bytes32(0))), "0\t32\tuint");
        lines = string.concat(
            lines,
            _line(string.concat("storage\tCheckPool\tstamp\t", vm.toString(bytes32(uint256(1)))), "0\t32\tuint")
        );
        lines = string.concat(
            lines,
            _line(string.concat("storage\tCheckPool\towner\t", vm.toString(bytes32(uint256(2)))), "0\t20\taddress")
        );
        lines = string.concat(
            lines,
            _line(string.concat("storage\tCheckPool\topen\t", vm.toString(bytes32(uint256(2)))), "20\t1\tbool")
        );
        lines = string.concat(
            lines,
            _line(
                string.concat("entry\tCheckPool\tcredits[{}]\t", vm.toString(bytes32(uint256(3)))),
                "address\t0\t0\t32\tuint"
            )
        );
        lines = string.concat(
            lines,
            _line(
                string.concat("entry\tCheckToken\tbalanceOf[{}]\t", vm.toString(bytes32(0))),
                "address\t0\t0\t32\tuint"
            )
        );
        lines = string.concat(
            lines,
            _line(string.concat("storage\tCheckToken\ttotalSupply\t", vm.toString(bytes32(uint256(1)))), "0\t32\tuint")
        );
    }

    function _check(
        uint256 before,
        DeploymentCheckLib.Claim[] memory claims,
        string memory folder
    ) private view returns (DeploymentCheckLib.Check memory) {
        return
            DeploymentCheckLib.Check(
                before,
                string.concat(_proxies(), _views(), _storage()),
                "GOLD::",
                new address[](0),
                new DeploymentSnapLib.Implementation[](0),
                claims,
                string.concat("tmp/check/", folder)
            );
    }

    function _claims(DeploymentCheckLib.Claim memory a) private pure returns (DeploymentCheckLib.Claim[] memory c) {
        c = new DeploymentCheckLib.Claim[](1);
        c[0] = a;
    }

    function _claims(
        DeploymentCheckLib.Claim memory a,
        DeploymentCheckLib.Claim memory b,
        DeploymentCheckLib.Claim memory d
    ) private pure returns (DeploymentCheckLib.Claim[] memory c) {
        c = new DeploymentCheckLib.Claim[](3);
        (c[0], c[1], c[2]) = (a, b, d);
    }

    function _none() private pure returns (DeploymentCheckLib.Claim[] memory) {
        return new DeploymentCheckLib.Claim[](0);
    }

    /// The pool's changes are claimed as changing for a stated reason.
    function _poolChanges() private pure returns (DeploymentCheckLib.Claim memory) {
        return DeploymentCheckLib.changes("GOLD::pool", "*", REASON);
    }

    function _expectFailure(string memory report) private {
        vm.expectRevert(abi.encodeWithSelector(DeploymentCheckLib.ClaimsFailed.selector, report));
    }

    function _reverted(uint256 stamp) private pure returns (string memory) {
        return string.concat("reverted ", vm.toString(abi.encodeWithSelector(CheckPool.Empty.selector, stamp)));
    }

    function _named(address implementation, string memory contractType) private pure returns (string memory) {
        return string.concat(vm.toString(implementation), " (", contractType, ")");
    }

    /// The label of an address view at `key`.
    function _called(string memory name, address key) private pure returns (string memory) {
        return string.concat(name, "(", vm.toString(key), ")");
    }

    /// The label of a mapping's entry at `key`.
    function _entryOf(string memory name, address key) private pure returns (string memory) {
        return string.concat(name, "[", vm.toString(key), "]");
    }

    // ── what fails ────────────────────────────────────────────────────────────────────────────────

    function test_aChangeNoClaimCoversFails() public {
        // Each change nothing claims is listed: the views that read it, then the storage value that holds it.
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).setCount(5);
        DeploymentCheckLib.Check memory check = _check(before, _none(), "unclaimed");

        _expectFailure(
            string.concat(
                "unclaimed: GOLD::pool\tcount()\t0 -> 5\n",
                "unclaimed: GOLD::pool\tfails()\t",
                _reverted(0),
                " -> 5\nunclaimed: GOLD::pool\tcount\t0 -> 5"
            )
        );
        CheckHarness(harness).end(check);
    }

    function test_aClaimThatClaimsNothingFails() public {
        // A claim of a change the batch did not make fails: here the batch changes nothing.
        uint256 before = CheckHarness(harness).begin();
        DeploymentCheckLib.Check memory check = _check(
            before,
            _claims(DeploymentCheckLib.becomes("GOLD::pool", "count()", uint256(5))),
            "claimed-nothing"
        );

        _expectFailure("claimed nothing: GOLD::pool\tcount()");
        CheckHarness(harness).end(check);
    }

    // ── what claims say ───────────────────────────────────────────────────────────────────────────

    function test_becomesChecksTheValue() public {
        // Each typed form of `becomes` states the value as the read writes it: a number, an address, a bool, and the
        // text itself. A value the change does not end with fails, naming both.
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).setCount(5);
        CheckPool(pool).setOwner(alice);
        CheckPool(pool).setOpen(true);
        DeploymentCheckLib.Claim[] memory claims = new DeploymentCheckLib.Claim[](7);
        claims[0] = DeploymentCheckLib.becomes("GOLD::pool", "count()", uint256(5));
        claims[1] = DeploymentCheckLib.becomes("GOLD::pool", "count", uint256(5));
        claims[2] = DeploymentCheckLib.becomes("GOLD::pool", "fails()", "5");
        claims[3] = DeploymentCheckLib.becomes("GOLD::pool", "owner()", alice);
        claims[4] = DeploymentCheckLib.becomes("GOLD::pool", "owner", alice);
        claims[5] = DeploymentCheckLib.becomes("GOLD::pool", "open()", true);
        claims[6] = DeploymentCheckLib.becomes("GOLD::pool", "open", true);
        CheckHarness(harness).end(_check(before, claims, "becomes"));

        before = CheckHarness(harness).begin();
        CheckPool(pool).setCount(6);
        claims = _claims(
            DeploymentCheckLib.becomes("GOLD::pool", "count()", uint256(7)),
            DeploymentCheckLib.changes("GOLD::pool", "count", REASON),
            DeploymentCheckLib.changes("GOLD::pool", "fails()", REASON)
        );
        DeploymentCheckLib.Check memory check = _check(before, claims, "becomes-wrong");

        _expectFailure("wrong: GOLD::pool\tcount(): expected 7, found 5 -> 6");
        CheckHarness(harness).end(check);
    }

    function test_becomesTheBlockTime() public {
        // A value the batch sets to the time of its block.
        vm.warp(1_700_000_000);
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).touch();
        DeploymentCheckLib.Claim[] memory claims = _claims(
            DeploymentCheckLib.becomesTheBlockTime("GOLD::pool", "stamp()"),
            DeploymentCheckLib.becomesTheBlockTime("GOLD::pool", "stamp"),
            DeploymentCheckLib.reverts(
                "GOLD::pool",
                "fails()",
                abi.encodeWithSelector(CheckPool.Empty.selector, 1_700_000_000)
            )
        );

        CheckHarness(harness).end(_check(before, claims, "block-time"));
    }

    function test_increasesBy() public {
        // A value that goes up by a stated amount; another amount fails.
        CheckPool(pool).setCount(3);
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).bump(2);
        DeploymentCheckLib.Claim[] memory claims = _claims(
            DeploymentCheckLib.increasesBy("GOLD::pool", "count()", 2),
            DeploymentCheckLib.increasesBy("GOLD::pool", "count", 2),
            DeploymentCheckLib.increasesBy("GOLD::pool", "fails()", 2)
        );
        CheckHarness(harness).end(_check(before, claims, "increases"));

        before = CheckHarness(harness).begin();
        CheckPool(pool).bump(2);
        claims = _claims(
            DeploymentCheckLib.increasesBy("GOLD::pool", "count()", 3),
            DeploymentCheckLib.increasesBy("GOLD::pool", "count", 2),
            DeploymentCheckLib.increasesBy("GOLD::pool", "fails()", 2)
        );
        DeploymentCheckLib.Check memory check = _check(before, claims, "increases-wrong");

        _expectFailure("wrong: GOLD::pool\tcount(): expected an increase by 3, found 5 -> 7");
        CheckHarness(harness).end(check);
    }

    function test_revertsChecksTheWholeRevertData() public {
        // A view that reverts after the batch, with its error and its argument; the same error with another argument
        // fails.
        vm.warp(1_000);
        CheckPool(pool).touch();
        CheckPool(pool).setCount(5);
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).setCount(0);
        DeploymentCheckLib.Claim[] memory claims = _claims(
            DeploymentCheckLib.reverts(
                "GOLD::pool",
                "fails()",
                abi.encodeWithSelector(CheckPool.Empty.selector, 1_000)
            ),
            DeploymentCheckLib.becomes("GOLD::pool", "count()", uint256(0)),
            DeploymentCheckLib.becomes("GOLD::pool", "count", uint256(0))
        );
        CheckHarness(harness).end(_check(before, claims, "reverts"));

        vm.warp(2_000);
        before = CheckHarness(harness).begin();
        CheckPool(pool).touch();
        claims = _claims(
            DeploymentCheckLib.reverts(
                "GOLD::pool",
                "fails()",
                abi.encodeWithSelector(CheckPool.Empty.selector, 1_000)
            ),
            DeploymentCheckLib.becomesTheBlockTime("GOLD::pool", "stamp()"),
            DeploymentCheckLib.becomesTheBlockTime("GOLD::pool", "stamp")
        );
        DeploymentCheckLib.Check memory check = _check(before, claims, "reverts-wrong");

        _expectFailure(
            string.concat(
                "wrong: GOLD::pool\tfails(): expected ",
                _reverted(1_000),
                ", found ",
                _reverted(1_000),
                " -> ",
                _reverted(2_000)
            )
        );
        CheckHarness(harness).end(check);
    }

    function test_changesTakesAReason() public {
        // A change whose value is not stated, with the reason it changes.
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).setCount(5);

        CheckHarness(harness).end(_check(before, _claims(_poolChanges()), "changes"));
    }

    function test_aPatternClaimsEveryChangeItMatches() public {
        // `*` in the contract key and the label: a claim matching two changes, three matching one each, and one
        // matching none, which fails.
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).setCount(5);
        CheckPool(pool).setOwner(alice);
        DeploymentCheckLib.Claim[] memory claims = new DeploymentCheckLib.Claim[](5);
        claims[0] = DeploymentCheckLib.changes("GOLD::*", "count*", REASON);
        claims[1] = DeploymentCheckLib.changes("*::pool", "owner()", REASON);
        claims[2] = DeploymentCheckLib.changes("*", "fails()", REASON);
        claims[3] = DeploymentCheckLib.changes("GOLD::pool", "owner", REASON);
        claims[4] = DeploymentCheckLib.changes("GOLD::token", "*", REASON);
        DeploymentCheckLib.Check memory check = _check(before, claims, "patterns");

        _expectFailure("claimed nothing: GOLD::token\t*");
        CheckHarness(harness).end(check);
    }

    // ── what changes ──────────────────────────────────────────────────────────────────────────────

    function test_aReadingThatAppearsOrGoesIsAChange() public {
        // A proxy the batch pauses gains a reading of its implementation before the pause; one it unpauses loses it.
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).upgradeTo(pauser);
        string memory pausedByTheBatch = string.concat(
            _named(poolImplementation, "CheckPool"),
            ", paused by the batch"
        );
        DeploymentCheckLib.Claim[] memory claims = new DeploymentCheckLib.Claim[](2);
        claims[0] = DeploymentCheckLib.becomes(
            "GOLD::pool",
            "ERC-1967 implementation",
            _named(pauser, "HarborPauser_v1")
        );
        claims[1] = DeploymentCheckLib.becomes(
            "GOLD::pool",
            "ERC-1967 implementation before the pause",
            pausedByTheBatch
        );
        CheckHarness(harness).end(_check(before, claims, "appears"));

        CheckHarness(harness).setHistory(pool, poolImplementation, pauser, block.number);
        vm.roll(block.number + 10);
        before = CheckHarness(harness).begin();
        vm.startPrank(MULTISIG);
        HarborPauser_v1(pool).upgradeToAndCall(poolImplementation, "");
        vm.stopPrank();
        claims[0] = DeploymentCheckLib.becomes(
            "GOLD::pool",
            "ERC-1967 implementation",
            _named(poolImplementation, "CheckPool")
        );
        claims[1] = DeploymentCheckLib.becomes(
            "GOLD::pool",
            "ERC-1967 implementation before the pause",
            DeploymentCheckLib.NONE
        );

        CheckHarness(harness).end(_check(before, claims, "goes"));
    }

    function test_storageChangesComeFromTheDiffForEveryListedProxy() public {
        // A proxy outside the prefix has no views read, but its storage changes are the batch's and are claimed.
        uint256 before = CheckHarness(harness).begin();
        CheckPool(silver).setCount(4);

        CheckHarness(harness).end(
            _check(before, _claims(DeploymentCheckLib.becomes("SILVER::pool", "count", uint256(4))), "every-proxy")
        );
    }

    function test_aProxyTheBatchPausedIsReadOnItsImplementationBeforeThePause() public {
        // The batch's own write gives the implementation before the pause: its views answer as before, and the slot's
        // history is not read.
        CheckPool(pool).setCount(5);
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).upgradeTo(pauser);
        string memory pausedByTheBatch = string.concat(
            _named(poolImplementation, "CheckPool"),
            ", paused by the batch"
        );
        DeploymentCheckLib.Claim[] memory claims = new DeploymentCheckLib.Claim[](2);
        claims[0] = DeploymentCheckLib.becomes(
            "GOLD::pool",
            "ERC-1967 implementation",
            _named(pauser, "HarborPauser_v1")
        );
        claims[1] = DeploymentCheckLib.becomes(
            "GOLD::pool",
            "ERC-1967 implementation before the pause",
            pausedByTheBatch
        );

        CheckHarness(harness).end(_check(before, claims, "paused-by-the-batch"));

        assertEq(CheckHarness(harness).historyReads(), 0);
    }

    function test_aProxyPausedThroughAnotherImplementationIsReadAsBeforeTheBatch() public {
        // The batch runs the pool on a one-shot implementation that declares none of the storage it writes, which
        // empties it and pauses it. After the batch the pool is read as it was before, so the two reads compare the
        // same views, and the emptying's write is named by the pool's own layout.
        CheckPool(pool).setCount(5);
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).upgradeTo(emptier);
        CheckPoolEmptier(pool).emptyAndPause(pauser);
        string memory pausedByTheBatch = string.concat(
            _named(poolImplementation, "CheckPool"),
            ", paused by the batch"
        );
        DeploymentCheckLib.Claim[] memory claims = new DeploymentCheckLib.Claim[](5);
        claims[0] = DeploymentCheckLib.becomes(
            "GOLD::pool",
            "ERC-1967 implementation",
            _named(pauser, "HarborPauser_v1")
        );
        claims[1] = DeploymentCheckLib.becomes(
            "GOLD::pool",
            "ERC-1967 implementation before the pause",
            pausedByTheBatch
        );
        claims[2] = DeploymentCheckLib.becomes("GOLD::pool", "count()", uint256(0));
        claims[3] = DeploymentCheckLib.becomes("GOLD::pool", "count", uint256(0));
        claims[4] = DeploymentCheckLib.reverts(
            "GOLD::pool",
            "fails()",
            abi.encodeWithSelector(CheckPool.Empty.selector, 0)
        );

        CheckHarness(harness).end(_check(before, claims, "paused-through-an-emptier"));

        assertEq(CheckHarness(harness).historyReads(), 0);
    }

    function test_readsViewsAtTheAddressesTheBatchWroteAndPaid() public {
        // An address the batch wrote an entry for, and one it paid, are read at by the address views, before and
        // after: neither is known otherwise.
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).credit(carol, 3);
        CheckToken(token).mint(dave, 1);
        DeploymentCheckLib.Claim[] memory claims = _claims(
            DeploymentCheckLib.becomes("GOLD::pool", _called("credits", carol), uint256(3)),
            DeploymentCheckLib.becomes("GOLD::pool", _entryOf("credits", carol), uint256(3)),
            DeploymentCheckLib.becomes("GOLD::token", _called("balanceOf", dave), uint256(1))
        );

        CheckHarness(harness).end(_check(before, claims, "known"));
    }

    function test_endsAtTheStateAfterTheBatch() public {
        // The reads revert the fork to before the batch and back: the caller continues after the batch.
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).setCount(5);

        CheckHarness(harness).end(_check(before, _claims(_poolChanges()), "ends-after"));

        assertEq(CheckPool(pool).count(), 5);
    }

    // ── the transfer rule ─────────────────────────────────────────────────────────────────────────

    function test_transfersClaimTheBalancesAndSupplyTheyExplain() public {
        // A mint and a transfer: the parties' balances and the supply, in views and in storage, move by exactly the
        // logs, so the rule claims them all. The check gives the batch's logs back.
        uint256 before = CheckHarness(harness).begin();
        CheckToken(token).mint(alice, 10);
        vm.startPrank(alice);
        CheckToken(token).transfer(bob, 4);
        vm.stopPrank();

        Vm.Log[] memory logs = CheckHarness(harness).end(_check(before, _none(), "transfers"));

        assertEq(logs.length, 2);
    }

    function test_aTokenThatMovesOtherThanItsTransfersFails() public {
        // A mint logged as one less than it is: the supply and the balance moved by 10, the logs say 9.
        uint256 before = CheckHarness(harness).begin();
        CheckToken(token).mintMislogged(alice, 10);
        DeploymentCheckLib.Check memory check = _check(before, _none(), "mislogged");

        string memory head = string.concat("transfers: ", vm.toString(token));
        _expectFailure(
            string.concat(
                string.concat(head, " totalSupply() moved by 10, its transfers by 9\n"),
                string.concat(head, " ", _called("balanceOf", alice), " moved by 10, its transfers by 9")
            )
        );
        CheckHarness(harness).end(check);
    }

    function test_aTokenOutsideTheListingIsCheckedThroughItsViews() public {
        // A token no proxy of the listing is: its storage is not claimed, but its views must move by its logs.
        uint256 before = CheckHarness(harness).begin();
        CheckToken(outsideToken).mint(bob, 3);
        CheckHarness(harness).end(_check(before, _none(), "outside-token"));

        before = CheckHarness(harness).begin();
        CheckToken(outsideToken).mintMislogged(alice, 10);
        DeploymentCheckLib.Check memory check = _check(before, _none(), "outside-token-mislogged");

        string memory head = string.concat("transfers: ", vm.toString(outsideToken));
        _expectFailure(
            string.concat(
                string.concat(head, " totalSupply() moved by 10, its transfers by 9\n"),
                string.concat(head, " ", _called("balanceOf", alice), " moved by 10, its transfers by 9")
            )
        );
        CheckHarness(harness).end(check);
    }

    // ── the batch's transactions, as run-campaign-test gives them ─────────────────────────────────

    function test_transactionsAreReadFromACommaSeparatedList() public view {
        // None, one, and two in the order listed; the names the runner gives them under are its.
        bytes32 first = keccak256("first");
        bytes32 second = keccak256("second");
        assertEq(CheckHarness(harness).transactions("").length, 0);
        bytes32[] memory one = CheckHarness(harness).transactions(vm.toString(first));
        assertEq(one.length, 1);
        assertEq(one[0], first);
        bytes32[] memory two = CheckHarness(harness).transactions(
            string.concat(vm.toString(first), ",", vm.toString(second))
        );
        assertEq(two.length, 2);
        assertEq(two[0], first);
        assertEq(two[1], second);
        assertEq(DeploymentCheckLib.LISTING, "BAO_CHECK_LISTING");
        assertEq(DeploymentCheckLib.FOLDER, "BAO_CHECK_FOLDER");
        assertEq(DeploymentCheckLib.TRANSACTIONS, "_TRANSACTIONS");
    }

    function test_anEntryNotA32ByteHashStopsTheList() public {
        // Too short, a character not hex, no `0x`, and an empty entry between two hashes.
        string memory hash = vm.toString(keccak256("first"));
        string[4] memory wrong = [
            "0x1234",
            "0xg111111111111111111111111111111111111111111111111111111111111111",
            vm.replace(hash, "0x", "00"),
            ""
        ];
        for (uint256 i = 0; i < wrong.length; ++i) {
            string memory list = string.concat(hash, ",", wrong[i]);
            vm.expectRevert(abi.encodeWithSelector(DeploymentCheckLib.NotATransactionHash.selector, wrong[i]));
            CheckHarness(harness).transactions(list);
        }
    }

    // ── the files ─────────────────────────────────────────────────────────────────────────────────

    function test_writesTheReadsTheChangesAndTheOutsideWrites() public {
        // The reads before and after, the changes with what claims each, and the writes outside the listing, each a
        // line; each file first holds a marker this run must replace.
        string memory folder = "tmp/check/files";
        string[4] memory files = ["before.tsv", "after.tsv", "changes.tsv", "outside.tsv"];
        vm.createDir(folder, true);
        for (uint256 i = 0; i < files.length; ++i) {
            vm.writeFile(string.concat(folder, "/", files[i]), "marker\n");
        }
        uint256 before = CheckHarness(harness).begin();
        CheckPool(pool).setCount(5);
        CheckToken(outsideToken).mint(bob, 1);

        CheckHarness(harness).end(_check(before, _claims(_poolChanges()), "files"));

        string memory reasoned = string.concat("changes: ", REASON);
        assertTrue(vm.contains(vm.readFile(string.concat(folder, "/before.tsv")), "GOLD::pool\tcount()\t0\n"));
        assertTrue(vm.contains(vm.readFile(string.concat(folder, "/after.tsv")), "GOLD::pool\tcount()\t5\n"));
        string memory changed = vm.readFile(string.concat(folder, "/changes.tsv"));
        assertTrue(vm.contains(changed, string.concat("GOLD::pool\tcount()\t0\t5\t", reasoned, "\n")));
        assertTrue(vm.contains(changed, string.concat("GOLD::pool\tcount\t0\t5\t", reasoned, "\n")));
        string memory supplyWrite = string.concat(
            vm.toString(outsideToken),
            "\t",
            vm.toString(bytes32(uint256(1))),
            "\t",
            vm.toString(bytes32(0)),
            "\t",
            vm.toString(bytes32(uint256(1)))
        );
        assertTrue(vm.contains(vm.readFile(string.concat(folder, "/outside.tsv")), supplyWrite));
        for (uint256 i = 0; i < files.length; ++i) {
            assertFalse(vm.contains(vm.readFile(string.concat(folder, "/", files[i])), "marker"));
        }
    }
}

/// A batch where it ran: two mined USDT transfers by one sender, the second spending from what the first left,
/// replayed in turn on a fork made at the first.
contract DeploymentCheckLibReplayTest is BaoTest {
    bytes32 private constant FIRST = 0xd3257e6cf6263636441c2af629d715f2f5c6e324bc1c5cbe420541a96d6d26dd;
    bytes32 private constant SECOND = 0x56789792fc43c17027bd7d9bf2a4a4d5cc7f8290a36bcdd84f82ba2e8cee395b;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant SENDER = 0x46a87250486D95402EE3881FF660b3A11e5F2089;
    address private constant FIRST_RECIPIENT = 0x36E57be043A9DC8a765b7bF55885229F4a28D6fE;
    address private constant SECOND_RECIPIENT = 0x600377b617a82FC6A4b6f2d2199882e5Bd975037;
    uint256 private constant FIRST_AMOUNT = 1_400_000_000;
    uint256 private constant SECOND_AMOUNT = 3_000_000_000;

    function test_replayAppliesEachMinedTransactionInTurn() public {
        // Each transfer as the chain ran it, in order: its log, and the balances it moved.
        createSelectForkAtTransaction("mainnet", FIRST);
        uint256 sender = IERC20(USDT).balanceOf(SENDER);
        uint256 first = IERC20(USDT).balanceOf(FIRST_RECIPIENT);
        uint256 second = IERC20(USDT).balanceOf(SECOND_RECIPIENT);
        bytes32[] memory batch = new bytes32[](2);
        (batch[0], batch[1]) = (FIRST, SECOND);
        vm.recordLogs();

        DeploymentCheckLib.replay(batch);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        address[2] memory recipients = [FIRST_RECIPIENT, SECOND_RECIPIENT];
        uint256[2] memory amounts = [FIRST_AMOUNT, SECOND_AMOUNT];
        for (uint256 i = 0; i < logs.length; ++i) {
            assertEq(logs[i].emitter, USDT);
            assertEq(logs[i].topics[0], DeploymentCheckLib.TRANSFER);
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(SENDER))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(recipients[i]))));
            assertEq(abi.decode(logs[i].data, (uint256)), amounts[i]);
        }
        assertEq(IERC20(USDT).balanceOf(SENDER), sender - FIRST_AMOUNT - SECOND_AMOUNT);
        assertEq(IERC20(USDT).balanceOf(FIRST_RECIPIENT), first + FIRST_AMOUNT);
        assertEq(IERC20(USDT).balanceOf(SECOND_RECIPIENT), second + SECOND_AMOUNT);
    }
}
