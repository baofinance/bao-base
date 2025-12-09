# Key Registration System

## Problem Statement

The deployment JSON system stores configuration as key-value pairs. Keys like `contracts.pegged.address` are registered in the constructor so the system knows their types for serialization/deserialization.

**The Dynamic Key Problem**: Some keys are only known at runtime:
- Network-specific keys: `networks.mainnet.chainId`, `networks.sepolia.chainId`
- Role keys: `contracts.pegged.roles.MINTER_ROLE.value`

These keys get written to JSON fine (registered dynamically at write time), but **don't load back** because:
1. A fresh instance only knows constructor-registered keys
2. `_fromJsonNoSave()` iterates `schemaKeys()` which only contains constructor keys
3. The dynamic keys in the JSON file are silently ignored

## Solution: Pattern-Based Registration

Register patterns with single-level wildcards that match families of keys:
```solidity
addAnyUintKeySuffix("networks", "chainId");  // matches networks.*.chainId
```

When loading JSON, expand patterns against actual JSON keys to register concrete keys.

## Key States

A key can be in one of three states:

| State | `_keyRegistered[key]` | Matches Pattern | Can Read | Can Write |
|-------|----------------------|-----------------|----------|-----------|
| Unregistered | false | false | ❌ Error | ❌ Error |
| Pattern-matched | false | true | ✅ (after auto-register) | ✅ (auto-registers) |
| Explicitly registered | true | - | ✅ | ✅ |

## Registration Methods

### 1. Explicit Registration (Constructor Time)

For keys known at compile time:
```solidity
constructor() {
    addUintKey("config.fee");           // Simple key
    addProxy("contracts.pegged");        // Registers address, type, path, etc.
    addRoles("contracts.pegged", roles); // Registers specific role keys
}
```

### 2. Pattern Registration (Constructor Time)

For key families where the middle segment varies:
```solidity
constructor() {
    // Pattern: networks.*.chainId
    addAnyUintKeySuffix("networks", "chainId");
    addAnyAddressKeySuffix("networks", "collateral");
}
```

### 3. Explicit Role Registration

Roles are semi-dynamic: role names are known (MINTER_ROLE, ADMIN_ROLE), but which contracts use them varies.

```solidity
string[] memory roles = new string[](2);
roles[0] = "MINTER_ROLE";
roles[1] = "BURNER_ROLE";
addRoles("contracts.pegged", roles);
// Registers:
//   contracts.pegged.roles (OBJECT)
//   contracts.pegged.roles.MINTER_ROLE (OBJECT)
//   contracts.pegged.roles.MINTER_ROLE.value (UINT)
//   contracts.pegged.roles.MINTER_ROLE.grantees (STRING_ARRAY)
//   contracts.pegged.roles.BURNER_ROLE (OBJECT)
//   contracts.pegged.roles.BURNER_ROLE.value (UINT)
//   contracts.pegged.roles.BURNER_ROLE.grantees (STRING_ARRAY)
```

This provides **validation**: only declared roles can be used.

## Operations and Validation

### Setting a Value (`_setUint`, `_setRole`, etc.)

**Requirement**: Key MUST be registered (explicit or pattern-matched).

```
_setUint(key, value)
    │
    ▼
validateKey(key)
    │
    ├─ Is key explicitly registered? ─────────────────► YES: proceed
    │
    ├─ Does key match a pattern? ─► YES: auto-register ► proceed
    │
    └─ NO: revert KeyNotRegistered(key)
```

**Example flow for pattern-matched key**:
```solidity
// In constructor:
addAnyUintKeySuffix("networks", "chainId");

// At runtime:
_setUint("networks.mainnet.chainId", 1);
// 1. validateKey("networks.mainnet.chainId") called
// 2. Not explicitly registered
// 3. Matches pattern networks.*.chainId
// 4. Auto-registers "networks.mainnet.chainId" as UINT
// 5. Proceeds to set value
```

**Example flow for unregistered key**:
```solidity
_setUint("networks.mainnet.rpcUrl", "...");
// 1. validateKey("networks.mainnet.rpcUrl") called
// 2. Not explicitly registered
// 3. No pattern matches (no networks.*.rpcUrl pattern)
// 4. Reverts: KeyNotRegistered("networks.mainnet.rpcUrl")
```

### Getting a Value (`_getUint`, `_getRoleValue`, etc.)

**Requirement**: Key MUST be registered AND have a value set.

```
_getUint(key)
    │
    ▼
Check _hasKey[key]
    │
    ├─ true ──► return _uints[key]
    │
    └─ false ─► revert KeyNotFound(key)
```

Note: We check `_hasKey`, not `_keyRegistered`. A key can be registered but have no value yet.

### Writing to JSON (`toJson`)

Iterates all keys in `schemaKeys()` and serializes those with values.

```
toJson()
    │
    ▼
for each key in schemaKeys():
    │
    ├─ has value? ─► serialize to JSON
    │
    └─ no value ──► skip
```

**Key insight**: Pattern-matched keys that were auto-registered during `_set*` calls ARE in `schemaKeys()`, so they serialize correctly.

### Reading from JSON (`_fromJsonNoSave`)

**The critical part**: Must discover pattern-matched keys in JSON before iterating.

```
_fromJsonNoSave(json)
    │
    ▼
Step 1: Expand patterns from JSON
    │
    for each pattern in _patterns:
        for each key in json that matches pattern:
            auto-register key (adds to schemaKeys)
    │
    ▼
Step 2: Load registered keys (excluding roles)
    │
    for each key in schemaKeys():
        if key contains ".roles.": skip (handled in Step 3)
        if key exists in json:
            load value
    │
    ▼
Step 3: Load roles specially
    │
    for each contract with .roles object:
        discover role names via parseJsonKeys
        for each role:
            _setRole() - validates key registered, sets value
            _setGrantee() for each grantee
```

**Why roles are handled specially**: Roles have complex structure (value + grantees array). The generic loader would load the grantees array directly, but `_loadRolesFromJson` needs to call `_setGrantee` for proper tracking. Loading both would cause duplicates.

**Example**:
```json
{
  "networks": {
    "mainnet": { "chainId": 1, "collateral": "0x..." },
    "sepolia": { "chainId": 11155111, "collateral": "0x..." }
  }
}
```

1. Pattern `networks.*.chainId` matches `networks.mainnet.chainId` and `networks.sepolia.chainId`
2. Both keys auto-registered
3. Both keys loaded from JSON

## Why Explicit Role Registration?

**Option A: Wildcard roles (rejected)**
```solidity
addRolesFor("contracts.pegged");  // registers contracts.pegged.roles.*.value
```
- Any role name accepted - no validation
- Typos like `MINTER_ROL` silently create wrong keys
- No documentation of expected roles

**Option B: Explicit roles (chosen)**
```solidity
addRoles("contracts.pegged", ["MINTER_ROLE", "BURNER_ROLE"]);
```
- Only declared roles accepted
- Typos caught: `KeyNotRegistered("contracts.pegged.roles.MINTER_ROL.value")`
- Self-documenting: constructor shows all roles

## Summary of Validation Points

| Operation | Check | On Failure |
|-----------|-------|------------|
| `_set*(key, value)` | `validateKey(key)` | `KeyNotRegistered` |
| `_get*(key)` | `_hasKey[key]` | `KeyNotFound` |
| `toJson()` | iterates `schemaKeys()` | N/A (skips unset) |
| `_fromJsonNoSave()` | expand patterns first | unmatched JSON keys ignored |

## Pattern Format

Single-level wildcard only: `prefix.*.suffix`

- `networks.*.chainId` matches `networks.mainnet.chainId` ✓
- `networks.*.chainId` does NOT match `networks.mainnet.rpc.chainId` ✗

This prevents overly broad patterns that could hide bugs.
