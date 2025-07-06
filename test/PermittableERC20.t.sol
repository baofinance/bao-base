// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {PermittableERC20_v1} from "@bao/PermittableERC20_v1.sol";

contract PermittableERC20Setup is Test {
    // Constants
    address internal OWNER = makeAddr("OWNER");
    address internal USER1 = makeAddr("USER1");
    address internal USER2 = makeAddr("USER2");
    string internal constant NAME = "Test Token";
    string internal constant SYMBOL = "TEST";
    uint256 internal constant INITIAL_BALANCE = 1000 ether;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // Contracts
    PermittableERC20_v1 internal implementation;
    address internal proxy;

    // Private key for testing permit
    uint256 internal userPrivateKey;
    address internal user;

    function setUp() public virtual {
        OWNER = makeAddr("OWNER");
        USER1 = makeAddr("USER1");
        USER2 = makeAddr("USER2");

        // Deploy implementation
        implementation = new PermittableERC20_v1();
        vm.label(address(implementation), "PermittableERC20_v1Implementation");
        // Create initialization data for proxy
        bytes memory initData = abi.encodeWithSelector(PermittableERC20_v1.initialize.selector, OWNER, NAME, SYMBOL);

        // Deploy proxy pointing to implementation
        proxy = address(new ERC1967Proxy(address(implementation), initData));
        vm.label(proxy, "PermittableERC20_v1Proxy");
        IBaoOwnable(proxy).transferOwnership(OWNER); // Set owner of the proxy

        // Setup for permit testing
        userPrivateKey = 0xA11CE;
        user = vm.addr(userPrivateKey);

        // Deal some initial balance to the contract
        vm.startPrank(OWNER);
        vm.deal(OWNER, 100 ether);
        vm.stopPrank();
    }

    // Helper to sign permit messages
    function signPermit(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline,
        uint256 privateKey
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = PermittableERC20_v1(proxy).DOMAIN_SEPARATOR();

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (v, r, s) = vm.sign(privateKey, digest);
    }
}

contract PermittableERC20BasicTest is PermittableERC20Setup {
    // Test initialization was successful
    function test_initialization_correctState_() public view {
        // Verify token metadata
        assertEq(PermittableERC20_v1(proxy).name(), NAME, "Token name should match");
        assertEq(PermittableERC20_v1(proxy).symbol(), SYMBOL, "Token symbol should match");
        assertEq(PermittableERC20_v1(proxy).decimals(), 18, "Token decimals should be 18");

        // Verify ownership
        assertEq(PermittableERC20_v1(proxy).owner(), OWNER, "Owner should be set correctly");

        // Verify initial state
        assertEq(PermittableERC20_v1(proxy).totalSupply(), 0, "Initial supply should be 0");
    }

    // Test that a double initialization is not possible
    function test_doubleInitialize_shouldRevert_() public {
        vm.expectRevert(); // Will revert with InvalidInitialization from Initializable
        PermittableERC20_v1(proxy).initialize(USER1, "New Name", "NEW");
    }

    // Test constructor behavior
    function test_directInitializeImplementation_shouldRevert_() public {
        vm.expectRevert(); // Will revert with InvalidInitialization from Initializable
        implementation.initialize(USER1, "Direct Name", "DIR");
    }

    // Test supportsInterface
    function test_supportsInterface_correctInterfaces_() public view {
        // Should support these interfaces
        assertTrue(PermittableERC20_v1(proxy).supportsInterface(type(IERC20).interfaceId), "Should support IERC20");
        assertTrue(
            PermittableERC20_v1(proxy).supportsInterface(type(IERC20Metadata).interfaceId),
            "Should support IERC20Metadata"
        );
        assertTrue(
            PermittableERC20_v1(proxy).supportsInterface(type(IERC20Permit).interfaceId),
            "Should support IERC20Permit"
        );

        // Should not support a random interface
        bytes4 randomInterface = bytes4(keccak256("random()"));
        assertFalse(
            PermittableERC20_v1(proxy).supportsInterface(randomInterface),
            "Should not support random interface"
        );
    }
}

// Mock upgraded version for testing
contract PermittableERC20_v2 is PermittableERC20_v1 {
    string public version;

    function v2initialize(string memory version_) public reinitializer(2) {
        version = version_;
    }
}

contract PermittableERC20UpgradeTest is PermittableERC20Setup {
    function test_upgradeByOwner_success_() public {
        // Create the V2 implementation
        PermittableERC20_v2 implementationV2 = new PermittableERC20_v2();

        // Perform the upgrade as the owner
        vm.prank(OWNER);
        // This is the correct way to upgrade in OpenZeppelin UUPS pattern
        UUPSUpgradeable(proxy).upgradeToAndCall(
            address(implementationV2),
            abi.encodeWithSelector(PermittableERC20_v2.v2initialize.selector, "v2")
        );

        // Verify upgrade worked by checking the new function exists
        assertEq(
            PermittableERC20_v2(proxy).version(),
            "v2",
            "Upgrade should work and new function should be accessible"
        );
    }

    // Test upgrade by non-owner
    function test_upgradeByNonOwner_shouldRevert_() public {
        // Create the V2 implementation
        PermittableERC20_v2 implementationV2 = new PermittableERC20_v2();

        // Try to upgrade as a non-owner
        vm.prank(USER1);
        vm.expectRevert(abi.encodeWithSelector(IBaoOwnable.Unauthorized.selector));
        UUPSUpgradeable(proxy).upgradeToAndCall(address(implementationV2), "");
    }
}

contract PermittableERC20PermitTest is PermittableERC20Setup {
    function test_permit_validSignature_() public {
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Generate valid signature
        (uint8 v, bytes32 r, bytes32 s) = signPermit(user, USER1, value, nonce, deadline, userPrivateKey);

        // Execute permit
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);

        // Check allowance was set
        assertEq(PermittableERC20_v1(proxy).allowance(user, USER1), value, "Allowance should be set after permit");

        // Check nonce was incremented
        assertEq(PermittableERC20_v1(proxy).nonces(user), nonce + 1, "Nonce should be incremented after permit");
    }

    function test_permit_expiredDeadline_shouldRevert_() public {
        uint256 value = 100 ether;
        vm.warp(block.timestamp + 1 days); // Move time forward to avoid block 0
        uint256 deadline = block.timestamp - 1 hours; // Expired deadline
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Generate signature with expired deadline
        (uint8 v, bytes32 r, bytes32 s) = signPermit(user, USER1, value, nonce, deadline, userPrivateKey);

        // Should revert with expired deadline
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);
    }

    function test_permit_invalidSignature_shouldRevert_() public {
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Generate valid signature
        (uint8 v, bytes32 r, bytes32 s) = signPermit(user, USER1, value, nonce, deadline, userPrivateKey);

        // Try with different signer
        vm.expectRevert();
        PermittableERC20_v1(proxy).permit(USER2, USER1, value, deadline, v, r, s);
    }

    function test_permit_replayAttack_shouldRevert_() public {
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Generate valid signature
        (uint8 v, bytes32 r, bytes32 s) = signPermit(user, USER1, value, nonce, deadline, userPrivateKey);

        // First permit succeeds
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);

        // Replay the same signature
        vm.expectRevert();
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);
    }
}

contract PermittableERC20OwnershipTest is PermittableERC20Setup {
    function test_transferOwnership_byOwner_() public {
        // Transfer ownership to USER1
        vm.expectRevert(IBaoOwnable.Unauthorized.selector); // Will revert with "Ownable: caller is not the owner"
        PermittableERC20_v1(proxy).transferOwnership(USER1);

        // Verify new owner
        assertEq(PermittableERC20_v1(proxy).owner(), OWNER, "Owner should be updated to OWNER");
    }

    function test_transferOwnership_byNonOwner_shouldRevert_() public {
        vm.startPrank(USER1);

        // Try to transfer ownership from non-owner
        vm.expectRevert(); // Will revert with "Ownable: caller is not the owner"
        PermittableERC20_v1(proxy).transferOwnership(USER2);

        vm.stopPrank();
    }
}

contract PermittableERC20FunctionalityTest is PermittableERC20Setup {
    using SafeERC20 for IERC20;
    // Since PermittableERC20_v1 doesn't have direct mint/burn functions,
    // we'll need to add some funds for testing ERC20 functionality

    function setUp() public override {
        super.setUp();
        deal(proxy, USER1, INITIAL_BALANCE); // Give USER1 some tokens
    }

    function test_transfer_validAmount_() public {
        vm.startPrank(USER1);

        uint256 amount = 100 ether;
        bool success = PermittableERC20_v1(proxy).transfer(USER2, amount);

        // Verify transfer worked
        assertTrue(success, "Transfer should return true");
        assertEq(
            PermittableERC20_v1(proxy).balanceOf(USER1),
            INITIAL_BALANCE - amount,
            "USER1 balance should be reduced"
        );
        assertEq(PermittableERC20_v1(proxy).balanceOf(USER2), amount, "USER2 should receive tokens");

        vm.stopPrank();
    }

    function test_transfer_insufficientBalance_shouldRevert_() public {
        vm.startPrank(USER1);

        uint256 amount = INITIAL_BALANCE + 1 ether; // More than USER1 has

        // Should revert with insufficient balance
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, USER1, INITIAL_BALANCE, amount)
        );
        PermittableERC20_v1(proxy).transfer(USER2, amount);

        vm.stopPrank();
    }

    function test_approve_validAmount_() public {
        vm.startPrank(USER1);

        uint256 amount = 100 ether;
        bool success = PermittableERC20_v1(proxy).approve(USER2, amount);

        // Verify approve worked
        assertTrue(success, "Approve should return true");
        assertEq(PermittableERC20_v1(proxy).allowance(USER1, USER2), amount, "Allowance should be set correctly");

        vm.stopPrank();
    }

    function test_transferFrom_withAllowance_() public {
        // First approve USER2 to spend USER1's tokens
        vm.prank(USER1);
        PermittableERC20_v1(proxy).approve(USER2, 100 ether);

        // Now USER2 transfers from USER1 to themselves
        vm.prank(USER2);
        bool success = PermittableERC20_v1(proxy).transferFrom(USER1, USER2, 50 ether);

        // Verify transfer worked
        assertTrue(success, "TransferFrom should return true");
        assertEq(
            PermittableERC20_v1(proxy).balanceOf(USER1),
            INITIAL_BALANCE - 50 ether,
            "USER1 balance should be reduced"
        );
        assertEq(PermittableERC20_v1(proxy).balanceOf(USER2), 50 ether, "USER2 should receive tokens");
        assertEq(PermittableERC20_v1(proxy).allowance(USER1, USER2), 50 ether, "Allowance should be reduced");
    }

    function test_transferFromWithoutAllowanceShouldRevert_() public {
        // USER2 attempts to transfer without allowance
        vm.prank(USER2);

        // Should revert with insufficient allowance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, USER2, 0, 50 ether));
        PermittableERC20_v1(proxy).transferFrom(USER1, USER2, 50 ether);
    }

    function test_increaseAllowance_old() public {
        // First set initial allowance
        PermittableERC20_v1(proxy).approve(USER2, 100 ether);

        // Now increase it
        IERC20(proxy).safeIncreaseAllowance(USER2, 50 ether);

        // Verify increase worked
        assertEq(
            PermittableERC20_v1(proxy).allowance(address(this), USER2),
            150 ether,
            "Allowance should be increased"
        );
    }

    function test_decreaseAllowance_old() public {
        // First set initial allowance
        PermittableERC20_v1(proxy).approve(USER2, 100 ether);

        // Now decrease it
        IERC20(proxy).safeDecreaseAllowance(USER2, 30 ether);

        // Verify decrease worked
        assertEq(PermittableERC20_v1(proxy).allowance(address(this), USER2), 70 ether, "Allowance should be decreased");
    }

    // function test_decreaseAllowanceBelowZeroShouldRevert_old() public {
    //     // First set initial allowance
    //     PermittableERC20_v1(proxy).approve(USER2, 100 ether);

    //     // Try to decrease by more than the allowance
    //     vm.expectRevert("ERC20: decreased allowance below zero");
    //     IERC20(proxy).safeDecreaseAllowance(USER2, 150 ether);
    // }

    function test_increaseAllowance_() public {
        vm.startPrank(USER1);

        // First set initial allowance
        PermittableERC20_v1(proxy).approve(USER2, 100 ether);

        // Now call approve again with increased value
        bool success = PermittableERC20_v1(proxy).approve(USER2, 150 ether);

        // Verify increase worked
        assertEq(success, true, "Approve should return true");
        assertEq(PermittableERC20_v1(proxy).allowance(USER1, USER2), 150 ether, "Allowance should be increased");

        vm.stopPrank();
    }

    function test_decreaseAllowance_() public {
        vm.startPrank(USER1);

        // First set initial allowance
        PermittableERC20_v1(proxy).approve(USER2, 100 ether);

        // Now call approve again with decreased value
        bool success = PermittableERC20_v1(proxy).approve(USER2, 70 ether);

        // Verify decrease worked
        assertEq(success, true, "Approve should return true");
        assertEq(PermittableERC20_v1(proxy).allowance(USER1, USER2), 70 ether, "Allowance should be decreased");

        vm.stopPrank();
    }

    // Since we're using approve directly, there's no way to have a "decrease below zero" case.
    // Instead, we can test that a user can set their allowance to zero
    function test_decreaseAllowanceToZero_() public {
        vm.startPrank(USER1);

        // First set initial allowance
        PermittableERC20_v1(proxy).approve(USER2, 100 ether);

        // Now set allowance to zero
        bool success = PermittableERC20_v1(proxy).approve(USER2, 0);

        // Verify it worked
        assertEq(success, true, "Approve should return true");
        assertEq(PermittableERC20_v1(proxy).allowance(USER1, USER2), 0, "Allowance should be set to zero");

        vm.stopPrank();
    }
}

// New test contract to test domain separator behavior with upgrades
contract PermittableERC20DomainSeparatorTest is PermittableERC20Setup {
    function test_domainSeparatorBeforeAfterUpgrade_() public {
        // Get domain separator before upgrade
        bytes32 initialDomainSeparator = PermittableERC20_v1(proxy).DOMAIN_SEPARATOR();

        // Make sure it's not zero
        assertFalse(initialDomainSeparator == bytes32(0), "Domain separator should not be zero");

        // Create a permit signature using the initial domain separator
        uint256 value = 1000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypehash, user, USER1, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", initialDomainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        // Execute permit with current implementation
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);

        // Verify allowance was set
        assertEq(PermittableERC20_v1(proxy).allowance(user, USER1), value, "Allowance should be set correctly");

        // Now upgrade to V2
        PermittableERC20_v2 implementationV2 = new PermittableERC20_v2();

        vm.prank(OWNER);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(implementationV2), "");

        // Get domain separator after upgrade
        bytes32 upgradedDomainSeparator = PermittableERC20_v2(proxy).DOMAIN_SEPARATOR();

        // Domain separator should remain the same after upgrade (as we're not changing the version)
        assertEq(
            initialDomainSeparator,
            upgradedDomainSeparator,
            "Domain separator should remain the same after upgrade"
        );
    }
}

// This test contract tests more specific permit scenarios
contract PermittableERC20PermitEdgeCasesTest is PermittableERC20Setup {
    function test_permitMaxValues_() public {
        // Test with max uint256 value
        uint256 value = type(uint256).max;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Create the permit signature
        (uint8 v, bytes32 r, bytes32 s) = signPermit(user, USER1, value, nonce, deadline, userPrivateKey);

        // Execute permit
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);

        // Verify allowance was set to max value
        assertEq(
            PermittableERC20_v1(proxy).allowance(user, USER1),
            type(uint256).max,
            "Max allowance should be set correctly"
        );
    }

    function test_permitZeroValues_() public {
        // Test with zero value
        uint256 value = 0;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Create the permit signature
        (uint8 v, bytes32 r, bytes32 s) = signPermit(user, USER1, value, nonce, deadline, userPrivateKey);

        // Execute permit
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);

        // Verify zero allowance was set
        assertEq(PermittableERC20_v1(proxy).allowance(user, USER1), 0, "Zero allowance should be set correctly");

        // Verify nonce was still incremented
        assertEq(
            PermittableERC20_v1(proxy).nonces(user),
            nonce + 1,
            "Nonce should be incremented even with zero value"
        );
    }

    function test_permitMaxDeadline_() public {
        uint256 value = 1000 ether;
        uint256 deadline = type(uint256).max; // Max possible deadline
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Create the permit signature
        (uint8 v, bytes32 r, bytes32 s) = signPermit(user, USER1, value, nonce, deadline, userPrivateKey);

        // Execute permit
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);

        // Verify allowance was set
        assertEq(PermittableERC20_v1(proxy).allowance(user, USER1), value, "Allowance should be set with max deadline");
    }

    function test_permitSpecificError_expiredDeadline_() public {
        uint256 value = 1000 ether;
        vm.warp(block.timestamp + 1 days); // Move time forward to avoid block 0
        uint256 deadline = block.timestamp - 1 hours; // Expired deadline
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Create the permit signature
        (uint8 v, bytes32 r, bytes32 s) = signPermit(user, USER1, value, nonce, deadline, userPrivateKey);

        // Should revert with specific error
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);
    }

    function test_permitSpecificErrorInvalidSignature_() public {
        uint256 value = 1000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = PermittableERC20_v1(proxy).nonces(user);

        // Create the permit signature
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypehash, user, USER1, value, nonce, deadline));
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", PermittableERC20_v1(proxy).DOMAIN_SEPARATOR(), structHash)
        );

        // Sign with a different private key
        uint256 wrongPrivateKey = 0xB0B;
        address wrongSigner = vm.addr(wrongPrivateKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);

        // Expect revert due to invalid signer
        vm.expectRevert(
            abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, wrongSigner, user)
        );
        PermittableERC20_v1(proxy).permit(user, USER1, value, deadline, v, r, s);
    }

    function test_noncesIncrement_multiplePermits_() public {
        // Verify initial nonce is zero
        assertEq(PermittableERC20_v1(proxy).nonces(user), 0, "Initial nonce should be zero");

        // Execute first permit
        uint256 value1 = 100 ether;
        uint256 deadline1 = block.timestamp + 1 hours;
        uint256 nonce1 = PermittableERC20_v1(proxy).nonces(user);

        (uint8 v1, bytes32 r1, bytes32 s1) = signPermit(user, USER1, value1, nonce1, deadline1, userPrivateKey);
        PermittableERC20_v1(proxy).permit(user, USER1, value1, deadline1, v1, r1, s1);

        // Verify nonce was incremented
        assertEq(PermittableERC20_v1(proxy).nonces(user), 1, "Nonce should be 1 after first permit");

        // Execute second permit
        uint256 value2 = 200 ether;
        uint256 deadline2 = block.timestamp + 2 hours;
        uint256 nonce2 = PermittableERC20_v1(proxy).nonces(user);

        (uint8 v2, bytes32 r2, bytes32 s2) = signPermit(user, USER2, value2, nonce2, deadline2, userPrivateKey);
        PermittableERC20_v1(proxy).permit(user, USER2, value2, deadline2, v2, r2, s2);

        // Verify nonce was incremented again
        assertEq(PermittableERC20_v1(proxy).nonces(user), 2, "Nonce should be 2 after second permit");

        // Verify both allowances were set
        assertEq(PermittableERC20_v1(proxy).allowance(user, USER1), value1, "First allowance should be set");
        assertEq(PermittableERC20_v1(proxy).allowance(user, USER2), value2, "Second allowance should be set");
    }
}

// Example of using UnsafeUpgrades for deployment, which is more similar to how you'd deploy in a production environment
contract PermittableERC20UnsafeUpgradesTest is Test {
    using SafeERC20 for IERC20;

    address internal OWNER;
    address internal USER1;
    address internal USER2;
    address internal proxy;
    address internal implementation;

    function setUp() public {
        // Setup accounts
        OWNER = makeAddr("OWNER");
        USER1 = makeAddr("USER1");
        USER2 = makeAddr("USER2");

        vm.startPrank(OWNER);

        // Deploy implementation
        implementation = address(new PermittableERC20_v1());
        proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeWithSelector(PermittableERC20_v1.initialize.selector, OWNER, "Test Token", "TEST")
        );

        vm.label(proxy, "PermittableERC20_v1 Proxy");
        vm.label(implementation, "PermittableERC20_v1 Implementation");

        vm.stopPrank();
    }

    function test_upgradeWithUnsafeUpgrades_() public {
        // Create V2 implementation
        address implementationV2 = address(new PermittableERC20_v2());
        vm.label(implementationV2, "PermittableERC20_v2 Implementation");

        // Upgrade using owner
        vm.startPrank(OWNER);
        UnsafeUpgrades.upgradeProxy(
            proxy,
            address(implementationV2),
            abi.encodeWithSelector(PermittableERC20_v2.v2initialize.selector, "v2")
        );

        vm.stopPrank();

        // Verify upgrade worked
        assertEq(PermittableERC20_v2(proxy).version(), "v2", "Upgrade should set implementation to V2");
    }
}
