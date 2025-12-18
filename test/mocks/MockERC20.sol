// SPDX-License-Identifier: MIT
// solhint-disable one-contract-per-file
pragma solidity >=0.8.28 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnable2Arg} from "@bao/interfaces/IBurnable2Arg.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

// MockERC20Base is a base contract for creating mock ERC20 tokens with a specified number of decimals.
abstract contract MockERC20Base is ERC20, IBaoRoles {
    uint256 public constant MINTER_ROLE = 1 << 0;
    uint256 public constant BURNER_ROLE = 1 << 1;

    uint8 private immutable _DECIMALS;
    mapping(address => uint256) private _roles;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _DECIMALS;
    }

    function grantRoles(address user, uint256 roles) public virtual override {
        uint256 current = _roles[user];
        uint256 updated = current | roles;
        if (updated != current) {
            _roles[user] = updated;
            emit RolesUpdated(user, updated);
        }
    }

    function revokeRoles(address user, uint256 roles) public virtual override {
        uint256 current = _roles[user];
        uint256 updated = current & ~roles;
        if (updated != current) {
            _roles[user] = updated;
            emit RolesUpdated(user, updated);
        }
    }

    function renounceRoles(uint256 roles) public virtual override {
        revokeRoles(msg.sender, roles);
    }

    function rolesOf(address user) public view virtual override returns (uint256 roles) {
        roles = _roles[user];
    }

    function hasAnyRole(address user, uint256 roles) public view virtual override returns (bool) {
        return _roles[user] & roles != 0;
    }

    function hasAllRoles(address user, uint256 roles) public view virtual override returns (bool) {
        return (_roles[user] & roles) == roles;
    }
}

contract MockERC20 is MockERC20Base, IMintable, IBurnable, IBurnableFrom {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20Base(name_, symbol_, decimals_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }
}

contract MockERC20Burn2Arg is MockERC20Base, IMintable, IBurnable2Arg {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20Base(name_, symbol_, decimals_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    function burnSignature() external pure returns (string memory) {
        return "burn(address,uint256)";
    }
}

contract MockERC20Burn1Arg is MockERC20Base, IMintable, IBurnable {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20Base(name_, symbol_, decimals_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function burnSignature() external pure returns (string memory) {
        return "burn(uint256)";
    }
}

contract MockERC20BurnFrom is MockERC20Base, IMintable, IBurnableFrom {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20Base(name_, symbol_, decimals_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    function burnSignature() external pure returns (string memory) {
        return "burnFrom(address,uint256)";
    }
}

// solhint-enable one-contract-per-file
