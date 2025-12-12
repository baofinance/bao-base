// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentMemoryTesting} from "@bao-script/deployment/DeploymentMemoryTesting.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Test harness using production bytecode for stable addresses under coverage
contract DeploymentTestingHarness is DeploymentMemoryTesting {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function startSession(string memory network, string memory salt) external {
        start(network, salt, "");
    }

    function readContractAddress(string memory key) external view returns (address) {
        return _get(key);
    }

    /// @dev Use production bytecode for stable addresses (works with coverage instrumentation)
    function _ensureBaoFactory() internal override returns (address baoFactory) {
        baoFactory = DeploymentInfrastructure._ensureBaoFactoryProduction();
        // Always reset operator to this harness
        if (!IBaoFactory(baoFactory).isCurrentOperator(address(this))) {
            VM.prank(BaoFactory(baoFactory).owner());
            IBaoFactory(baoFactory).setOperator(address(this), 365 days);
        }
    }
}

contract DeploymentTestingTest is BaoDeploymentTest {
    DeploymentTestingHarness public deployment;

    function setUp() public override {
        super.setUp();
        deployment = new DeploymentTestingHarness();
    }

    function test_StartConfiguresBaoFactoryOperator_() public {
        deployment.startSession("net-operator", "salt-operator");
        address factory = DeploymentInfrastructure.predictBaoFactoryAddress();
        assertTrue(
            BaoFactory(factory).isCurrentOperator(address(deployment)),
            "BaoFactory operator configured for test harness"
        );
    }

    function test_SetContractAddressStoresValue_() public {
        deployment.addContract("contracts.fixture");
        deployment.startSession("net-fixture", "salt-fixture");
        address stored = address(0xFEE);
        deployment.set("contracts.fixture", stored);
        assertEq(deployment.readContractAddress("contracts.fixture"), stored, "setAddress wires value");
    }

    function test_SimulatePredictableDeployWithoutFundingRevertsValueMismatch_() public {
        deployment.addContract("contracts.predictable");
        deployment.startSession("net-predictable", "salt-predictable");
        bytes memory initCode = hex"6000600055"; // minimal init code
        vm.expectRevert(abi.encodeWithSelector(IBaoFactory.ValueMismatch.selector, 1 ether, 0));
        deployment.simulatePredictableDeployWithoutFunding(1 ether, "contracts.predictable", initCode, "", "");
    }

    function test_SimulatePredictableDeployWithZeroValueSucceeds_() public {
        deployment.addContract("contracts.zerovalue");
        deployment.startSession("net-zerovalue", "salt-zerovalue");
        // Init code that deploys a contract returning a single STOP opcode (0x00)
        // PUSH1 0x01, PUSH1 0x00, PUSH1 0x00, CODECOPY, PUSH1 0x01, PUSH1 0x00, RETURN, STOP
        // This copies 1 byte from offset 0 and returns it as runtime code
        // Actually simpler: runtime code = 0x00 (STOP), init returns it
        // PUSH1 1, PUSH1 7, PUSH1 0, CODECOPY, PUSH1 1, PUSH1 0, RETURN, STOP
        // 60 01 60 07 60 00 39 60 01 60 00 f3 00
        bytes memory initCode = hex"6001600760003960016000f300";

        // With value=0, ForceZeroValue mode matches, so deployment succeeds
        address deployed = deployment.simulatePredictableDeployWithoutFunding(
            0,
            "contracts.zerovalue",
            initCode,
            "TestContract",
            "test/TestContract.sol"
        );

        // Verify deterministic address was returned and contract has code
        assertNotEq(deployed, address(0), "Should return deployed address");
        assertGt(deployed.code.length, 0, "Deployed contract should have code");
    }
}
