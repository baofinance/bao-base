// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {ERC20WithData} from "test/mocks/deployment/ERC20WithData.sol";

/**
 * @title DeployTestHarness
 * @notice Deployment harness for ERC20WithData
 * @dev Extends DeploymentJson for JSON persistence (production paths)
 */
contract DeployTestHarness is DeploymentJson {
    string public constant TOKEN = "contracts.token";
    string public constant NAME = "contracts.token.name";
    string public constant SYMBOL = "contracts.token.symbol";
    string public constant STORAGE_UINT = "contracts.token.storageUint";
    string public constant STORAGE_UINT_ARRAY = "contracts.token.storageUintArray";

    constructor() {
        addStringKey(NAME);
        addStringKey(SYMBOL);
        addProxy(TOKEN);
        addUintArrayKey(STORAGE_UINT_ARRAY);
        addUintKey(STORAGE_UINT);
    }

    /// @notice Deploy ERC20WithData as a proxy
    /// @param key Contract key (e.g., "contracts.token")
    function deployERC20WithData(string memory key) public {
        // Deploy implementation with constructor arg
        ERC20WithData impl = new ERC20WithData(address(0));

        address owner = _getAddress(OWNER);
        string memory name = _getString(NAME);
        string memory symbol = _getString(SYMBOL);
        uint256 aUint = _getUint(STORAGE_UINT);

        // Encode initializer call
        bytes memory initData = abi.encodeCall(ERC20WithData.initialize, (owner, name, symbol, aUint));

        // Deploy proxy via CREATE3
        this.deployProxy(
            key,
            address(impl),
            initData,
            "ERC20WithData",
            "test/mocks/deployment/ERC20WithData.sol",

        );
    }
}

/**
 * @title DeployTest
 * @notice Script to deploy ERC20WithData using DeploymentJson (production)
 * @dev Run with: script/deploy-test
 *
 * This demonstrates using the deployment harness in a script context.
 * Output JSON is written to deployments/<salt>/<network>/
 *
 * Uses real multisig address as BaoDeployer owner.
 * On anvil with --auto-impersonate, we can broadcast from any address.
 * On mainnet, multisig would sign these transactions.
 */
contract DeployTest is Script {
    // Anvil default account (used as deployment operator)
    uint256 constant ANVIL_ACCOUNT_0_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    DeployTestHarness public deployment;

    function run() public {
        string memory network = "anvil";
        string memory salt = "DeployTest";

        // ========================================
        // Phase 1: Infrastructure Setup
        // ========================================

        // Check Nick's Factory exists
        require(
            DeploymentInfrastructure._NICKS_FACTORY.code.length > 0,
            "Nick's Factory not deployed. Start anvil with: anvil"
        );
        console.log("Nick's Factory found at:", DeploymentInfrastructure._NICKS_FACTORY);

        address baoDeployerAddr = DeploymentInfrastructure.predictBaoDeployerAddress();

        // Deploy BaoDeployer if missing (broadcast from multisig - works on anvil with --unlocked)
        if (baoDeployerAddr.code.length == 0) {
            console.log("Deploying BaoDeployer (as multisig)...");
            vm.startBroadcast(ANVIL_ACCOUNT_0_PK);
            DeploymentInfrastructure.ensureBaoDeployer();
            vm.stopBroadcast();
            console.log("BaoDeployer deployed at:", baoDeployerAddr);
        } else {
            console.log("BaoDeployer already exists at:", baoDeployerAddr);
        }

        // Create harness (will be the operator)
        deployment = new DeployTestHarness();
        console.log("Deployment harness created at:", address(deployment));

        // Set operator to the harness (as multisig, which is BaoDeployer owner)
        BaoDeployer baoDeployer = BaoDeployer(baoDeployerAddr);
        if (baoDeployer.operator() != address(deployment)) {
            console.log("Setting BaoDeployer operator to harness (as multisig)...");
            vm.startBroadcast(DeploymentInfrastructure.BAOMULTISIG);
            baoDeployer.setOperator(address(deployment));
            vm.stopBroadcast();
            console.log("Operator set to:", address(deployment));
        }

        // ========================================
        // Phase 2: Deployment (as account 1)
        // ========================================

        console.log("Starting deployment on network:", network);

        // Start deployment session
        deployment.start(network, salt, "");

        // Deploy the token (as anvil account 0 - the deployment operator)
        vm.startBroadcast(ANVIL_ACCOUNT_0_PK);
        deployment.deployERC20WithData(deployment.TOKEN());
        vm.stopBroadcast();

        // Get deployed address
        address tokenAddr = deployment.get(deployment.TOKEN());
        console.log("Deployed ERC20WithData proxy at:", tokenAddr);

        // Finish and save
        deployment.finish();
        console.log("Deployment complete");
    }
}
