// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {DeploymentJsonScript} from "@bao-script/deployment/DeploymentJsonScript.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {ERC20WithData} from "test/mocks/deployment/ERC20WithData.sol";

/**
 * @title DeployTest
 * @notice Deployment script for ERC20WithData
 * @dev Run with: script/deploy-test
 *
 * Demonstrates using DeploymentJsonScript for production deployments.
 * Output JSON is written to deployments/<salt>/<network>/
 *
 * Infrastructure setup (BaoDeployer) is explicit in run().
 * On anvil with --auto-impersonate, we can broadcast as multisig.
 * On mainnet, multisig would sign the setOperator transaction.
 */
contract DeployTest is DeploymentJsonScript {
    // ============================================================================
    // Deployment Keys
    // ============================================================================

    string public constant TOKEN = "contracts.token";
    string public constant NAME = "contracts.token.name";
    string public constant SYMBOL = "contracts.token.symbol";
    string public constant STORAGE_UINT = "contracts.token.storageUint";
    string public constant STORAGE_UINT_ARRAY = "contracts.token.storageUintArray";

    // Anvil default accounts - account 0 is the deployer/operator
    uint256 constant PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // ============================================================================
    // Constructor - Schema Registration
    // ============================================================================

    constructor() {
        addStringKey(NAME);
        addStringKey(SYMBOL);
        addProxy(TOKEN);
        addUintArrayKey(STORAGE_UINT_ARRAY);
        addUintKey(STORAGE_UINT);
    }

    // ============================================================================
    // Main Entry Point
    // ============================================================================

    function run() public {
        string memory network = "anvil";
        string memory salt = "DeployTest";

        // ========================================
        // Phase 1: Verify Infrastructure
        // ========================================

        // // Check Nick's Factory exists
        // require(
        //     DeploymentInfrastructure._NICKS_FACTORY.code.length > 0,
        //     "Nick's Factory not deployed. Start anvil with: anvil"
        // );
        // console.log("Nick's Factory found at:", DeploymentInfrastructure._NICKS_FACTORY);

        // address baoDeployerAddr = DeploymentInfrastructure.predictBaoDeployerAddress();
        // require(baoDeployerAddr.code.length > 0, "BaoDeployer not deployed - run infrastructure setup first");
        // console.log("BaoDeployer at:", baoDeployerAddr);

        // BaoDeployer baoDeployer = BaoDeployer(baoDeployerAddr);
        // require(
        //     baoDeployer.operator() == ANVIL_ACCOUNT_0,
        //     "BaoDeployer operator not set - run infrastructure setup first"
        // );
        // console.log("BaoDeployer operator:", ANVIL_ACCOUNT_0);

        // ========================================
        // Phase 2: Deployment
        // ========================================

        // Set private key for broadcasts
        setDeployerPk(PRIVATE_KEY);

        console.log("Starting deployment on network:", network);
        // Start deployment session
        require(vm.addr(PRIVATE_KEY) == ANVIL_ACCOUNT_0, "private key not correct");
        start(network, salt, vm.addr(PRIVATE_KEY), "");

        // Deploy bootstrap stub
        // console.log("Deploying bootstrap stub...");
        // UUPSProxyDeployStub stub = new UUPSProxyDeployStub();
        // console.log("Stub deployed at:", _get(SESSION_STUB));

        // Deploy the token
        deployERC20WithData(TOKEN);

        // Finish and save
        finish();

        // Get deployed address
        address tokenAddr = _get(TOKEN);
        console.log("Deployed ERC20WithData proxy at:", tokenAddr);
        console.log(
            string.concat("   '", ERC20WithData(tokenAddr).name(), "' (", ERC20WithData(tokenAddr).symbol(), ")")
        );
        console.log("   owner:", ERC20WithData(tokenAddr).owner());

        console.log("Deployment complete");
    }

    // ============================================================================
    // Deployment Functions
    // ============================================================================

    /// @notice Deploy ERC20WithData as a proxy
    /// @param key Contract key (e.g., "contracts.token")
    function deployERC20WithData(string memory key) internal {
        // Deploy implementation with constructor arg
        ERC20WithData impl = new ERC20WithData(address(0));

        address owner = _getAddress(OWNER);
        string memory name = _getString(NAME);
        string memory symbol = _getString(SYMBOL);
        uint256 aUint = _getUint(STORAGE_UINT);

        // Encode initializer call
        bytes memory initData = abi.encodeCall(ERC20WithData.initialize, (owner, name, symbol, aUint));

        // Deploy proxy via CREATE3
        // Note: deployProxy internally handles broadcast via hooks
        deployProxy(
            key,
            address(impl),
            initData,
            "ERC20WithData",
            "test/mocks/deployment/ERC20WithData.sol",
            _getAddress(SESSION_DEPLOYER)
        );
    }
}
