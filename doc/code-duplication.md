# Code Duplication Analysis

Analysis performed: 11 December 2025

## High Priority

### 1. BaoRoles vs BaoRoles_v2 (~350 duplicated lines)

**Files:**

- `src/access/BaoRoles.sol`
- `src/access/BaoRoles_v2.sol`

**Duplicated Elements:**

| Element                                                  | Lines (v1) | Lines (v2) |
| -------------------------------------------------------- | ---------- | ---------- |
| `_ROLE_*` constants (256)                                | 214-475    | 189-450    |
| Event signature & slot seed                              | 20-24      | 25-29      |
| Public functions (`rolesOf`, `hasAnyRole`, etc.)         | 31-80      | 36-85      |
| Internal functions (`_updateRoles`, `_grantRoles`, etc.) | 86-137     | 91-143     |
| Modifiers (`onlyRoles`, `onlyOwnerOrRoles`)              | 190-205    | 171-184    |

**Suggested Refactoring:**

Create `BaoRolesBase.sol`:

```solidity
abstract contract BaoRolesBase is IBaoRoles {
  // All _ROLE_* constants
  // Event signature and slot seed
  // rolesOf(), hasAnyRole(), hasAllRoles(), renounceRoles()
  // _updateRoles(), _grantRoles(), _removeRoles()
  // onlyRoles modifier
  // Abstract: _checkOwner(), _checkOwnerOrRoles()
}
```

Then simplify both versions:

```solidity
contract BaoRoles is BaoRolesBase, BaoCheckOwner { ... }
contract BaoRoles_v2 is BaoRolesBase, BaoCheckOwner_v2 { ... }
```

---

### 2. IBaoOwnable vs IBaoOwnable_v2

**Files:**

- `src/access/IBaoOwnable.sol`
- `src/access/IBaoOwnable_v2.sol`

**Duplicated Elements:**

- `error Unauthorized()` - line 16 / 18
- `event OwnershipTransferred(...)` - lines 31-33 / 28-30
- `function owner() external view returns (address)` - line 49 / 37

**Suggested Refactoring:**

Create `IBaoOwnableBase.sol`:

```solidity
interface IBaoOwnableBase {
    error Unauthorized();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    function owner() external view returns (address);
}

interface IBaoOwnable is IBaoOwnableBase { ... }
interface IBaoOwnable_v2 is IBaoOwnableBase { ... }
```

---

## Medium Priority

### 3. MintableBurnableERC20_v1 vs PermittableERC20_v1

**Files:**

- `src/tokens/MintableBurnableERC20_v1.sol`
- `src/tokens/PermittableERC20_v1.sol`

**Duplicated Patterns:**

1. Constructor with `_disableInitializers()`:

   ```solidity
   constructor() {
     _disableInitializers();
   }
   ```

2. `_authorizeUpgrade` implementation:

   ```solidity
   function _authorizeUpgrade(address) internal override onlyOwner {}
   ```

3. Initialization sequence:
   ```solidity
   _initializeOwner(owner_);
   __UUPSUpgradeable_init();
   __ERC20_init(name_, symbol_);
   __ERC20Permit_init(name_);
   ```

**Suggested Refactoring:**

Create `BaoERC20Base.sol` with common patterns:

```solidity
abstract contract BaoERC20Base is BaoOwnable, UUPSUpgradeable, ERC20Upgradeable, ERC20PermitUpgradeable {
  constructor() {
    _disableInitializers();
  }

  function __BaoERC20_init(address owner_, string memory name_, string memory symbol_) internal onlyInitializing {
    _initializeOwner(owner_);
    __UUPSUpgradeable_init();
    __ERC20_init(name_, symbol_);
    __ERC20Permit_init(name_);
  }

  function _authorizeUpgrade(address) internal override onlyOwner {}
}
```

---

## Lower Priority

### 4. DeploymentBase Proxy Query Methods

**File:** `script/deployment/DeploymentBase.sol` (lines 223-280)

**Duplicated Pattern:**

`_getTransferrableProxies()` and `_getTimeoutProxies()` share identical iteration logic:

```solidity
string[] memory allKeys = keys();
string memory suffix = ".implementation.ownershipModel";
proxies = new T[](allKeys.length);
uint256 count = 0;
for (uint256 i; i < allKeys.length; i++) {
    string memory key = allKeys[i];
    if (!LibString.endsWith(key, suffix)) continue;
    if (!LibString.eq(_getString(key), "<MODEL_VALUE>")) continue;
    // ... extract parent key and add to array
}
assembly { mstore(proxies, count) }
```

**Suggested Refactoring:**

Extract common filtering logic:

```solidity
function _getProxiesByOwnershipModel(
  string memory modelValue
) internal view returns (string[] memory parentKeys, uint256 count);
```

---

### 5. DeploymentTesting Setter Wrappers

**File:** `script/deployment/DeploymentTesting.sol` (lines 51-92)

**Duplicated Pattern:**

10+ methods that just wrap internal setters:

```solidity
function set(string memory key, address value) public {
  _set(key, value);
}
function setAddress(string memory key, address value) public {
  _setAddress(key, value);
}
function setString(string memory key, string memory value) public {
  _setString(key, value);
}
// ... etc
```

**Suggested Refactoring:**

Consider making internal setters `public virtual` in base class for test builds, or use a test-only modifier.

---

### 6. DeploymentBase Method Overloads

**File:** `script/deployment/DeploymentBase.sol`

**Duplicated Pattern:**

Multiple methods have overloads differing only by `value` parameter:

- `deployProxy` / `deployProxy(value, ...)`
- `upgradeProxy` / `upgradeProxy(value, ...)`
- `predictableDeployContract` / `predictableDeployContract(value, ...)`

**Suggested Refactoring:**

Use default parameter values or a config struct pattern.

---

## Summary

| Priority | Duplication                  | Est. Lines Saved |
| -------- | ---------------------------- | ---------------- |
| High     | BaoRoles/BaoRoles_v2         | ~350             |
| High     | IBaoOwnable/IBaoOwnable_v2   | ~15              |
| Medium   | ERC20 token bases            | ~20              |
| Low      | DeploymentBase proxy queries | ~30              |
| Low      | DeploymentTesting setters    | ~40              |
| Low      | DeploymentBase overloads     | ~30              |

**Total potential reduction: ~485 lines**
