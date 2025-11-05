// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeTarget {
    uint256 internal storedValue;

    function initialize(uint256 newValue) external {
        storedValue = newValue;
    }

    function setValue(uint256 newValue) external {
        storedValue = newValue;
    }

    function value() external view returns (uint256) {
        return storedValue;
    }
}

contract UUPSProxyDeployStubTest is BaoDeploymentTest {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC;

    UUPSProxyDeployStub internal stub;
    address internal owner;
    address internal outsider;

    function setUp() public {
        super.setUp();
        // TODO:
        owner = address(this);
        stub = new UUPSProxyDeployStub();
        outsider = makeAddr("outsider");
        vm.label(address(stub), "stub");
        vm.label(owner, "owner");
        vm.label(outsider, "outsider");
    }

    function test_OwnerIsBakedIntoBytecode() public view {
        assertEq(stub.owner(), owner, "constructor pins owner");
    }

    function test_UpgradeToRequiresOwner() public {
        UpgradeTarget target = new UpgradeTarget();

        vm.expectRevert(UUPSProxyDeployStub.NotOwner.selector);
        vm.prank(outsider);
        stub.upgradeTo(address(target));

        stub.upgradeTo(address(target));

        bytes32 raw = vm.load(address(stub), IMPLEMENTATION_SLOT);
        address stored = address(uint160(uint256(raw)));
        assertEq(stored, address(target), "implementation stored");
    }

    function test_UpgradeToAndCallThroughProxy() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(stub), bytes(""));
        UUPSProxyDeployStub proxyStub = UUPSProxyDeployStub(address(proxy));

        UpgradeTarget target = new UpgradeTarget();

        vm.prank(outsider);
        vm.expectRevert(UUPSProxyDeployStub.NotOwner.selector);
        proxyStub.upgradeToAndCall(address(target), bytes(""));

        vm.prank(owner);
        proxyStub.upgradeToAndCall(address(target), abi.encodeCall(UpgradeTarget.initialize, (17)));

        (, bytes memory result) = address(proxy).call(abi.encodeWithSignature("value()"));
        uint256 value = abi.decode(result, (uint256));
        assertEq(value, 17, "upgrade target initialised via delegatecall");

        vm.prank(owner);
        (bool ok, ) = address(proxy).call(abi.encodeWithSignature("setValue(uint256)", 99));
        assertTrue(ok, "mutable call succeeds post-upgrade");
    }

    function test_ProxiableUUIDMatchesSlot() public view {
        assertEq(stub.proxiableUUID(), IMPLEMENTATION_SLOT, "UUID matches slot");
    }
}
