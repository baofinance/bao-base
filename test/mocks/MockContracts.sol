// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title MockContracts
 * @notice Common mock contracts for deployment testing
 * @dev Centralized location for all simple test contracts to reduce duplication
 */

// Simple mock contract with name
contract MockContract {
    string public name;

    constructor(string memory _name) {
        name = _name;
    }
}

// Mock implementation with initialization
contract MockImplementation {
    uint256 public value;

    function initialize(uint256 _value) external {
        value = _value;
    }
}

// Mock ERC20 for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

// Mock Oracle for dependency testing
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

// Mock Token that depends on Oracle
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

// Mock Minter with multiple dependencies
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
