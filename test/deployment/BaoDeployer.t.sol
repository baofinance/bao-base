// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {FundedVault, NonPayableVault, FundedVaultUUPS} from "@bao-test/mocks/deployment/FundedVault.sol";

contract SimpleContract {
    uint256 public value;
    address public deployer;

    constructor(uint256 _value) {
        value = _value;
        deployer = msg.sender;
    }
}

contract BaoDeployerTest is Test {
    BaoDeployer internal deployer;
    address internal owner;
    address internal operator;
    address internal outsider;

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        outsider = makeAddr("outsider");

        deployer = new BaoDeployer(owner);
        deployer.setOperator(operator);
    }

    function _commit(bytes memory initCode, bytes32 salt, uint256 value) internal returns (bytes32 commitment) {
        commitment = deployer.computeCommitment(operator, value, salt, keccak256(initCode));
        vm.prank(operator);
        deployer.commit(commitment);
    }

    function _reveal(bytes memory initCode, bytes32 salt, uint256 value) internal returns (address deployedAddr) {
        vm.deal(operator, value);
        vm.prank(operator);
        deployedAddr = deployer.reveal{value: value}(initCode, salt, value);
    }

    function testConstructorSetsOwner() public view {
        assertEq(deployer.owner(), owner);
    }

    function testSetOperatorOnlyOwner() public {
        address newOperator = makeAddr("new operator");
        vm.expectEmit(true, true, false, false);
        emit BaoDeployer.OperatorUpdated(operator, newOperator);
        deployer.setOperator(newOperator);
        assertEq(deployer.operator(), newOperator);

        vm.prank(outsider);
        vm.expectRevert();
        deployer.setOperator(makeAddr("forbidden"));
    }

    function testCommitRevealDeploysContract() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(42)));
        bytes32 salt = keccak256("commit.reveal.zero");
        bytes32 commitment = _commit(initCode, salt, 0);
        address predicted = deployer.predictDeterministicAddress(salt);

        address deployedAddr = _reveal(initCode, salt, 0);

        assertEq(deployedAddr, predicted);
        assertFalse(deployer.isCommitted(commitment));

        SimpleContract simple = SimpleContract(deployedAddr);
        assertEq(simple.value(), 42);
        assertTrue(simple.deployer() != address(deployer));
    }

    function testCommitRevealWithValue() public {
        uint256 value = 5 ether;
        bytes memory initCode = type(FundedVault).creationCode;
        bytes32 salt = keccak256("commit.reveal.value");
        bytes32 commitment = _commit(initCode, salt, value);
        address predicted = deployer.predictDeterministicAddress(salt);

        address deployedAddr = _reveal(initCode, salt, value);

        assertEq(deployedAddr, predicted);
        assertFalse(deployer.isCommitted(commitment));

        FundedVault vault = FundedVault(payable(deployedAddr));
        assertEq(vault.initialBalance(), value);
        assertEq(vault.currentBalance(), value);
    }

    function testCommitTwiceReverts() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(1)));
        bytes32 salt = keccak256("double.commit");
        bytes32 commitment = _commit(initCode, salt, 0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.CommitmentAlreadyExists.selector, commitment));
        deployer.commit(commitment);
    }

    function testRevealWithWrongSaltReverts() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(7)));
        bytes32 salt = keccak256("good.salt");
        bytes32 badSalt = keccak256("bad.salt");
        _commit(initCode, salt, 0);

        bytes32 expected = deployer.computeCommitment(operator, 0, badSalt, keccak256(initCode));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.UnknownCommitment.selector, expected));
        deployer.reveal(initCode, badSalt, 0);
    }

    function testRevealWithoutCommitReverts() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(9)));
        bytes32 salt = keccak256("no.commit");
        bytes32 expected = deployer.computeCommitment(operator, 0, salt, keccak256(initCode));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.UnknownCommitment.selector, expected));
        deployer.reveal(initCode, salt, 0);
    }

    function testClearCommitment() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(3)));
        bytes32 salt = keccak256("clear.commitment");
        bytes32 commitment = _commit(initCode, salt, 0);
        assertTrue(deployer.isCommitted(commitment));

        deployer.clearCommitment(commitment);
        assertFalse(deployer.isCommitted(commitment));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.UnknownCommitment.selector, commitment));
        deployer.reveal(initCode, salt, 0);
    }

    function testOperatorUnsetReverts() public {
        deployer.setOperator(address(0));
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(5)));
        bytes32 salt = keccak256("operator.unset");
        bytes32 commitment = deployer.computeCommitment(address(0), 0, salt, keccak256(initCode));

        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.OperatorRequired.selector));
        vm.prank(address(0));
        deployer.commit(commitment);
    }

    function testUnauthorizedCallerCannotCommit() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(11)));
        bytes32 salt = keccak256("unauthorized");
        bytes32 commitment = deployer.computeCommitment(operator, 0, salt, keccak256(initCode));

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.UnauthorizedOperator.selector, outsider));
        deployer.commit(commitment);
    }

    function testRevealValueMismatchReverts() public {
        uint256 value = 1 ether;
        bytes memory initCode = type(FundedVault).creationCode;
        bytes32 salt = keccak256("value.mismatch");
        bytes32 commitment = _commit(initCode, salt, value);
        assertTrue(deployer.isCommitted(commitment));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.ValueMismatch.selector, value, uint256(0)));
        deployer.reveal(initCode, salt, value);
    }

    function testOwnerDirectDeployMatchesCommitReveal() public {
        bytes memory initCode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(55)));

        bytes32 saltCommit = keccak256("flow.commit");
        _commit(initCode, saltCommit, 0);
        address commitAddr = _reveal(initCode, saltCommit, 0);
        SimpleContract viaCommit = SimpleContract(commitAddr);
        assertEq(viaCommit.value(), 55);

        bytes32 saltOwner = keccak256("flow.owner");
        address predicted = deployer.predictDeterministicAddress(saltOwner);
        address ownerAddr = deployer.deployDeterministic(initCode, saltOwner);
        assertEq(ownerAddr, predicted);

        SimpleContract viaOwner = SimpleContract(ownerAddr);
        assertEq(viaOwner.value(), 55);
        assertEq(keccak256(commitAddr.code), keccak256(ownerAddr.code));
    }

    function testCommitRevealSupportsProxyPayload() public {
        FundedVaultUUPS implementation = new FundedVaultUUPS(owner);
        bytes memory initData = abi.encodeCall(FundedVaultUUPS.initialize, ());
        bytes memory proxyInit = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(implementation), initData)
        );
        bytes32 salt = keccak256("uups.proxy");
        _commit(proxyInit, salt, 0);

        address deployedAddr = _reveal(proxyInit, salt, 0);
        FundedVaultUUPS proxy = FundedVaultUUPS(payable(deployedAddr));
        assertTrue(address(proxy) != address(0));
        assertEq(proxy.owner(), owner);
    }

    function testCommitRevealNonPayableTargetReverts() public {
        uint256 value = 1 ether;
        bytes memory initCode = abi.encodePacked(type(NonPayableVault).creationCode, abi.encode(uint256(1)));
        bytes32 salt = keccak256("nonpayable");
        _commit(initCode, salt, value);

        vm.deal(operator, value);
        vm.prank(operator);
        vm.expectRevert();
        deployer.reveal{value: value}(initCode, salt, value);
    }
}
