// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20PermitUpgradeable} from "@bao/ERC20PermitUpgradeable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

// Mock implementation of ERC20PermitUpgradeable for testing
contract MockERC20Permit is Initializable, ERC20PermitUpgradeable {
    // Mapping of approvals (owner => spender => amount)
    mapping(address => mapping(address => uint256)) private _allowances;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function initialize(string memory name) public initializer {
        __ERC20Permit_init(name);
    }

    // Implementation of _approve required by ERC20PermitUpgradeable
    function _approve(address owner, address spender, uint256 value) internal override {
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    // View function to check allowances
    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }
}

contract TestERC20PermitUpgradeable is Test {
    using ECDSA for bytes32;

    MockERC20Permit public token;
    string public constant TOKEN_NAME = "Test Token";

    address public owner;
    uint256 public ownerPrivateKey;

    address public spender;

    function setUp() public {
        // Create token
        token = new MockERC20Permit();
        token.initialize(TOKEN_NAME);

        // Set up owner with a known private key
        ownerPrivateKey = 0xA11CE;
        owner = vm.addr(ownerPrivateKey);

        // Set up spender
        spender = address(0xB0B);
    }

    function test_initialization() public {
        // Create a new instance to test initialization
        MockERC20Permit newToken = new MockERC20Permit();
        newToken.initialize(TOKEN_NAME);

        // Verify cannot initialize twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        newToken.initialize(TOKEN_NAME);

        // Check that DOMAIN_SEPARATOR is properly set
        bytes32 domainSeparator = newToken.DOMAIN_SEPARATOR();
        assertFalse(domainSeparator == bytes32(0), "Domain separator should not be zero");

        // Check initial nonce is zero
        assertEq(newToken.nonces(owner), 0, "Initial nonce should be zero");
    }

    function test_permit() public {
        // Check initial allowance and nonce
        assertEq(token.allowance(owner, spender), 0, "Initial allowance should be zero");
        assertEq(token.nonces(owner), 0, "Initial nonce should be zero");

        // Prepare permit data
        uint256 value = 1000;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        // Create the permit signature
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        vm.expectEmit(true, true, false, true);
        emit MockERC20Permit.Approval(owner, spender, value);
        token.permit(owner, spender, value, deadline, v, r, s);

        // Verify allowance was set
        assertEq(token.allowance(owner, spender), value, "Allowance not set correctly");

        // Verify nonce was incremented
        assertEq(token.nonces(owner), nonce + 1, "Nonce should be incremented");
    }

    function test_permitExpiredDeadline() public {
        // Prepare permit data with expired deadline
        uint256 value = 1000;
        uint256 deadline = block.timestamp - 1; // Already expired
        uint256 nonce = token.nonces(owner);

        // Create the permit signature
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Expect revert due to expired deadline
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, spender, value, deadline, v, r, s);

        // Verify allowance remains unchanged
        assertEq(token.allowance(owner, spender), 0, "Allowance should remain zero");

        // Verify nonce remains unchanged
        assertEq(token.nonces(owner), nonce, "Nonce should remain unchanged");
    }

    function test_permitInvalidSigner() public {
        // Prepare permit data
        uint256 value = 1000;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        // Create the permit signature
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        // Sign with a different private key
        uint256 wrongPrivateKey = 0xB0B;
        address wrongSigner = vm.addr(wrongPrivateKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);

        // Expect revert due to invalid signer
        vm.expectRevert(
            abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, wrongSigner, owner)
        );
        token.permit(owner, spender, value, deadline, v, r, s);

        // Verify allowance remains unchanged
        assertEq(token.allowance(owner, spender), 0, "Allowance should remain zero");

        // Verify nonce remains unchanged
        assertEq(token.nonces(owner), nonce, "Nonce should remain unchanged");
    }

    function test_permitReplayProtection() public {
        // Prepare permit data
        uint256 value = 1000;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        // Create the permit signature
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        token.permit(owner, spender, value, deadline, v, r, s);

        // Try to replay the same permit
        vm.expectRevert(); // Will fail due to nonce mismatch
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_permitMaxValues() public {
        // Prepare permit data with max values
        uint256 value = type(uint256).max;
        uint256 deadline = type(uint256).max;
        uint256 nonce = token.nonces(owner);

        // Create the permit signature
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        token.permit(owner, spender, value, deadline, v, r, s);

        // Verify allowance was set to max
        assertEq(token.allowance(owner, spender), type(uint256).max, "Max allowance not set correctly");
    }

    function test_permitZeroValues() public {
        // First set a non-zero allowance
        uint256 initialValue = 1000;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        // Create first permit signature
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, initialValue, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        token.permit(owner, spender, initialValue, deadline, v, r, s);

        // Now set zero allowance
        uint256 zeroValue = 0;
        nonce = token.nonces(owner); // Get updated nonce

        // Create second permit signature
        structHash = keccak256(abi.encode(permitTypehash, owner, spender, zeroValue, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (v, r, s) = vm.sign(ownerPrivateKey, digest);
        token.permit(owner, spender, zeroValue, deadline, v, r, s);

        // Verify allowance was set to zero
        assertEq(token.allowance(owner, spender), 0, "Allowance should be reset to zero");
    }

    function test_domainSeparator() public {
        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        assertFalse(domainSeparator == bytes32(0), "Domain separator should not be zero");

        // Create a new token with the same name
        MockERC20Permit newToken = new MockERC20Permit();
        newToken.initialize(TOKEN_NAME);

        // Domain separators should NOT match because addresses are different
        assertTrue(
            token.DOMAIN_SEPARATOR() != newToken.DOMAIN_SEPARATOR(),
            "Domain separators should differ due to different contract addresses"
        );

        // Verify domain separator remains constant for the same contract
        bytes32 secondCall = token.DOMAIN_SEPARATOR();
        assertEq(domainSeparator, secondCall, "Domain separator should be consistent for same contract");

        // Create a token with different name
        MockERC20Permit differentToken = new MockERC20Permit();
        differentToken.initialize("Different Token");

        // Domain separators should be different
        assertTrue(
            token.DOMAIN_SEPARATOR() != differentToken.DOMAIN_SEPARATOR(),
            "Domain separators should differ for different names"
        );
    }

    function test_noncesIncrement() public {
        // Check initial nonce
        assertEq(token.nonces(owner), 0, "Initial nonce should be zero");

        // Prepare and execute multiple permits
        for (uint256 i = 0; i < 3; i++) {
            uint256 nonce = token.nonces(owner);
            uint256 value = 1000 + i;
            uint256 deadline = block.timestamp + 1 hours;

            bytes32 permitTypehash = keccak256(
                "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
            );
            bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, nonce, deadline));
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
            token.permit(owner, spender, value, deadline, v, r, s);

            // Verify nonce incremented correctly
            assertEq(token.nonces(owner), nonce + 1, "Nonce should increment correctly");
        }

        // Final nonce should be 3
        assertEq(token.nonces(owner), 3, "Final nonce should be 3");
    }
}
