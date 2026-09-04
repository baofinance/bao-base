// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title PermitTestBase
/// @notice Reusable EIP-2612 permit test suite. Override `_permitTarget` (required)
///         and `_permitVersion` (defaults to `"1"`); inherit five standard permit tests.
abstract contract PermitTestBase is Test {
    function _permitTarget() internal view virtual returns (address);

    function _permitVersion() internal view virtual returns (string memory) {
        return "1";
    }

    function _permitDigest(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", IERC20Permit(_permitTarget()).DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev Sign and submit a permit — helper for subclass tests that need an approval
    ///      in place before asserting other behaviour.
    function _grantPermit(address signer, uint256 signerPk, address spender, uint256 value) internal {
        address target = _permitTarget();
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(target).nonces(signer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, _permitDigest(signer, spender, value, nonce, deadline));
        IERC20Permit(target).permit(signer, spender, value, deadline, v, r, s);
    }

    /// @notice Happy path: valid permit signature sets allowance and advances the nonce.
    function test_permit_happyPath() public virtual {
        address target = _permitTarget();
        (address signer, uint256 pk) = makeAddrAndKey("permit.signer");
        address spender = makeAddr("permit.spender");
        uint256 value = 42 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonceBefore = IERC20Permit(target).nonces(signer);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(signer, spender, value, nonceBefore, deadline));

        IERC20Permit(target).permit(signer, spender, value, deadline, v, r, s);

        assertEq(IERC20(target).allowance(signer, spender), value, "allowance set");
        assertEq(IERC20Permit(target).nonces(signer), nonceBefore + 1, "nonce incremented");
    }

    /// @notice A permit with a deadline in the past reverts.
    function test_permit_expiredDeadline_reverts() public virtual {
        address target = _permitTarget();
        (address signer, uint256 pk) = makeAddrAndKey("permit.signer");
        address spender = makeAddr("permit.spender");

        // Ensure block.timestamp is past genesis so `- 1` is well-defined.
        if (block.timestamp == 0) {
            vm.warp(1);
        }
        uint256 deadline = block.timestamp - 1;
        uint256 nonce = IERC20Permit(target).nonces(signer);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(signer, spender, 1 ether, nonce, deadline));

        vm.expectRevert();
        IERC20Permit(target).permit(signer, spender, 1 ether, deadline, v, r, s);
    }

    /// @notice A signature from an address other than `owner` reverts.
    function test_permit_wrongSigner_reverts() public virtual {
        address target = _permitTarget();
        (address signer, ) = makeAddrAndKey("permit.signer");
        (, uint256 attackerPk) = makeAddrAndKey("permit.attacker");
        address spender = makeAddr("permit.spender");
        uint256 value = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(target).nonces(signer);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, _permitDigest(signer, spender, value, nonce, deadline));

        vm.expectRevert();
        IERC20Permit(target).permit(signer, spender, value, deadline, v, r, s);
    }

    /// @notice A previously-used signature cannot be replayed — the nonce has advanced.
    function test_permit_replay_reverts() public virtual {
        address target = _permitTarget();
        (address signer, uint256 pk) = makeAddrAndKey("permit.signer");
        address spender = makeAddr("permit.spender");
        uint256 value = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(target).nonces(signer);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(signer, spender, value, nonce, deadline));

        IERC20Permit(target).permit(signer, spender, value, deadline, v, r, s);

        vm.expectRevert();
        IERC20Permit(target).permit(signer, spender, value, deadline, v, r, s);
    }

    /// @notice `DOMAIN_SEPARATOR` matches the canonical EIP-712 layout: hash of the
    ///         domain typehash, name hash, version hash, chainid, and verifying
    ///         contract (the target address). Catches any regression in
    ///         name/version/chainid/address binding.
    function test_permit_domainSeparatorFormat() public view virtual {
        address target = _permitTarget();
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(IERC20Metadata(target).name())),
                keccak256(bytes(_permitVersion())),
                block.chainid,
                target
            )
        );
        assertEq(IERC20Permit(target).DOMAIN_SEPARATOR(), expected, "domain separator matches EIP-712 layout");
    }
}
