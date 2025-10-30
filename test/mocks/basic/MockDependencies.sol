// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

/**
 * @title MockOracle
 * @notice Mock Oracle for dependency testing
 */
contract MockOracle {
    string public constant name = "Oracle";
    uint256 public price;
    address public admin;

    constructor(uint256 _price) {
        price = _price;
        admin = msg.sender;
    }

    function setPrice(uint256 _price) external {
        require(msg.sender == admin, "Not admin");
        price = _price;
    }
}

/**
 * @title MockToken
 * @notice Mock Token that depends on Oracle
 */
contract MockToken {
    address public oracle;
    string public name;
    uint8 public decimals;

    constructor(address _oracle, string memory _name, uint8 _decimals) {
        require(_oracle != address(0), "Oracle required");
        oracle = _oracle;
        name = _name;
        decimals = _decimals;
    }

    function getPrice() external view returns (uint256) {
        return MockOracle(oracle).price();
    }
}

/**
 * @title MockMinter
 * @notice Mock Minter with multiple dependencies
 */
contract MockMinter {
    address public token;
    address public oracle;
    address public admin;

    constructor(address _token, address _oracle) {
        require(_token != address(0), "Token required");
        require(_oracle != address(0), "Oracle required");
        token = _token;
        oracle = _oracle;
        admin = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == admin, "Not admin");
        MockERC20(token).mint(to, amount);
    }
}
