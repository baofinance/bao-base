// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
    using SafeERC20 for IERC20;

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
        SafeERC20.safeTransfer(IERC20(leveragedToken), user1, 1 ether);

        // mint some to this
        vm.prank(minter);
        IMintable(leveragedToken).mint(address(this), 10 ether);
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 10 ether, "start with none");

        // transfer to user1
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 starts with none");
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(this), user1, 1 ether);
        SafeERC20.safeTransfer(IERC20(leveragedToken), user1, 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 9 ether, "moved 1");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 1 ether, "received 1");
    }

    function test_allowance() public {
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 starts with none");
        assertEq(IERC20(leveragedToken).balanceOf(user2), 0, "user1 starts with none");
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 0, "user1 starts with none");

        // try when no no allowance
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        SafeERC20.safeTransferFrom(IERC20(leveragedToken), user1, user2, 1 ether);

        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user1, address(this), 1 ether);
        IERC20(leveragedToken).approve(address(this), 1 ether);
        assertEq(IERC20(leveragedToken).allowance(user1, address(this)), 1 ether, "should have allowance");

        // try when no no balance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 0, 1 ether));
        SafeERC20.safeTransferFrom(IERC20(leveragedToken), user1, user2, 1 ether);

        // mint some to user1
        vm.prank(minter);
        IMintable(leveragedToken).mint(user1, 10 ether);
        assertEq(IERC20(leveragedToken).balanceOf(user1), 10 ether, "start with none");

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user1, user2, 1 ether);
        SafeERC20.safeTransferFrom(IERC20(leveragedToken), user1, user2, 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(user1), 9 ether, "moved 1");
        assertEq(IERC20(leveragedToken).balanceOf(user2), 1 ether, "received 1");

        // transfer with no allowance again
        assertEq(IERC20(leveragedToken).allowance(user1, address(this)), 0, "should have no allowance");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        SafeERC20.safeTransferFrom(IERC20(leveragedToken), user1, user2, 1 ether);

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
        SafeERC20.safeTransferFrom(IERC20(leveragedToken), user1, user2, 1 ether);
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
        SafeERC20.safeTransferFrom(IERC20(leveragedToken), user1, user2, 1 ether);

        // Check allowance remains max
        assertEq(
            IERC20(leveragedToken).allowance(user1, address(this)),
            type(uint256).max,
            "Max allowance should not decrease"
        );

        // Transfer again
        SafeERC20.safeTransferFrom(IERC20(leveragedToken), user1, user2, 2 ether);

        // Balances should be updated
        assertEq(IERC20(leveragedToken).balanceOf(user1), 7 ether, "user1 balance incorrect");
        assertEq(IERC20(leveragedToken).balanceOf(user2), 3 ether, "user2 balance incorrect");
    }
}
