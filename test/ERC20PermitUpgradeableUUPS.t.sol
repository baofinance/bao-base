// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ERC20PermitUpgradeable} from "@bao/ERC20PermitUpgradeable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

// Base Mock ERC20Permit contract with UUPS upgrade pattern
contract MockERC20PermitUpgradeable is Initializable, UUPSUpgradeable, OwnableUpgradeable, ERC20PermitUpgradeable {
    // Mapping of approvals (owner => spender => amount)
    mapping(address => mapping(address => uint256)) private _allowances;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function initialize(string memory name, address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __ERC20Permit_init(name);
        __UUPSUpgradeable_init();
    }

    function _approve(address owner, address spender, uint256 value) internal override {
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // This function exposes internal EIP712 version for testing
    function getVersion() public pure virtual returns (string memory) {
        return "1";
    }
}

// V2 implementation with a different version
contract MockERC20PermitUpgradeableV2 is MockERC20PermitUpgradeable {
    // Override the version for V2
    function getVersion() public pure virtual override returns (string memory) {
        return "2";
    }

    // We need to override the EIP712 version used internally
    // This requires us to modify the EIP712 initialization
    function reinitializeEIP712(string memory name) public reinitializer(2) {
        __EIP712_init(name, "2"); // Use version 2 here
    }
}

contract ERC20PermitUUPSTest is Test {
    using ECDSA for bytes32;

    address public owner;
    MockERC20PermitUpgradeable public implementation;
    address public proxy;
    string public constant TOKEN_NAME = "Test Token";

    address public user;
    uint256 public userPrivateKey;
    address public spender;

    function setUp() public {
        // Setup accounts
        owner = address(0xA11CE);
        vm.startPrank(owner);

        // Deploy implementation and proxy
        implementation = new MockERC20PermitUpgradeable();
        proxy = UnsafeUpgrades.deployUUPSProxy(
            address(implementation),
            abi.encodeCall(MockERC20PermitUpgradeable.initialize, (TOKEN_NAME, owner))
        );

        // Setup user for permit testing
        userPrivateKey = 0xB0B;
        user = vm.addr(userPrivateKey);
        spender = address(0xCAFE);

        vm.stopPrank();
    }

    struct PermitData {
        uint256 value;
        uint256 nonce;
        uint256 deadline;
        bytes32 typeHash;
    }

    struct SignData {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function test_domainSeparatorWithProxy() public {
        // Get domain separator from proxy
        bytes32 initialDomainSeparator = MockERC20PermitUpgradeable(proxy).DOMAIN_SEPARATOR();

        // Make sure it's not zero
        assertFalse(initialDomainSeparator == bytes32(0), "Domain separator should not be zero");

        // Create permit signature using the initial domain separator
        PermitData memory pd;
        pd.value = 1000;
        pd.deadline = block.timestamp + 1 hours;
        pd.nonce = MockERC20PermitUpgradeable(proxy).nonces(user);

        pd.typeHash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(pd.typeHash, user, spender, pd.value, pd.nonce, pd.deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", initialDomainSeparator, structHash));

        SignData memory sd;
        (sd.v, sd.r, sd.s) = vm.sign(userPrivateKey, digest);

        // Verify permit works with current implementation
        vm.prank(user);
        MockERC20PermitUpgradeable(proxy).permit(user, spender, pd.value, pd.deadline, sd.v, sd.r, sd.s);

        assertEq(
            MockERC20PermitUpgradeable(proxy).allowance(user, spender),
            pd.value,
            "Permit should have set allowance"
        );

        // Now upgrade to V2
        MockERC20PermitUpgradeableV2 implementationV2 = new MockERC20PermitUpgradeableV2();

        vm.prank(owner);
        UUPSUpgradeable(proxy).upgradeToAndCall(
            address(implementationV2),
            abi.encodeCall(MockERC20PermitUpgradeableV2.reinitializeEIP712, (TOKEN_NAME))
        );

        // Get domain separator after upgrade
        bytes32 upgradedDomainSeparator = MockERC20PermitUpgradeableV2(proxy).DOMAIN_SEPARATOR();

        // Verify domain separator has changed
        assertNotEq(
            initialDomainSeparator,
            upgradedDomainSeparator,
            "Domain separator should change after upgrade with version change"
        );

        // Verify the version was updated
        assertEq(MockERC20PermitUpgradeableV2(proxy).getVersion(), "2", "Version should be updated");

        // Try to use the old signature - should fail
        uint256 newNonce = MockERC20PermitUpgradeableV2(proxy).nonces(user);
        uint256 newValue = 2000;

        // Create new signature with old domain separator (which would be invalid)
        bytes32 newStructHash = keccak256(abi.encode(pd.typeHash, user, spender, newValue, newNonce, pd.deadline));
        bytes32 oldDigest = keccak256(abi.encodePacked("\x19\x01", initialDomainSeparator, newStructHash));

        (sd.v, sd.r, sd.s) = vm.sign(userPrivateKey, oldDigest);

        // This should fail because the domain separator has changed
        // the exact error has the recovered signer not the current one and we can't easily determine the recovered one
        vm.expectRevert /*ERC20PermitUpgradeable.ERC2612InvalidSigner.selector*/();
        vm.prank(user);
        MockERC20PermitUpgradeableV2(proxy).permit(user, spender, newValue, pd.deadline, sd.v, sd.r, sd.s);

        // Now create a signature with the new domain separator
        bytes32 newDigest = keccak256(abi.encodePacked("\x19\x01", upgradedDomainSeparator, newStructHash));

        (sd.v, sd.r, sd.s) = vm.sign(userPrivateKey, newDigest);

        // This should work
        vm.prank(user);
        MockERC20PermitUpgradeableV2(proxy).permit(user, spender, newValue, pd.deadline, sd.v, sd.r, sd.s);

        // Verify the new allowance was set
        assertEq(
            MockERC20PermitUpgradeableV2(proxy).allowance(user, spender),
            newValue,
            "New permit should have set allowance"
        );
    }

    function test_proxyAddressStability() public {
        // The proxy address should remain the same after upgrade
        address beforeUpgradeAddress = proxy;

        // Upgrade to V2
        MockERC20PermitUpgradeableV2 implementationV2 = new MockERC20PermitUpgradeableV2();

        vm.prank(owner);
        UUPSUpgradeable(proxy).upgradeToAndCall(
            address(implementationV2),
            abi.encodeCall(MockERC20PermitUpgradeableV2.reinitializeEIP712, (TOKEN_NAME))
        );

        // Verify address is the same
        assertEq(beforeUpgradeAddress, proxy, "Proxy address should remain the same after upgrade");
    }

    function test_sameDomainSeparatorWithoutVersionChange() public {
        // Get initial domain separator
        bytes32 initialDomainSeparator = MockERC20PermitUpgradeable(proxy).DOMAIN_SEPARATOR();

        // Deploy a new implementation without changing the version
        MockERC20PermitUpgradeable implementationV1a = new MockERC20PermitUpgradeable();

        vm.prank(owner);
        UUPSUpgradeable(proxy).upgradeToAndCall(
            address(implementationV1a),
            "" // No initialization call needed
        );

        // Get domain separator after upgrade
        bytes32 upgradedDomainSeparator = MockERC20PermitUpgradeable(proxy).DOMAIN_SEPARATOR();

        // Verify domain separator has NOT changed (since version is the same)
        assertEq(
            initialDomainSeparator,
            upgradedDomainSeparator,
            "Domain separator should remain the same when version doesn't change"
        );
    }
}
