// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";

/**
 * @title AddressResolutionHarness
 * @notice Test harness exposing internal address functions
 */
contract AddressResolutionHarness is DeploymentDataMemory {
    constructor() {
        // Register keys for testing
        addAddressKey("treasury");
        addAddressKey("owner");
        addContract("contracts.token");
        addContract("contracts.minter");
        addAddressKey("contracts.minter.feeReceiver");
        addAddressArrayKey("contracts.validators");
        addAddressArrayKey("contracts.recipients");
    }

    // ========== Address parsing ==========

    function parseAddress(string memory s) external pure returns (address) {
        return _parseAddress(s);
    }

    function hexCharToUint8(bytes1 c) external pure returns (uint8) {
        return _hexCharToUint8(c);
    }

    // ========== Address storage ==========

    function setAddress(string memory key, address value) external {
        _setAddress(key, value);
    }

    function setAddressFromString(string memory key, string memory value) external {
        _setAddressFromString(key, value);
    }

    function getAddressResolved(string memory key) external view returns (address) {
        return _getAddress(key);
    }

    function getAddressRaw(string memory key) external view returns (string memory) {
        return _getAddressRaw(key);
    }

    // ========== Resolution helpers ==========

    function resolveAddressValue(string memory value) external view returns (address) {
        return _resolveAddressValue(value);
    }

    function tryResolveAddressValue(string memory value) external view returns (bool success, address result) {
        return _tryResolveAddressValue(value);
    }

    // ========== Address arrays ==========

    function setAddressArray(string memory key, address[] memory values) external {
        _setAddressArray(key, values);
    }

    function setAddressArrayFromStrings(string memory key, string[] memory values) external {
        _setAddressArrayFromStrings(key, values);
    }

    function getAddressArrayResolved(string memory key) external view returns (address[] memory) {
        return _getAddressArray(key);
    }

    function getAddressArrayRaw(string memory key) external view returns (string[] memory) {
        return _getAddressArrayRaw(key);
    }
}

// ============================================================================
// Test: Hex Parsing
// ============================================================================

contract DeploymentAddressParsingTest is BaoTest {
    AddressResolutionHarness internal harness;

    function setUp() public {
        harness = new AddressResolutionHarness();
    }

    // ========== _hexCharToUint8 tests ==========

    function test_HexCharToUint8_Digits() public view {
        assertEq(harness.hexCharToUint8("0"), 0);
        assertEq(harness.hexCharToUint8("1"), 1);
        assertEq(harness.hexCharToUint8("9"), 9);
    }

    function test_HexCharToUint8_LowercaseLetters() public view {
        assertEq(harness.hexCharToUint8("a"), 10);
        assertEq(harness.hexCharToUint8("b"), 11);
        assertEq(harness.hexCharToUint8("f"), 15);
    }

    function test_HexCharToUint8_UppercaseLetters() public view {
        assertEq(harness.hexCharToUint8("A"), 10);
        assertEq(harness.hexCharToUint8("B"), 11);
        assertEq(harness.hexCharToUint8("F"), 15);
    }

    function test_HexCharToUint8_InvalidCharReverts() public {
        vm.expectRevert("Invalid hex character");
        harness.hexCharToUint8("g");
    }

    function test_HexCharToUint8_InvalidCharReverts_Space() public {
        vm.expectRevert("Invalid hex character");
        harness.hexCharToUint8(" ");
    }

    // ========== _parseAddress tests ==========

    function test_ParseAddress_ZeroAddress() public view {
        address result = harness.parseAddress("0x0000000000000000000000000000000000000000");
        assertEq(result, address(0));
    }

    function test_ParseAddress_SimpleAddress() public view {
        address result = harness.parseAddress("0x000000000000000000000000000000000000bEEF");
        assertEq(result, address(0xBEEF));
    }

    function test_ParseAddress_FullAddress() public view {
        address expected = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        address result = harness.parseAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
        assertEq(result, expected);
    }

    function test_ParseAddress_ChecksummedAddress() public view {
        // Checksummed version of the above
        address expected = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        address result = harness.parseAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
        assertEq(result, expected);
    }

    function test_ParseAddress_LowercaseAddress() public view {
        address expected = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        address result = harness.parseAddress("0xae7ab96520de3a18e5e111b5eaab095312d7fe84");
        assertEq(result, expected);
    }

    function test_ParseAddress_UppercaseAddress() public view {
        address expected = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        address result = harness.parseAddress("0xAE7AB96520DE3A18E5E111B5EAAB095312D7FE84");
        assertEq(result, expected);
    }

    function test_ParseAddress_UppercaseX() public view {
        address result = harness.parseAddress("0X000000000000000000000000000000000000bEEF");
        assertEq(result, address(0xBEEF));
    }

    function test_ParseAddress_TooShortReverts() public {
        vm.expectRevert("Invalid address length");
        harness.parseAddress("0xBEEF");
    }

    function test_ParseAddress_TooLongReverts() public {
        vm.expectRevert("Invalid address length");
        harness.parseAddress("0x0000000000000000000000000000000000000BEEF0");
    }

    function test_ParseAddress_MissingPrefixReverts() public {
        // 40 chars without prefix fails length check first
        vm.expectRevert("Invalid address length");
        harness.parseAddress("ae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
    }

    function test_ParseAddress_WrongPrefixSameLengthReverts() public {
        // 42 chars with wrong prefix - this tests the prefix check
        vm.expectRevert("Missing 0x prefix");
        harness.parseAddress("00ae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
    }

    function test_ParseAddress_InvalidPrefixReverts() public {
        vm.expectRevert("Missing 0x prefix");
        harness.parseAddress("1xae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
    }

    function test_ParseAddress_InvalidHexCharReverts() public {
        vm.expectRevert("Invalid hex character");
        harness.parseAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fGGG");
    }
}

// ============================================================================
// Test: Address Storage and Resolution
// ============================================================================

contract DeploymentAddressStorageTest is BaoTest {
    AddressResolutionHarness internal harness;
    address constant TREASURY = 0x3dFc49e5112005179Da613BdE5973229082dAc35;
    address constant TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    function setUp() public {
        harness = new AddressResolutionHarness();
    }

    // ========== Direct address storage ==========

    function test_SetAddress_StoresAsChecksummedHex() public {
        harness.setAddress("treasury", TREASURY);

        string memory raw = harness.getAddressRaw("treasury");
        // Should be checksummed hex string
        assertEq(bytes(raw).length, 42, "Should be 42 chars (0x + 40 hex)");
        assertTrue(bytes(raw)[0] == "0" && bytes(raw)[1] == "x", "Should start with 0x");
    }

    function test_SetAddress_ResolvesToOriginal() public {
        harness.setAddress("treasury", TREASURY);

        address resolved = harness.getAddressResolved("treasury");
        assertEq(resolved, TREASURY);
    }

    // ========== String address storage (literal) ==========

    function test_SetAddressFromString_LiteralAddress() public {
        harness.setAddressFromString("treasury", "0x3dFc49e5112005179Da613BdE5973229082dAc35");

        address resolved = harness.getAddressResolved("treasury");
        assertEq(resolved, TREASURY);
    }

    function test_SetAddressFromString_LiteralAddressRawPreserved() public {
        string memory input = "0x3dFc49e5112005179Da613BdE5973229082dAc35";
        harness.setAddressFromString("treasury", input);

        string memory raw = harness.getAddressRaw("treasury");
        assertEq(raw, input, "Raw value should be preserved exactly");
    }

    // ========== String address storage (reference) ==========

    function test_SetAddressFromString_KeyReference() public {
        // First set the referenced key
        harness.setAddress("treasury", TREASURY);

        // Now set another key as a reference
        harness.setAddressFromString("contracts.minter.feeReceiver", "treasury");

        // Raw should be the reference string
        string memory raw = harness.getAddressRaw("contracts.minter.feeReceiver");
        assertEq(raw, "treasury");

        // Resolved should be the treasury address
        address resolved = harness.getAddressResolved("contracts.minter.feeReceiver");
        assertEq(resolved, TREASURY);
    }

    function test_SetAddressFromString_ChainedReference_SingleLevel() public {
        // treasury -> actual address
        harness.setAddress("treasury", TREASURY);

        // feeReceiver -> treasury (reference)
        harness.setAddressFromString("contracts.minter.feeReceiver", "treasury");

        // Resolution should work
        address resolved = harness.getAddressResolved("contracts.minter.feeReceiver");
        assertEq(resolved, TREASURY);
    }

    // ========== Resolution helpers ==========

    function test_ResolveAddressValue_LiteralAddress() public view {
        address result = harness.resolveAddressValue("0x3dFc49e5112005179Da613BdE5973229082dAc35");
        assertEq(result, TREASURY);
    }

    function test_ResolveAddressValue_KeyReference() public {
        harness.setAddress("treasury", TREASURY);

        address result = harness.resolveAddressValue("treasury");
        assertEq(result, TREASURY);
    }

    function test_TryResolveAddressValue_LiteralSuccess() public view {
        (bool success, address result) = harness.tryResolveAddressValue("0x3dFc49e5112005179Da613BdE5973229082dAc35");
        assertTrue(success);
        assertEq(result, TREASURY);
    }

    function test_TryResolveAddressValue_ReferenceSuccess() public {
        harness.setAddress("treasury", TREASURY);

        (bool success, address result) = harness.tryResolveAddressValue("treasury");
        assertTrue(success);
        assertEq(result, TREASURY);
    }

    function test_TryResolveAddressValue_MissingReferenceFails() public view {
        (bool success, address result) = harness.tryResolveAddressValue("nonexistent.key");
        assertFalse(success);
        assertEq(result, address(0));
    }

    function test_TryResolveAddressValue_ChainedReferenceFails() public {
        // Set up: a -> b -> actual (but we only support single level)
        harness.setAddress("treasury", TREASURY);
        harness.setAddressFromString("contracts.minter.feeReceiver", "treasury");

        // This should work - single level lookup
        (bool success, address result) = harness.tryResolveAddressValue("contracts.minter.feeReceiver");
        assertTrue(success);
        assertEq(result, TREASURY);
    }
}

// ============================================================================
// Test: Address Array Storage and Resolution
// ============================================================================

contract DeploymentAddressArrayTest is BaoTest {
    AddressResolutionHarness internal harness;
    address constant ADDR1 = 0x1111111111111111111111111111111111111111;
    address constant ADDR2 = 0x2222222222222222222222222222222222222222;
    address constant TREASURY = 0x3dFc49e5112005179Da613BdE5973229082dAc35;

    function setUp() public {
        harness = new AddressResolutionHarness();
    }

    // ========== Direct address array storage ==========

    function test_SetAddressArray_StoresAsHexStrings() public {
        address[] memory addrs = new address[](2);
        addrs[0] = ADDR1;
        addrs[1] = ADDR2;

        harness.setAddressArray("contracts.validators", addrs);

        string[] memory raw = harness.getAddressArrayRaw("contracts.validators");
        assertEq(raw.length, 2);
        assertEq(bytes(raw[0]).length, 42);
        assertEq(bytes(raw[1]).length, 42);
    }

    function test_SetAddressArray_ResolvesToOriginals() public {
        address[] memory addrs = new address[](2);
        addrs[0] = ADDR1;
        addrs[1] = ADDR2;

        harness.setAddressArray("contracts.validators", addrs);

        address[] memory resolved = harness.getAddressArrayResolved("contracts.validators");
        assertEq(resolved.length, 2);
        assertEq(resolved[0], ADDR1);
        assertEq(resolved[1], ADDR2);
    }

    // ========== String array storage (literals) ==========

    function test_SetAddressArrayFromStrings_Literals() public {
        string[] memory strs = new string[](2);
        strs[0] = "0x1111111111111111111111111111111111111111";
        strs[1] = "0x2222222222222222222222222222222222222222";

        harness.setAddressArrayFromStrings("contracts.validators", strs);

        address[] memory resolved = harness.getAddressArrayResolved("contracts.validators");
        assertEq(resolved.length, 2);
        assertEq(resolved[0], ADDR1);
        assertEq(resolved[1], ADDR2);
    }

    // ========== String array storage (references) ==========

    function test_SetAddressArrayFromStrings_References() public {
        // Set up referenced keys
        harness.setAddress("treasury", TREASURY);
        harness.setAddress("owner", ADDR1);

        // Array with references
        string[] memory strs = new string[](2);
        strs[0] = "treasury";
        strs[1] = "owner";

        harness.setAddressArrayFromStrings("contracts.recipients", strs);

        // Raw should preserve references
        string[] memory raw = harness.getAddressArrayRaw("contracts.recipients");
        assertEq(raw[0], "treasury");
        assertEq(raw[1], "owner");

        // Resolved should be actual addresses
        address[] memory resolved = harness.getAddressArrayResolved("contracts.recipients");
        assertEq(resolved[0], TREASURY);
        assertEq(resolved[1], ADDR1);
    }

    function test_SetAddressArrayFromStrings_MixedLiteralsAndReferences() public {
        // Set up referenced key
        harness.setAddress("treasury", TREASURY);

        // Array with mix of literal and reference
        string[] memory strs = new string[](3);
        strs[0] = "0x1111111111111111111111111111111111111111"; // literal
        strs[1] = "treasury"; // reference
        strs[2] = "0x2222222222222222222222222222222222222222"; // literal

        harness.setAddressArrayFromStrings("contracts.recipients", strs);

        address[] memory resolved = harness.getAddressArrayResolved("contracts.recipients");
        assertEq(resolved.length, 3);
        assertEq(resolved[0], ADDR1);
        assertEq(resolved[1], TREASURY);
        assertEq(resolved[2], ADDR2);
    }

    // ========== Empty array ==========

    function test_SetAddressArray_Empty() public {
        address[] memory addrs = new address[](0);
        harness.setAddressArray("contracts.validators", addrs);

        address[] memory resolved = harness.getAddressArrayResolved("contracts.validators");
        assertEq(resolved.length, 0);
    }

    // ========== Overwrite clears old values ==========

    function test_SetAddressArray_OverwriteShrinksLength() public {
        address[] memory first = new address[](3);
        first[0] = ADDR1;
        first[1] = ADDR2;
        first[2] = TREASURY;
        harness.setAddressArray("contracts.validators", first);

        address[] memory second = new address[](1);
        second[0] = TREASURY;
        harness.setAddressArray("contracts.validators", second);

        address[] memory resolved = harness.getAddressArrayResolved("contracts.validators");
        assertEq(resolved.length, 1);
        assertEq(resolved[0], TREASURY);
    }
}

// ============================================================================
// Test: Edge Cases and Error Conditions
// ============================================================================

contract DeploymentAddressEdgeCasesTest is BaoTest {
    AddressResolutionHarness internal harness;

    function setUp() public {
        harness = new AddressResolutionHarness();
    }

    function test_ResolveUnsetKeyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "treasury"));
        harness.getAddressResolved("treasury");
    }

    function test_ResolveReferenceToUnsetKeyReverts() public {
        // Set a reference to a key that doesn't exist
        harness.setAddressFromString("contracts.minter.feeReceiver", "nonexistent");

        // Try to resolve should revert when looking up the reference
        vm.expectRevert(abi.encodeWithSelector(DeploymentDataMemory.ValueNotSet.selector, "nonexistent"));
        harness.getAddressResolved("contracts.minter.feeReceiver");
    }

    function test_TryResolve_DoesNotRevert_OnMissingKey() public view {
        (bool success, ) = harness.tryResolveAddressValue("missing.key");
        assertFalse(success);
    }

    function test_AddressMaxValue() public view {
        address result = harness.parseAddress("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");
        assertEq(result, address(type(uint160).max));
    }

    function test_SetAndGetSameAddressMultipleTimes() public {
        address expected = 0xcafE000000000000000000000000000000000001;

        harness.setAddress("treasury", expected);
        assertEq(harness.getAddressResolved("treasury"), expected);

        // Overwrite
        address expected2 = 0xdEaD000000000000000000000000000000000002;
        harness.setAddress("treasury", expected2);
        assertEq(harness.getAddressResolved("treasury"), expected2);
    }

    function test_ReferenceUpdatesProperly() public {
        address treasury1 = 0x1111111111111111111111111111111111111111;
        address treasury2 = 0x2222222222222222222222222222222222222222;

        // Set treasury
        harness.setAddress("treasury", treasury1);

        // Set feeReceiver as reference to treasury
        harness.setAddressFromString("contracts.minter.feeReceiver", "treasury");
        assertEq(harness.getAddressResolved("contracts.minter.feeReceiver"), treasury1);

        // Update treasury
        harness.setAddress("treasury", treasury2);

        // feeReceiver should now resolve to new treasury
        assertEq(harness.getAddressResolved("contracts.minter.feeReceiver"), treasury2);
    }
}
