// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";

contract DeploymentTestingHarness is DeploymentTesting {
    function startSession(string memory network, string memory salt) external {
        start(network, salt, "");
    }

    function readContractAddress(string memory key) external view returns (address) {
        return _get(key);
    }
}

contract DeploymentTestingTest is BaoDeploymentTest {
    DeploymentTestingHarness public deployment;

    function setUp() public override {
        super.setUp();
        deployment = new DeploymentTestingHarness();
    }

    function test_StartConfiguresBaoDeployerOperator_() public {
        deployment.startSession("net-operator", "salt-operator");
        address factory = DeploymentInfrastructure.predictBaoDeployerAddress();
        assertEq(BaoDeployer(factory).operator(), address(deployment), "BaoDeployer operator updated to test harness");
    }

    function test_SetContractAddressStoresValue_() public {
        deployment.addContract("contracts.fixture");
        deployment.startSession("net-fixture", "salt-fixture");
        address stored = address(0xFEE);
        deployment.setContractAddress("contracts.fixture", stored);
        assertEq(deployment.readContractAddress("contracts.fixture"), stored, "setContractAddress wires value");
    }

    function test_SimulatePredictableDeployWithoutFundingRevertsValueMismatch_() public {
        deployment.addContract("contracts.predictable");
        deployment.startSession("net-predictable", "salt-predictable");
        bytes memory initCode = hex"6000600055"; // minimal init code
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.ValueMismatch.selector, 1 ether, 0));
        deployment.simulatePredictableDeployWithoutFunding(1 ether, "contracts.predictable", initCode, "", "");
    }
}
