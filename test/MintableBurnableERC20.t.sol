// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// forge-config: default.allow_internal_expect_revert = true

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";

contract TestLeveragedTokensSetUp is Test {
    using ECDSA for bytes32;
    string name;
    string symbol;

    bytes4 Unauthorized_selector = bytes4(keccak256("Unauthorized()"));

    address leveragedImpl;
    address leveragedToken;
    address minter;
    address owner;
    address user1;
    Vm.Wallet user1Wallet;
    address user2;

    function setUpFork() internal virtual {
        owner = makeAddr("owner");
        minter = makeAddr("minter");

        name = "Leveraged wstETH against BaoUSD";
        symbol = "BaoUSDLwstETH";
    }

    function setUp_impl() internal {
        leveragedImpl = address(new MintableBurnableERC20_v1());
    }

    function setUp_proxy() internal {
        leveragedToken = address(
            MintableBurnableERC20_v1(
                UnsafeUpgrades.deployUUPSProxy(
                    leveragedImpl, //"MintableBurnableERC20_v1.sol",
                    abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, name, symbol))
                )
            )
        );
    }

    function setUpContract() internal virtual {
        setUp_impl();
        setUp_proxy();

        uint256 minterRole = IMintableRole(leveragedToken).MINTER_ROLE();
        uint256 burnerRole = IBurnableRole(leveragedToken).BURNER_ROLE();
        vm.expectEmit();
        emit IBaoRoles.RolesUpdated(minter, minterRole);
        IBaoRoles(leveragedToken).grantRoles(minter, minterRole);
        vm.expectEmit();
        emit IBaoRoles.RolesUpdated(minter, minterRole + burnerRole);
        IBaoRoles(leveragedToken).grantRoles(minter, burnerRole);
        IBaoOwnable(leveragedToken).transferOwnership(owner);
    }

    function setUp() public virtual {
        setUpFork();
        setUpContract();

        user1Wallet = vm.createWallet("user1");
        user1 = user1Wallet.addr;
        user2 = makeAddr("user2");
    }
}

contract TestLeveragedTokenInitEvents is TestLeveragedTokensSetUp {
    function test_initEventsImpl() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        setUp_impl();
    }

    function test_initEventsProxy() public {
        setUp_impl();
        vm.expectEmit();
        emit IERC1967.Upgraded(leveragedImpl);
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUp_proxy();
    }
}

contract TestLeveragedToken is TestLeveragedTokensSetUp {
    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MintableBurnableERC20_v1(leveragedToken).initialize(address(this), name, symbol);

        // check the data has been set up correctly
        assertEq(IERC20Metadata(leveragedToken).name(), name, "wrong name");
        assertEq(IERC20Metadata(leveragedToken).symbol(), symbol, "wrong symbol");
        assertEq(IERC20Metadata(leveragedToken).decimals(), 18, "wrong decimals");
        assertEq(IERC20(leveragedToken).totalSupply(), 0, "nothing minted yet");

        // admin role
        assertEq(IBaoOwnable(leveragedToken).owner(), owner, "owner should be admin");

        // minter role
        assertTrue(
            IBaoRoles(leveragedToken).hasAnyRole(minter, IMintableRole(leveragedToken).MINTER_ROLE()),
            "minter should be minter"
        );
        // minter role
        assertTrue(
            IBaoRoles(leveragedToken).hasAnyRole(minter, IBurnableRole(leveragedToken).BURNER_ROLE()),
            "minter should be burner"
        );
    }

    function test_access() public {
        // not anyone can grant roles
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(leveragedToken).grantRoles(minter, 23);
        // not anyone can transfer ownership
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(leveragedToken).transferOwnership(address(this));
    }

    function test_mintburn() public {
        // non-minter mint - minter
        vm.expectRevert(Unauthorized_selector);
        IMintable(leveragedToken).mint(address(this), 1 ether);
        assertEq(IERC20(leveragedToken).totalSupply(), 0, "nothing minted yet");
        vm.expectRevert(Unauthorized_selector);
        IBurnableFrom(leveragedToken).burnFrom(address(this), 1 ether);
        //------------------------------------------------------------

        // burn when none allowed
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, minter, 0, 2 ether));
        vm.prank(minter);
        IBurnableFrom(leveragedToken).burnFrom(address(this), 2 ether);
        //------------------------------------------------------------

        // burn when none
        IERC20(leveragedToken).approve(minter, 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 2 ether)
        );
        vm.prank(minter);
        IBurnableFrom(leveragedToken).burnFrom(address(this), 2 ether);
        //------------------------------------------------------------

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 0, 2 ether));
        vm.prank(minter);
        IBurnable(leveragedToken).burn(2 ether);
        //------------------------------------------------------------

        // mint
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), address(this), 2 ether);
        vm.prank(minter);
        IMintable(leveragedToken).mint(address(this), 2 ether);
        //------------------------------------------------------------
        assertEq(IERC20(leveragedToken).totalSupply(), 2 ether, "2 ether minted");
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 2 ether, "should have 2 ether");

        vm.prank(minter);
        IMintable(leveragedToken).mint(minter, 2 ether);
        //------------------------------------------------------------
        assertEq(IERC20(leveragedToken).totalSupply(), 4 ether, "4 ether minted");
        assertEq(IERC20(leveragedToken).balanceOf(minter), 2 ether, "should have 2 ether");

        // burn more than allowed
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, minter, 2 ether, 3 ether)
        );
        vm.prank(minter);
        IBurnableFrom(leveragedToken).burnFrom(address(this), 3 ether);
        //------------------------------------------------------------

        // burn too much
        IERC20(leveragedToken).approve(minter, 3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 2 ether, 3 ether)
        );
        vm.prank(minter);
        IBurnableFrom(leveragedToken).burnFrom(address(this), 3 ether);
        //------------------------------------------------------------

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 2 ether, 3 ether)
        );
        vm.prank(minter);
        IBurnable(leveragedToken).burn(3 ether);
        //------------------------------------------------------------

        // burn when some.
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(this), address(0), 1 ether);
        vm.prank(minter);
        IBurnableFrom(leveragedToken).burnFrom(address(this), 1 ether);
        //------------------------------------------------------------
        assertEq(IERC20(leveragedToken).totalSupply(), 3 ether, "3 ether left now");
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 1 ether, "should now have 1");
        vm.prank(minter);
        IBurnable(leveragedToken).burn(1 ether);
        //------------------------------------------------------------
        assertEq(IERC20(leveragedToken).totalSupply(), 2 ether, "2 ether left now");
        assertEq(IERC20(leveragedToken).balanceOf(minter), 1 ether, "should now have 1");
    }

    function test_transfer() public {
        // transfer when none
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 0, "start with none");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1 ether)
        );
        IERC20(leveragedToken).transfer(user1, 1 ether);

        // mint some to this
        vm.prank(minter);
        IMintable(leveragedToken).mint(address(this), 10 ether);
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 10 ether, "start with none");

        // transfer to user1
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 starts with none");
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(this), user1, 1 ether);
        IERC20(leveragedToken).transfer(user1, 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 9 ether, "moved 1");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 1 ether, "received 1");
    }

    function test_allowance() public {
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 starts with none");
        assertEq(IERC20(leveragedToken).balanceOf(user2), 0, "user1 starts with none");
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 0, "user1 starts with none");

        // try when no allowance
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        IERC20(leveragedToken).transferFrom(user1, user2, 1 ether);

        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user1, address(this), 1 ether);
        IERC20(leveragedToken).approve(address(this), 1 ether);
        assertEq(IERC20(leveragedToken).allowance(user1, address(this)), 1 ether, "should have allowance");

        // try when no balance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 0, 1 ether));
        IERC20(leveragedToken).transferFrom(user1, user2, 1 ether);

        // mint some to user1
        vm.prank(minter);
        IMintable(leveragedToken).mint(user1, 10 ether);
        assertEq(IERC20(leveragedToken).balanceOf(user1), 10 ether, "start with none");

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user1, user2, 1 ether);
        IERC20(leveragedToken).transferFrom(user1, user2, 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(user1), 9 ether, "moved 1");
        assertEq(IERC20(leveragedToken).balanceOf(user2), 1 ether, "received 1");

        // transfer with no allowance again
        assertEq(IERC20(leveragedToken).allowance(user1, address(this)), 0, "should have no allowance");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        IERC20(leveragedToken).transferFrom(user1, user2, 1 ether);

        vm.startPrank(user1);
        uint256 deadline = block.timestamp + 1000;
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                IERC20Permit(leveragedToken).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        user1,
                        address(this),
                        1 ether,
                        IERC20Permit(leveragedToken).nonces(user1),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Wallet.privateKey, digest);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user1, address(this), 1 ether);
        IERC20Permit(leveragedToken).permit(user1, address(this), 1 ether, deadline, v, r, s);
        vm.stopPrank();
        assertEq(IERC20(leveragedToken).allowance(user1, address(this)), 1 ether, "should have allowance");

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user1, user2, 1 ether);
        IERC20(leveragedToken).transferFrom(user1, user2, 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(user1), 8 ether, "moved another 1");
        assertEq(IERC20(leveragedToken).balanceOf(user2), 2 ether, "received another 1");
    }

    function test_introspection() public view {
        // TODO: check all the introspections
        assertTrue(IERC165(leveragedToken).supportsInterface(type(IERC20).interfaceId), "should support IERC20");
        assertTrue(
            IERC165(leveragedToken).supportsInterface(type(IERC20Metadata).interfaceId),
            "should support IERC20Metadata"
        );
        assertTrue(IERC165(leveragedToken).supportsInterface(type(IMintable).interfaceId), "should support IMinter");
        assertTrue(IERC165(leveragedToken).supportsInterface(type(IBurnable).interfaceId), "should support IBurnable");
        assertTrue(
            IERC165(leveragedToken).supportsInterface(type(IBurnableFrom).interfaceId),
            "should support IBurnableFrom"
        );
        assertFalse(IERC165(leveragedToken).supportsInterface(bytes4(0)), "doesn't support 0");
    }
}

contract TestUpgrade is TestLeveragedTokensSetUp {
    function test_authorizeUpgrade() public {
        // Deploy a new implementation
        address newImpl = address(new MintableBurnableERC20_v1());

        // Should revert if not owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        UUPSUpgradeable(leveragedToken).upgradeToAndCall(newImpl, "");

        // Should succeed if owner
        vm.prank(owner);
        UUPSUpgradeable(leveragedToken).upgradeToAndCall(newImpl, "");
    }
}

import {MintableBurnableERC20_v2_Reinit} from "./mocks/MintableBurnableERC20_v2_Reinit.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Tests for recovering from botched proxy deployments via upgrade
/// Pattern: Upgrade to v2 with reinitializer to fix initialization issues
/// @dev Note: BaoOwnable sets msg.sender as owner and the passed address as pendingOwner.
///      transferOwnership() must be called to complete transfer.
contract TestUpgradeRecovery is TestLeveragedTokensSetUp {
    string constant CORRECT_NAME = "Correct Name";
    string constant CORRECT_SYMBOL = "CORRECT";
    string constant WRONG_NAME = "Wrong Name";
    string constant WRONG_SYMBOL = "WRONG";

    /// @notice Test: Proxy deployed with stub (no initialize called) can be fixed via upgrade
    /// Scenario: Factory.deploy created proxy with stub implementation, but upgradeToAndCall failed
    function test_recoverFromUninitializedProxy() public {
        // Deploy v1 implementation
        address v1Impl = address(new MintableBurnableERC20_v1());

        // Deploy proxy WITHOUT calling initialize (simulates failed upgradeToAndCall)
        // Use a minimal ERC1967 proxy pointing to v1 impl
        address uninitializedProxy = address(
            new ERC1967Proxy(v1Impl, "") // empty data = no initialize call
        );

        // Verify proxy is in uninitialized state
        assertEq(IERC20Metadata(uninitializedProxy).name(), "", "name should be empty");
        assertEq(IERC20Metadata(uninitializedProxy).symbol(), "", "symbol should be empty");

        // Deploy v2 implementation with reinitializer capability
        address v2Impl = address(new MintableBurnableERC20_v2_Reinit());

        // Since no owner is set, anyone can initialize - this is the vulnerability
        // Initialize with wrong params to simulate a deployment mistake
        // Note: BaoOwnable sets msg.sender (this test contract) as owner, finalOwner as pending
        MintableBurnableERC20_v1(uninitializedProxy).initialize(owner, WRONG_NAME, WRONG_SYMBOL);

        // Now test contract is owner, owner is pending owner
        assertEq(IERC20Metadata(uninitializedProxy).name(), WRONG_NAME, "wrong name set");
        assertEq(IBaoOwnable(uninitializedProxy).owner(), address(this), "test contract is owner");

        // Test contract (as current owner) upgrades to v2 and calls reinitializeV2 to fix name/symbol
        UUPSUpgradeable(uninitializedProxy).upgradeToAndCall(
            v2Impl,
            abi.encodeCall(MintableBurnableERC20_v2_Reinit.reinitializeV2, (CORRECT_NAME, CORRECT_SYMBOL))
        );

        // Verify name/symbol are now correct
        assertEq(IERC20Metadata(uninitializedProxy).name(), CORRECT_NAME, "name should be fixed");
        assertEq(IERC20Metadata(uninitializedProxy).symbol(), CORRECT_SYMBOL, "symbol should be fixed");

        // Complete ownership transfer
        IBaoOwnable(uninitializedProxy).transferOwnership(owner);
        assertEq(IBaoOwnable(uninitializedProxy).owner(), owner, "owner should be transferred");
    }

    /// @notice Test: Proxy initialized with wrong params can be fixed via v2 reinitializer
    /// Scenario: initialize() was called with incorrect name/symbol during deployment
    function test_recoverFromWrongInitialization() public {
        // Deploy with wrong name/symbol (simulating deployment error)
        // Note: initialize sets msg.sender (test contract) as owner
        address v1Impl = address(new MintableBurnableERC20_v1());
        address wronglyInitializedProxy = address(
            new ERC1967Proxy(
                v1Impl,
                abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, WRONG_NAME, WRONG_SYMBOL))
            )
        );

        // Verify wrong initialization
        assertEq(IERC20Metadata(wronglyInitializedProxy).name(), WRONG_NAME, "wrong name");
        assertEq(IERC20Metadata(wronglyInitializedProxy).symbol(), WRONG_SYMBOL, "wrong symbol");
        // Test contract is owner (BaoOwnable pattern)
        assertEq(IBaoOwnable(wronglyInitializedProxy).owner(), address(this), "test is owner");

        // Mint some tokens to verify state is preserved after upgrade
        uint256 minterRole = IMintableRole(wronglyInitializedProxy).MINTER_ROLE();
        // Test contract is owner, so it can grant roles
        IBaoRoles(wronglyInitializedProxy).grantRoles(minter, minterRole);

        vm.prank(minter);
        IMintable(wronglyInitializedProxy).mint(user1, 100 ether);
        assertEq(IERC20(wronglyInitializedProxy).balanceOf(user1), 100 ether, "user1 should have tokens");

        // Upgrade to v2 and reinitialize with correct params (test contract is owner)
        address v2Impl = address(new MintableBurnableERC20_v2_Reinit());
        UUPSUpgradeable(wronglyInitializedProxy).upgradeToAndCall(
            v2Impl,
            abi.encodeCall(MintableBurnableERC20_v2_Reinit.reinitializeV2, (CORRECT_NAME, CORRECT_SYMBOL))
        );

        // Verify fix
        assertEq(IERC20Metadata(wronglyInitializedProxy).name(), CORRECT_NAME, "name fixed");
        assertEq(IERC20Metadata(wronglyInitializedProxy).symbol(), CORRECT_SYMBOL, "symbol fixed");

        // Verify state preserved
        assertEq(IERC20(wronglyInitializedProxy).balanceOf(user1), 100 ether, "balance preserved");
        assertTrue(IBaoRoles(wronglyInitializedProxy).hasAnyRole(minter, minterRole), "minter role preserved");

        // Complete ownership transfer and verify
        IBaoOwnable(wronglyInitializedProxy).transferOwnership(owner);
        assertEq(IBaoOwnable(wronglyInitializedProxy).owner(), owner, "owner transferred");

        // Verify minting still works after ownership transfer
        vm.prank(minter);
        IMintable(wronglyInitializedProxy).mint(user2, 50 ether);
        assertEq(IERC20(wronglyInitializedProxy).balanceOf(user2), 50 ether, "can still mint");
    }

    /// @notice Test: Cannot reinitialize with same version
    function test_cannotReinitializeTwice() public {
        // Deploy and initialize normally
        address v2Impl = address(new MintableBurnableERC20_v2_Reinit());
        address proxy = address(
            new ERC1967Proxy(
                v2Impl,
                abi.encodeCall(MintableBurnableERC20_v2_Reinit.initialize, (owner, CORRECT_NAME, CORRECT_SYMBOL))
            )
        );

        // Try to reinitialize with v1 - should fail (already at version 1)
        // Note: test contract is owner (BaoOwnable pattern)
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MintableBurnableERC20_v2_Reinit(proxy).reinitializeV1(owner, "New Name", "NEW");

        // Can still reinitialize to v2 (test contract is owner)
        MintableBurnableERC20_v2_Reinit(proxy).reinitializeV2("Updated Name", "UPD");
        assertEq(IERC20Metadata(proxy).name(), "Updated Name", "v2 reinit works");

        // Cannot reinitialize v2 again
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MintableBurnableERC20_v2_Reinit(proxy).reinitializeV2("Another Name", "ANO");
    }

    /// @notice Test: Only owner can perform upgrade
    function test_onlyOwnerCanUpgradeToFix() public {
        // Deploy with wrong params - test contract becomes owner
        address v1Impl = address(new MintableBurnableERC20_v1());
        address proxy = address(
            new ERC1967Proxy(
                v1Impl,
                abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, WRONG_NAME, WRONG_SYMBOL))
            )
        );

        // Verify test contract is the current owner
        assertEq(IBaoOwnable(proxy).owner(), address(this), "test is owner");

        address v2Impl = address(new MintableBurnableERC20_v2_Reinit());

        // Non-owner cannot upgrade
        vm.prank(user1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        UUPSUpgradeable(proxy).upgradeToAndCall(
            v2Impl,
            abi.encodeCall(MintableBurnableERC20_v2_Reinit.reinitializeV2, (CORRECT_NAME, CORRECT_SYMBOL))
        );

        // Test contract (as owner) can upgrade
        UUPSUpgradeable(proxy).upgradeToAndCall(
            v2Impl,
            abi.encodeCall(MintableBurnableERC20_v2_Reinit.reinitializeV2, (CORRECT_NAME, CORRECT_SYMBOL))
        );

        assertEq(IERC20Metadata(proxy).name(), CORRECT_NAME, "owner upgrade succeeded");

        // Complete ownership transfer
        IBaoOwnable(proxy).transferOwnership(owner);
        assertEq(IBaoOwnable(proxy).owner(), owner, "ownership transferred");
    }
}

contract TestPermit is TestLeveragedTokensSetUp {
    function test_permitBasic() public {
        // Mint some tokens to user1
        vm.prank(minter);
        IMintable(leveragedToken).mint(user1, 10 ether);

        // Check initial nonce
        uint256 initialNonce = IERC20Permit(leveragedToken).nonces(user1);
        assertEq(initialNonce, 0, "Initial nonce should be 0");

        // Get domain separator
        bytes32 domainSeparator = IERC20Permit(leveragedToken).DOMAIN_SEPARATOR();
        assertFalse(domainSeparator == bytes32(0), "Domain separator should not be zero");

        // Create permit signature
        uint256 deadline = block.timestamp + 1000;
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash = keccak256(
            abi.encode(permitTypehash, user1, address(this), 1 ether, initialNonce, deadline)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Wallet.privateKey, digest);

        // Execute permit
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user1, address(this), 1 ether);
        IERC20Permit(leveragedToken).permit(user1, address(this), 1 ether, deadline, v, r, s);

        // Verify allowance was set
        assertEq(IERC20(leveragedToken).allowance(user1, address(this)), 1 ether, "Allowance not set correctly");

        // Verify nonce was incremented
        assertEq(IERC20Permit(leveragedToken).nonces(user1), initialNonce + 1, "Nonce not incremented");

        // Test with expired deadline
        uint256 expiredDeadline = block.timestamp - 1;
        bytes32 expiredStructHash = keccak256(
            abi.encode(
                permitTypehash,
                user1,
                address(this),
                1 ether,
                initialNonce + 1, // Updated nonce
                expiredDeadline
            )
        );

        bytes32 expiredDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, expiredStructHash));

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(user1Wallet.privateKey, expiredDigest);

        // Should revert with expired deadline
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, 0));
        IERC20Permit(leveragedToken).permit(user1, address(this), 1 ether, expiredDeadline, v2, r2, s2);
    }

    function test_permitInvalidSignature() public {
        // Mint some tokens to user1
        vm.prank(minter);
        IMintable(leveragedToken).mint(user1, 10 ether);

        uint256 deadline = block.timestamp + 1000;
        bytes32 domainSeparator = IERC20Permit(leveragedToken).DOMAIN_SEPARATOR();
        uint256 nonce = IERC20Permit(leveragedToken).nonces(user1);

        // Create digest for a different user (user2 wallet)
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user1, // owner is still user1
                address(this),
                1 ether,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with user2's wallet instead of user1
        Vm.Wallet memory user2Wallet = vm.createWallet("user2_alt");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2Wallet.privateKey, digest);

        // Should revert with invalid signature
        vm.expectRevert(
            abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, user2Wallet.addr, user1)
        );
        IERC20Permit(leveragedToken).permit(user1, address(this), 1 ether, deadline, v, r, s);
    }
}

contract TestMaxAllowance is TestLeveragedTokensSetUp {
    function test_maxAllowance() public {
        // Mint tokens to user1
        vm.prank(minter);
        IMintable(leveragedToken).mint(user1, 10 ether);

        // Set maximum allowance
        vm.prank(user1);
        IERC20(leveragedToken).approve(address(this), type(uint256).max);

        // Verify max allowance
        assertEq(
            IERC20(leveragedToken).allowance(user1, address(this)),
            type(uint256).max,
            "Max allowance not set correctly"
        );

        // Transfer once
        IERC20(leveragedToken).transferFrom(user1, user2, 1 ether);

        // Check allowance remains max
        assertEq(
            IERC20(leveragedToken).allowance(user1, address(this)),
            type(uint256).max,
            "Max allowance should not decrease"
        );

        // Transfer again
        IERC20(leveragedToken).transferFrom(user1, user2, 2 ether);

        // Balances should be updated
        assertEq(IERC20(leveragedToken).balanceOf(user1), 7 ether, "user1 balance incorrect");
        assertEq(IERC20(leveragedToken).balanceOf(user2), 3 ether, "user2 balance incorrect");
    }
}
