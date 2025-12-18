// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentJsonScript} from "@bao-script/deployment/DeploymentJsonScript.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {ERC20WithData} from "@bao-test/mocks/deployment/ERC20WithData.sol";

/**
 * @title DeployTest
 * @notice Deployment script for ERC20WithData
 * @dev Run with: script/deploy-test
 *
 * Demonstrates using DeploymentJsonScript for production deployments.
 * Output JSON is written to deployments/<salt>/<network>/
 *
 * Infrastructure setup (BaoFactory) is explicit in run().
 * On anvil with --auto-impersonate, we can broadcast as multisig.S
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

    function _ensureBaoFactory() internal override returns (address factory) {}

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

        // address baoFactoryAddr = DeploymentInfrastructure.predictBaoFactoryAddress();
        // require(baoFactoryAddr.code.length > 0, "BaoFactory not deployed - run infrastructure setup first");
        // console.log("BaoFactory at:", baoFactoryAddr);

        // BaoFactory baoFactory = BaoFactory(baoFactoryAddr);
        // require(
        //     baoFactory.operator() == ANVIL_ACCOUNT_0,
        //     "BaoFactory operator not set - run infrastructure setup first"
        // );
        // console.log("BaoFactory operator:", ANVIL_ACCOUNT_0);

        // ========================================
        // Phase 2: Deployment
        // ========================================

        // Set private key for broadcasts
        console.log("Starting deployment on network:", network);
        // Start deployment session
        start(network, salt, "");

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
            "eek",
            address(impl),
            initData,
            "ERC20WithData",
            type(ERC20WithData).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );
    }
}
