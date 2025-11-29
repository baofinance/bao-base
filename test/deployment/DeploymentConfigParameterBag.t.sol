// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {DeploymentMemoryTesting} from "@bao-script/deployment/DeploymentMemoryTesting.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";

contract DeploymentConfigParameterBagTestHarness is DeploymentMemoryTesting {
    constructor() {
        // Register all keys that will be used in the test
        // Register parent keys first
        addContract("pegged");
        addContract("collateral");
        addContract("minter");
        addContract("minter.bands");
        addContract("minter.ratios");

        // Then register nested keys
        addStringKey("pegged.name");
        addStringKey("pegged.symbol");
        addUintKey("pegged.decimals");
        addContract("collateral"); // collateral is actually a contract key
        addUintKey("minter.bands.0");
        addUintKey("minter.bands.1");
        addIntKey("minter.ratios.0");
        addUintKey("minter.ratios.1");
    }

    function populateTestData() external {
        // Populate test data after start() is called
        setString("pegged.name", "Bao USD");
        setString("pegged.symbol", "BAOUSD");
        setUint("pegged.decimals", 18);
        set("collateral", 0x0000000000000000000000000000000000000002);
        setUint("minter.bands.0", 100);
        setUint("minter.bands.1", 200);
        setInt("minter.ratios.0", -1);
        setUint("minter.ratios.1", 2);
    }
}

contract DeploymentConfigParameterBagTest is BaoDeploymentTest {
    DeploymentConfigParameterBagTestHarness internal deployment;
    string constant OWNER_ADDRESS = "0x0000000000000000000000000000000000000001";
    string constant COLLATERAL_ADDRESS = "0x0000000000000000000000000000000000000002";

    function setUp() public override {
        super.setUp();
        deployment = new DeploymentConfigParameterBagTestHarness();
    }

    function test_FlattensNestedConfigIntoParameters() public {
        deployment.start("testnet", "test-salt", "");
        deployment.populateTestData();

        assertEq(deployment.getString("pegged.name"), "Bao USD");
        assertEq(deployment.getString("pegged.symbol"), "BAOUSD");
        assertEq(deployment.getUint("pegged.decimals"), 18);

        assertEq(deployment.getString("collateral.address"), COLLATERAL_ADDRESS);

        assertEq(deployment.getUint("minter.bands.0"), 100);
        assertEq(deployment.getUint("minter.bands.1"), 200);
        assertEq(deployment.getInt("minter.ratios.0"), -1);
        assertEq(deployment.getUint("minter.ratios.1"), 2);

        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "owner"));
        deployment.getString("owner");
    }

    function _buildConfigJson() internal pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "{",
                    '"owner":"',
                    OWNER_ADDRESS,
                    '",',
                    '"version":"1.0.0",',
                    '"systemSaltString":"bag-demo",',
                    '"pegged":{"name":"Bao USD","symbol":"BAOUSD","decimals":18},',
                    '"collateral":{"address":"',
                    COLLATERAL_ADDRESS,
                    '"},',
                    '"minter":{"bands":[100,200],"ratios":[-1,2]},',
                    '"conflicts":{"owner":"prefer-config"}',
                    "}"
                )
            );
    }
}
