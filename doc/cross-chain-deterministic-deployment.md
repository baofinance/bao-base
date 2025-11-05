# Cross-Chain Deterministic Deployment Architecture

## Executive Summary

This document describes a secure architecture for deploying contracts with identical addresses across all EVM-compatible blockchains. The system uses Nick's Factory (CREATE2) to deploy a CREATE3-based deployer, which then deploys a canonical BaoFinance deployer contract. This canonical deployer provides a stable identity across chains while allowing operator rotation, and uses commit-reveal to prevent front-running attacks.

**Key Properties:**

- Same contract addresses on all EVM chains
- Operator EOA can be rotated without affecting deployed addresses
- Cryptographically secure against front-running and infrastructure squatting
- Owner-gated operator pattern prevents address squatting during gradual rollout
- Separates deployment authority from contract ownership
- Bytecode-independent deployment (upgrades don't change address)
- Supports both simultaneous multi-chain deployment and gradual chain-by-chain rollout
- Automated deployment via GitHub Actions with secret management and environment protection

## References and Theoretical Foundation

This architecture combines several well-established cryptographic and smart contract patterns:

### CREATE2 / CREATE3 Deterministic Deployment

- **EIP-1014 (CREATE2)**: Vitalik Buterin, "Skinny CREATE2", Ethereum Improvement Proposal, 2018
  - Specification: https://eips.ethereum.org/EIPS/eip-1014
  - Enables deterministic contract addresses based on deployer, salt, and init code
  - Nick's Factory (0x4e59b44847b379578588920cA78FbF26c0B4956C) is the canonical implementation

- **CREATE3 Pattern**: Introduced by Agustin Aguilar (0xSequence), refined by Vectorized (Solady)
  - Solady Implementation: https://github.com/Vectorized/solady/blob/main/src/utils/CREATE3.sol
  - Decouples deployment address from bytecode by using intermediate proxy
  - Address = f(deployer, salt) only, making upgrades deterministic

### Commit-Reveal Schemes

- **"Commitment Schemes"**: Gilles Brassard, David Chaum, Claude Crépeau, "Minimum Disclosure Proofs of Knowledge", 1988
  - Establishes cryptographic binding and hiding properties
  - Preimage resistance of SHA-256/Keccak-256: ~2^256 operations

- **Applied Commit-Reveal in Ethereum**:
  - ENS (Ethereum Name Service) registrar uses commit-reveal to prevent front-running name registration
  - Reference: https://docs.ens.domains/
  - Similar pattern applied here for contract deployment

### Front-Running Prevention

- **"Flash Boys 2.0: Frontrunning, Transaction Reordering, and Consensus Instability in Decentralized Exchanges"**: Daian et al., IEEE S&P 2020
  - Documents MEV (Miner Extractable Value) attacks on Ethereum
  - Establishes need for cryptographic commitments in public mempool environments

- **Time-Lock Puzzles**: Rivest, Shamir, Wagner, "Time-lock puzzles and timed-release crypto", 1996
  - Theoretical foundation for temporal separation between commitment and execution

### Namespace Isolation

- **Collision Resistance**: NIST FIPS 180-4 (SHA-256), NIST FIPS 202 (SHA-3/Keccak)
  - Birthday paradox: ~2^128 operations to find collision in 256-bit hash
  - msg.sender namespacing leverages collision resistance to prevent address squatting

### UUPS Proxy Pattern

- **EIP-1822 (UUPS)**: Gabriel Barros, Patrick Gallagher, "Universal Upgradeable Proxy Standard", 2019
  - Specification: https://eips.ethereum.org/EIPS/eip-1822
  - Places upgrade logic in implementation rather than proxy (vs Transparent Proxy pattern)

- **EIP-1967**: Santiago Palladino, Francisco Giordano, "Standard Proxy Storage Slots", 2019
  - Specification: https://eips.ethereum.org/EIPS/eip-1967
  - Defines storage slots for implementation address and admin to prevent collisions

### Production Implementations

This pattern has been successfully used by:

- **0xSequence**: Cross-chain wallet infrastructure
- **Safe (Gnosis Safe)**: Deterministic deployment across 10+ chains
- **Uniswap V3**: Factory deployment using CREATE2
- **Aave V3**: Cross-chain protocol deployment with identical addresses

---

## Deployment Strategies: Simultaneous vs Gradual Rollout

This architecture supports two deployment strategies:

### Strategy A: Simultaneous Multi-Chain Deployment

Deploy to all chains at once for immediate cross-chain presence. Best for:

- Protocol launches requiring day-1 multi-chain support
- Security-critical infrastructure that benefits from simultaneous audit
- Marketing events tied to broad chain availability

**Process**: Complete Part 2 (infrastructure) on all chains, then Part 3 (contracts) on all chains in parallel.

### Strategy B: Gradual Chain-by-Chain Rollout

Deploy to mainnet first, then expand to additional chains over time. Best for:

- Protocols testing market fit before broad expansion
- Risk mitigation through staged rollout
- Resource-constrained teams prioritizing specific chains
- Gathering mainnet feedback before L2 deployment

**Process**: Complete Part 2 + Part 3 on mainnet, validate, then repeat Part 2 + Part 3 on each additional chain.

**Critical Property**: Both strategies produce **identical addresses** because:

- Infrastructure addresses (Part 2) depend only on bytecode and salt (same everywhere)
- Contract addresses (Part 3) depend only on BaoDeployer address and userSalt (same everywhere)
- Timing of deployment does NOT affect addresses

The sections below document **Strategy B** (gradual rollout), which is more general. Strategy A is simply executing the same steps in parallel across multiple chains rather than sequentially.

---

## Part 1: One-Time Global Setup

These steps are performed once, off-chain, before any on-chain deployment.

**Deployment Strategy Note**: These steps are identical for both simultaneous and gradual rollout. Addresses are pre-calculated for ALL chains, even if you only deploy to mainnet initially.

### Step 1.1: Snapshot CREATE3Deployer Bytecode

The CREATE3Deployer is a minimal factory that wraps Solady's CREATE3 library. This contract must have **identical bytecode** across all chains to get the same address from Nick's Factory.

**Critical Requirements:**

- Parameterless constructor
- No constructor logic
- Identical compiler settings everywhere
- No external library linking (inline Solady CREATE3)
- No chain-specific logic (block.chainid, etc.)

**Process:**

1. Write CREATE3Deployer.sol with fixed Solidity version pragma
2. Compile with exact settings: `solc --optimize --optimize-runs 200`
3. Extract bytecode and save to `bytecode/CREATE3Deployer.hex`
4. **Never recompile** - always deploy from this hex file

```solidity
// CREATE3Deployer.sol - FROZEN BYTECODE
pragma solidity 0.8.23; // Fixed version

import { CREATE3 } from "solady/utils/CREATE3.sol";

contract CREATE3Deployer {
  function deploy(bytes memory creationCode, bytes32 salt) external payable returns (address deployed) {
    return CREATE3.deployDeterministic(creationCode, salt);
  }

  function predictAddress(bytes32 salt) external view returns (address) {
    return CREATE3.predictDeterministicAddress(salt, address(this));
  }
}
```

### Step 1.2: Calculate CREATE3Deployer Address

Using Nick's Factory, calculate where CREATE3Deployer will live:

```javascript
const nicksFactory = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const deployerBytecode = fs.readFileSync("bytecode/CREATE3Deployer.hex");
const salt = "0x0000000000000000000000000000000000000000000000000000000042616f00"; // "Bao\0"

const create3DeployerAddress = ethers.getCreate2Address(nicksFactory, salt, ethers.keccak256(deployerBytecode));
// Result: 0x... (same on all chains)
```

### Step 1.3: Register Governance Addresses

Deterministic deployment is governed by two roles:

- **`deploymentOwner`** – the cold multisig (typically a Safe) that owns BaoDeployer everywhere.
- **`deploymentOperator`** – the hot wallet (EOA) that performs commit/reveal for day-to-day deployments.

Record both addresses in configuration (`config/deployment-governance.json` works well) and persist the owner separately in `config/deployment-owner.txt` for the constructor encoding step. Until the owner delegates to an operator on a given chain, BaoDeployer remains inert.

### Step 1.4: Snapshot BaoDeployer Bytecode (Owner Embedded)

The canonical deployer now inherits Solady's `Ownable` contract. The multisig owner address is baked into the creation bytecode, so the deployer is fully configured the instant Nick's Factory instantiates it—no post-deployment initializer or secret reveal is required.

**Critical Requirements:**

- Constructor takes a single `address initialOwner` argument.
- `_initializeOwner(initialOwner)` runs inside the constructor; ownership cannot be front-run or replaced on other chains.
- `operator` starts as `address(0)`; the owner sets it per chain via `setOperator`.
- Fixed compiler settings, no chain-specific branches.
- Freeze the creation bytecode **including** the encoded owner argument.

```solidity
// BaoDeployer.sol - FROZEN BYTECODE
pragma solidity 0.8.23;

import { CREATE3Deployer } from "./CREATE3Deployer.sol";
import { Ownable } from "solady/auth/Ownable.sol";

contract BaoDeployer is Ownable {
  address public operator;
  mapping(bytes32 => address) public commitments; // commitHash => committer

  event OperatorChanged(address indexed oldOperator, address indexed newOperator);
  event Committed(bytes32 indexed commitHash, string indexed userSalt, address indexed committer);
  event Deployed(address indexed deployed, string indexed userSalt, address indexed deployer);

  constructor(address initialOwner) {
    _initializeOwner(initialOwner); // Owner locked at deployment
    operator = address(0); // Nobody can deploy until owner delegates
  }

  modifier onlyOperator() {
    require(msg.sender == operator, "not operator");
    _;
  }

  function setOperator(address newOperator) external onlyOwner {
    emit OperatorChanged(operator, newOperator);
    operator = newOperator;
  }

  function commit(bytes32 commitHash, string calldata userSalt) external onlyOperator {
    require(commitments[commitHash] == address(0), "already committed");
    commitments[commitHash] = msg.sender;
    emit Committed(commitHash, userSalt, msg.sender);
  }

  function reveal(
    address create3Deployer,
    bytes memory creationCode,
    string calldata userSalt,
    bytes calldata initData
  ) external payable onlyOperator returns (address deployed) {
    // Verify commitment
    bytes32 commitHash = keccak256(abi.encode(creationCode, userSalt, initData));
    require(commitments[commitHash] == msg.sender, "no commitment or wrong sender");
    delete commitments[commitHash];

    // Deploy via CREATE3 with namespaced salt
    bytes32 actualSalt = keccak256(abi.encodePacked(address(this), userSalt));
    deployed = CREATE3Deployer(create3Deployer).deploy{ value: msg.value }(creationCode, actualSalt);

    // Atomic initialization
    if (initData.length > 0) {
      (bool success, bytes memory returnData) = deployed.call(initData);
      require(success, string(returnData));
    }

    emit Deployed(deployed, userSalt, msg.sender);
  }

  function predictAddress(address create3Deployer, string calldata userSalt) external view returns (address) {
    bytes32 actualSalt = keccak256(abi.encodePacked(address(this), userSalt));
    return CREATE3Deployer(create3Deployer).predictAddress(actualSalt);
  }
}
```

**Compilation:**

```bash
# Compile with fixed settings
forge build

# Extract creation bytecode (without constructor args)
forge inspect BaoDeployer bytecode > bytecode/BaoDeployer.hex

# Append ABI-encoded constructor argument (the multisig owner)
OWNER=$(cat config/deployment-owner.txt)
cast abi-encode "constructor(address)" $OWNER >> bytecode/BaoDeployer.hex

# Freeze the resulting artifact
mv bytecode/BaoDeployer.hex bytecode/BaoDeployer-init.hex
```

**Result:** `bytecode/BaoDeployer-init.hex` contains the exact creation bytecode (contract + encoded owner). Deploying this blob with the fixed salt yields the same BaoDeployer address on every chain, and ownership is set immutably at construction time.

### Step 1.5: Define Salt Space

Create `config/deployment-salts.json`:

```json
{
  "infrastructure": {
    "CREATE3Deployer": "0x0000000000000000000000000000000000000000000000000000000042616f00",
    "BaoDeployer": "0x0000000000000000000000000000000000000000000000000000000042616f01"
  },
  "defi-contracts": {
    "HarborImplementation_v1": "harbor-impl-v1",
    "HarborProxy_ETH": "harbor-proxy-eth-mainnet",
    "HarborProxy_USDC": "harbor-proxy-usdc-mainnet",
    "Oracle_ETH": "oracle-eth",
    "Oracle_USDC": "oracle-usdc"
  }
}
```

### Step 1.6: Pre-Calculate All Addresses

Generate `addresses.json` with predicted addresses for every chain:

```bash
# Use foundry script to calculate all addresses
forge script script/CalculateAddresses.s.sol

# This generates addresses.json with all predicted addresses
```

**Result:** `addresses.json` contains every address you'll ever deploy, calculated before touching any chain.

### Step 1.7: Store Deployment Credentials in GitHub

With ownership embedded, the only hot credential is the operator private key. Store it (and the owner address for scripts) in encrypted CI secrets:

```bash
# Operator hot wallet used by GitHub Actions
gh secret set DEPLOYMENT_OPERATOR_KEY --body "$OPERATOR_PRIVATE_KEY"
gh secret set DEPLOYMENT_OPERATOR_ADDRESS --body "$DEPLOYMENT_OPERATOR"

# Multisig owner (read-only value for scripts and dashboards)
gh secret set DEPLOYMENT_OWNER_ADDRESS --body "$DEPLOYMENT_OWNER"

# Store per-chain RPC URLs
gh secret set ETHEREUM_RPC_URL --body "$MAINNET_RPC"
gh secret set ARBITRUM_RPC_URL --body "$ARBITRUM_RPC"
# ... etc for each chain

# Optional: Use OIDC for AWS KMS instead of storing private keys
gh secret set AWS_ROLE_ARN --body "arn:aws:iam::ACCOUNT:role/DeploymentRole"
```

**Team Benefits:**

- Team members can trigger deployments without touching raw keys
- GitHub logs all secret access (audit trail)
- Environment protection rules prevent accidental production deployments
- Encrypted secrets keep the hot key isolated from source control

---

## Part 2: Per-Chain Infrastructure Deployment

These steps are performed **once per blockchain** using Nick's Factory.

**Deployment Strategy Note**:

- **Gradual Rollout**: Start with mainnet only. Add other chains weeks or months later as needed.
- **Simultaneous**: Execute these steps on all target chains in parallel (same week/day).

Infrastructure deployment is **independent per chain** - deploying on mainnet has zero impact on other chains. Each chain gets identical infrastructure addresses but operates autonomously.

### Step 2.1: Deploy CREATE3Deployer to Chain

**Requirements:**

- Nick's Factory must exist at 0x4e59b44847b379578588920cA78FbF26c0B4956C
- Deployer EOA needs ETH for gas
- Must use exact bytecode from `bytecode/CREATE3Deployer.hex`

**Process:**

```javascript
const tx = await nicksFactoryContract.deploy(deployerBytecode, salts.CREATE3Deployer, { gasLimit: 500000 });
await tx.wait();

const deployedAddress = ethers.getCreate2Address(nicksFactory, salts.CREATE3Deployer, keccak256(deployerBytecode));
assert(deployedAddress === addresses.CREATE3Deployer); // Verify match
```

**Verification:**

```bash
cast code $CREATE3_DEPLOYER_ADDRESS --rpc-url $RPC
# Should return bytecode matching CREATE3Deployer.hex
```

### Step 2.2: Deploy BaoDeployer to Chain

**Process:**

```bash
# Deploy using foundry script (Nick's Factory + frozen init bytecode)
forge script script/DeployInfrastructure.s.sol \
  --rpc-url $ETHEREUM_RPC_URL \
  --broadcast \
  --verify
```

The deployment script should read `bytecode/BaoDeployer-init.hex` (creation bytecode + encoded owner) and hand it to Nick's Factory together with the fixed salt from `deployment-salts.json`.

**What this deploys:**

- BaoDeployer with the multisig owner immutably set
- Initial state: `operator = address(0)` (namespace locked until the owner delegates)
- Anyone can pay the gas to deploy this; the address is identical as long as the same bytecode + salt are used

**Anti-Squatting Property:** An attacker can copy the deployment transaction, but without access to the owner multisig they cannot assign an operator. BaoDeployer remains inert until the authorized owner signs a delegation.

### Step 2.3: Delegate Operator Role

Have the owner multisig submit a transaction to set the operator for this chain:

```bash
# Produce calldata for BaoDeployer.setOperator
cast calldata "setOperator(address)" $DEPLOYMENT_OPERATOR > /tmp/set-operator-calldata

# Load /tmp/set-operator-calldata into your Safe Transaction Builder (UI or CLI)
# and send a 0-value transaction to $BAO_DEPLOYER_ADDRESS from the multisig.

# After the required confirmations, execute the Safe transaction per your normal process.
```

(If you automate with Foundry, run `forge script script/SetOperator.s.sol` using a multisig signer. The key requirement is that the transaction originates from the owner address.)

**This transaction:**

- Sets `operator = deploymentOperator`
- Can be repeated any time the operator rotates (set to new address or `address(0)` temporarily)
- Leaves a clear governance audit trail in the multisig

**Result:** Infrastructure is ready. Same addresses on every chain where you perform Steps 2.1-2.3. Attackers can pre-deploy BaoDeployer, but without owner approval they cannot activate the namespace; you can arrive later, delegate the operator, and continue with deterministic contract deployments.

**Gradual Rollout Timeline Example**:

- Week 1: Deploy infrastructure on Ethereum mainnet
- Week 4: Validate mainnet stability, deploy infrastructure on Arbitrum
- Week 8: Deploy infrastructure on Optimism and Base
- Week 12: Deploy infrastructure on Polygon and Avalanche

**Simultaneous Timeline Example**:

- Day 1: Deploy infrastructure on Ethereum, Arbitrum, Optimism, Base, Polygon simultaneously
- Day 2: Verify all deployments, proceed to contract deployment

---

## Part 3: DeFi Contract Deployment (UUPS Proxies)

These steps deploy actual DeFi contracts (implementations + proxies) using commit-reveal.

**Deployment Strategy Note**:

- **Gradual Rollout**: Deploy contracts on mainnet first. Gather user feedback, fix bugs via upgrades. Only deploy to additional chains once mainnet is stable.
- **Simultaneous**: Deploy same contract version to all chains at once (useful for audited code with high confidence).

Each chain's deployment is **independent** - you can deploy Harbor v1.0 on mainnet while still running Harbor v0.9 on Arbitrum, or have Harbor only on mainnet for months before expanding.

### Step 3.1: Prepare Deployment

**With commitment (secure):**

```solidity
constructor(address initialOwner) {
  _initializeOwner(initialOwner); // Multisig owns the deployer everywhere
  operator = address(0);          // Owner delegates per chain via setOperator
}

function setOperator(address newOperator) external onlyOwner {
  emit OperatorChanged(operator, newOperator);
  operator = newOperator;
}
```

- Attacker deploys on Arbitrum → multisig owner already set, `operator = address(0)`
- Without multisig approval, attacker cannot call `setOperator` → namespace stays frozen
- You arrive later, multisig signs `setOperator(deploymentOperator)` → deployments resume ✓
- Attacker effectively prepaid the gas for your infrastructure deployment

**Key Insight:** Deterministic addresses depend solely on Nick's Factory, the salt, and the frozen bytecode. Ownership is orthogonal to deployment timing, so even if an attacker pays first, control still sits with the multisig.

**Timeline Example:**

```javascript
console.log(`Committed at block ${tx.blockNumber}`);
console.log(`Can reveal after block ${tx.blockNumber + 10}`);
```

**Why 10 blocks?**

- Ensures the commitment is finalized before reveal
- Gives the commit transaction time to propagate across the network
- Keeps MEV builders from reconstructing the payload before finality

### Step 3.3: Wait for Finalization

**Ethereum Mainnet:** 2 epochs (64 blocks) for finality
**Optimistic Rollups:** Challenge period (7 days for Optimism/Arbitrum)
**Polygon:** ~256 blocks for practical finality

```javascript
const currentBlock = await ethers.provider.getBlockNumber();
const blocksToWait = Math.max(10, CHAIN_FINALITY_BLOCKS[chainId]);
const targetBlock = commitBlock + blocksToWait;

while (currentBlock < targetBlock) {
  await new Promise((resolve) => setTimeout(resolve, 12000)); // 12s Ethereum block time
  currentBlock = await ethers.provider.getBlockNumber();
}
```

### Step 3.4: Reveal and Deploy

**Process:**

```javascript
const tx = await baoDeployer.reveal(addresses.CREATE3Deployer, proxyBytecode, userSalt, initData, {
  gasLimit: 2000000,
});
const receipt = await tx.wait();

// Extract deployed address from event
const deployedEvent = receipt.logs.find(
  (log) => log.topics[0] === baoDeployer.interface.getEvent("Deployed").topicHash,
);
const deployedAddress = ethers.AbiCoder.defaultAbiCoder().decode(["address"], deployedEvent.topics[1])[0];

// Verify address matches prediction
assert(deployedAddress === addresses.HarborProxy_ETH);
```

**What Happens in reveal():**

1. Verify `commitHash` matches stored commitment
2. Verify `msg.sender` matches original committer
3. Delete commitment (prevent replay)
4. Deploy via CREATE3 with namespaced salt: `keccak256(baoDeployer.address + userSalt)`
5. Call `initialize()` on deployed contract **in same transaction**
6. Emit Deployed event

**Result:**

- Proxy deployed at predicted address
- Initialized atomically (no front-running gap)
- Ownership transferred to specified owner (not operator)

### Step 3.5: Verify Deployment

```bash
# Check proxy exists
cast code $HARBOR_PROXY_ADDRESS --rpc-url $RPC

# Check proxy points to implementation
cast call $HARBOR_PROXY_ADDRESS "implementation()" --rpc-url $RPC
# Should return: $HARBOR_IMPLEMENTATION_ADDRESS

# Check initialization succeeded
cast call $HARBOR_PROXY_ADDRESS "owner()" --rpc-url $RPC
# Should return: $MULTISIG_OWNER_ADDRESS (not operator)
```

### Step 3.6: Repeat Across Chains

Perform Steps 3.1-3.5 on every chain where infrastructure exists (Part 2).

**Key Points:**

- Use **same userSalt** on every chain (e.g., "harbor-proxy-eth-mainnet")
- Implementation can differ per chain (chain-specific optimizations)
- Initialization parameters can differ per chain (different oracle addresses, etc.)
- **Proxy address will be identical** because BaoDeployer address and userSalt are identical

**Gradual Rollout Strategy**:

_Mainnet First (Month 1):_

1. Deploy Harbor implementation v1.0 on mainnet
2. Deploy Harbor proxy on mainnet
3. Run for 30 days, gather user feedback
4. Deploy bug fixes as Harbor implementation v1.1
5. Upgrade mainnet proxy to v1.1 via `upgradeToAndCall()`

_Arbitrum Expansion (Month 2):_

1. Deploy Harbor implementation v1.1 (battle-tested version) on Arbitrum
2. Deploy Harbor proxy on Arbitrum (same address as mainnet!)
3. Initialize with Arbitrum-specific oracle addresses
4. Users see familiar address, trust transfers across chains

_Optimism/Base Expansion (Month 3):_

1. Deploy Harbor implementation v1.1 on Optimism and Base
2. Deploy Harbor proxies (same address on all chains)
3. User has single address to remember: "0xHarbor" works on mainnet, Arbitrum, Optimism, Base

**Simultaneous Strategy**:

_Day 1:_

1. Deploy Harbor implementation v1.0 on Ethereum, Arbitrum, Optimism, Base
2. Deploy Harbor proxies on all chains (same address everywhere)
3. Initialize with chain-specific parameters
4. Announce multi-chain launch

_If Bug Found:_

1. Deploy Harbor implementation v1.1 on all affected chains
2. Upgrade proxies on all chains via multisig
3. Proxy addresses unchanged, users unaffected

---

## Part 4: Operator Rotation

The operator EOA can be changed without affecting any deployed contract addresses.

### Why Operator Rotation?

**Use Cases:**

- Key compromise: rotate to new EOA immediately
- Operational security: use different EOAs for different chains
- Team changes: transfer operator role to new team member
- Multisig upgrade: move from EOA to Safe multisig

**Critical Property:**
Changing operator does NOT change deployed addresses because addresses depend on:

- BaoDeployer address (stable, never changes)
- userSalt (defined in deployment-salts.json)

NOT on:

- Operator EOA address
- Transaction sender

### Rotation Process

**Step 4.1: Prepare New Operator**

```javascript
const newOperatorAddress = "0x..."; // New EOA or multisig
// Fund with gas if EOA, or ensure multisig is deployed
```

**Step 4.2: Execute Rotation**

```javascript
const baoDeployer = await ethers.getContractAt("BaoDeployer", addresses.BaoDeployer, currentOperatorSigner);

const tx = await baoDeployer.setOperator(newOperatorAddress);
await tx.wait();

console.log(`Operator changed from ${currentOperator} to ${newOperatorAddress}`);
```

**Step 4.3: Verify**

```javascript
const currentOperator = await baoDeployer.operator();
assert(currentOperator === newOperatorAddress);
```

**Step 4.4: Test New Operator**

Deploy a test contract to verify new operator works:

```javascript
const testSalt = "test-operator-rotation-" + Date.now();
const testBytecode = "0x600160010160005260206000f3"; // Returns 2
const commitHash = ethers.keccak256(
  ethers.AbiCoder.defaultAbiCoder().encode(["bytes", "string", "bytes"], [testBytecode, testSalt, "0x"]),
);

await baoDeployer.connect(newOperatorSigner).commit(commitHash, testSalt);
// Wait 10 blocks...
await baoDeployer.connect(newOperatorSigner).reveal(addresses.CREATE3Deployer, testBytecode, testSalt, "0x");
```

### Rotation Safety

**What's Protected:**

- All previously deployed contracts maintain their addresses
- Predicted addresses in `addresses.json` remain valid
- New operator can continue deploying with pre-calculated addresses

**What Changes:**

- Only the new operator can commit/reveal
- Old operator loses deployment authority immediately
- Commitments in-flight (committed but not revealed) from old operator remain valid

**Emergency Rotation:**

If operator key is compromised:

```javascript
// From backup operator or multisig
await baoDeployer.connect(backupSigner).setOperator(emergencyOperator);
```

If no backup exists and operator key is lost, infrastructure is "frozen" on that chain:

- Existing deployments unaffected
- Cannot deploy new contracts via BaoDeployer
- Must deploy new BaoDeployer with different salt (different addresses)

---

## Part 5: Multisig Ownership vs Operator Authority

**Critical Distinction:**

- **Operator** = Can deploy contracts via BaoDeployer
- **Owner** = Controls deployed contracts (e.g., Harbor proxy)

These are intentionally separate roles.

### Deployment Authority (Operator)

**Who:** Single EOA or lightweight multisig
**Controls:**

- Calling `commit()` and `reveal()` on BaoDeployer
- Deploying new contracts
- Rotating operator role

**Does NOT control:**

- Deployed contracts themselves
- Funds in deployed contracts
- Upgrades to deployed contracts
- Parameters of deployed contracts

**Why EOA?**

- Faster deployments (no multisig coordination)
- Lower gas costs (single signature)
- Can be rotated to multisig later if needed

### Contract Ownership (Multisig)

**Who:** Gnosis Safe or other multisig
**Controls:**

- Upgrades via `upgradeToAndCall()` (UUPS)
- Parameter changes (e.g., liquidation ratios)
- Emergency pauses
- Fund withdrawals
- All business logic governance

**Does NOT control:**

- BaoDeployer operator role
- Ability to deploy new contracts

### Initialization Pattern

When deploying a UUPS proxy, ownership is transferred during initialization:

```solidity
function initialize(
    address _owner,
    // ... other params
) external initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(_owner); // Transfer ownership to multisig
    // ... rest of initialization
}
```

**Flow:**

1. Operator calls `reveal()` with initData encoding `initialize(multisigAddress, ...)`
2. Proxy deployed via CREATE3
3. `initialize()` called in same transaction
4. Ownership transferred to multisig
5. Operator has zero control over proxy

**Result:** Clean separation

- Operator deployed the contract
- Multisig owns the contract
- If operator key compromised: cannot affect existing contracts
- If multisig compromised: cannot deploy new contracts to squat addresses

---

## Part 6: Attack Vector Mitigation

### Attack 1: Front-Running Deployment

**Scenario:** Attacker sees deploy transaction in mempool, copies it, submits with higher gas.

**Mitigation: Commit-Reveal**

- Commitment contains `keccak256(creationCode, userSalt, initData)` but doesn't reveal contents
- Attacker cannot reconstruct reveal transaction from commitment
- Preimage resistance: ~2^256 operations to find creationCode from commitHash
- Even if attacker guesses creationCode, cannot fake msg.sender in reveal()

**Why it works:**

```solidity
function reveal(...) external {
    require(commitments[commitHash] == msg.sender, "wrong sender");
    // Only original committer can reveal
}
```

### Attack 2: Address Squatting

**Scenario:** Attacker predicts address, deploys garbage first.

**Mitigation: msg.sender Namespacing**

```solidity
bytes32 actualSalt = keccak256(abi.encodePacked(address(this), userSalt));
```

- Address depends on BaoDeployer address as msg.sender
- Attacker cannot make CREATE3Deployer receive same msg.sender
- Even if attacker deploys identical BaoDeployer, their instance has different address
- Different address = different msg.sender = different actualSalt = different deployed address

**Mathematical proof:**

```
Your address = CREATE3(BaoDeployer_A, keccak256(BaoDeployer_A, salt))
Attacker address = CREATE3(BaoDeployer_B, keccak256(BaoDeployer_B, salt))

BaoDeployer_A ≠ BaoDeployer_B
Therefore: keccak256(BaoDeployer_A, salt) ≠ keccak256(BaoDeployer_B, salt)
Therefore: Your address ≠ Attacker address
```

### Attack 3: Initialization Front-Running

**Scenario:** Contract deployed, attacker calls `initialize()` before legitimate initializer.

**Mitigation: Atomic Deploy + Initialize**

```solidity
function reveal(..., bytes calldata initData) external {
    deployed = CREATE3Deployer(create3Deployer).deploy(creationCode, actualSalt);
    if (initData.length > 0) {
        (bool success,) = deployed.call(initData);
        require(success);
    }
}
```

- Deployment and initialization in **same transaction**
- No gap for attacker to insert initialization
- If attacker tries to initialize, contract is already initialized (initializer modifier)

### Attack 4: Commitment Replay

**Scenario:** Attacker copies old commitment, replays it.

**Mitigation: Single-Use Commitments**

```solidity
function reveal(...) external {
    require(commitments[commitHash] == msg.sender);
    delete commitments[commitHash]; // Consumed
}
```

- Commitment deleted after reveal
- Second reveal with same commitHash fails
- Cannot replay across chains (commitment stored per-chain)

### Attack 5: Griefing via Commitment Spam

**Scenario:** Attacker commits millions of hashes, never reveals, DoS the system.

**Mitigation: Operator-Only + Gas Costs**

```solidity
modifier onlyOperator() {
    require(msg.sender == operator);
    _;
}
```

- Only operator can commit
- If operator is attacker, can rotate operator
- Gas costs make spam expensive (~50k gas per commitment)
- Commitment storage is a mapping, not array (no iteration, no DoS vector)

### Attack 6: MEV Reordering

**Scenario:** Malicious block builder reorders commit/reveal, or inserts transactions between them.

**Mitigation: Temporal Separation + Finality**

- Commit at block N
- Wait for finality (64+ blocks on Ethereum)
- Reveal at block N+64
- By block N+64, block N is finalized (cannot be reorged)
- Builder cannot reorder finalized history

**Why 10 blocks minimum:**

- Optimistic rollups: ~10 blocks for soft finality
- Ethereum: 2 epochs (64 blocks) for full finality
- Practical compromise between security and UX

### Attack 7: Compiler-Based Address Squatting

**Scenario:** Attacker uses different compiler version, gets same bytecode by chance, deploys first.

**Mitigation: Bytecode Snapshot + Namespace**

- Infrastructure bytecode frozen in hex files
- Even if attacker gets same bytecode, they get different address from Nick's Factory (different tx sender or salt)
- Even if attacker gets same CREATE3Deployer address, msg.sender namespace prevents address collision
- Probability of collision: ~2^160 (address space), effectively impossible

### Attack 8: Infrastructure Squatting During Gradual Rollout

**Scenario:** You deploy on mainnet Month 1. An attacker copies the bytecode and deploys to Arbitrum Month 2 before you do, hoping to seize the namespace.

**Mitigation: Owner-Gated Operator Rotation**

**Without owner gating (vulnerable):**

```solidity
constructor() {
  operator = msg.sender; // Whoever deploys becomes operator!
}
```

- You deploy on mainnet → you're operator ✓
- Attacker deploys on Arbitrum → they're operator ✗
- They can deploy contracts at your pre-calculated addresses

**With owner gating (secure):**

```solidity
constructor(address initialOwner) {
  _initializeOwner(initialOwner); // Multisig is locked in at deployment
  operator = address(0);
}

function setOperator(address newOperator) external onlyOwner {
  emit OperatorChanged(operator, newOperator);
  operator = newOperator;
}
```

- Attacker deploys on Arbitrum → multisig owner already set, `operator = address(0)`
- Without the multisig's signature, attacker cannot call `setOperator` → namespace stays inert
- You arrive later, multisig signs `setOperator(deploymentOperator)` → you take control ✓
- Attacker effectively prepaid the gas for your infrastructure deployment

**Key Insight:** Ownership is domain-separated from deployment. CREATE2 determinism keeps addresses identical, while the multisig retains exclusive authority to activate each chain.

**Timeline:**

```
Month 1: Deploy BaoDeployer (owner baked in) on mainnet; multisig sets operator
Month 2: Attacker deploys BaoDeployer on Arbitrum (operator remains address(0))
Month 3: Multisig submits setOperator for Arbitrum; deployments continue
Month 4: Deploy contracts at pre-calculated addresses
```

**Key Property:** Gradual rollout remains safe. Address determinism holds, and only the owner multisig can unlock a chain by delegating an operator.

---

## Part 7: GitHub Actions Deployment Automation

GitHub provides infrastructure for secure, automated multi-chain deployments:

### Benefits

1. **Secret Management:** Encrypted storage with team access (without revealing secrets)
2. **Environment Protection:** Require approvals before production deployments
3. **Multi-Chain Orchestration:** Deploy to multiple chains in parallel or sequentially
4. **Deployment Tracking:** Built-in API tracks what's deployed where
5. **Audit Trail:** All deployments logged with who approved and when
6. **OIDC Integration:** Connect to cloud HSMs without storing credentials

### Setup GitHub Environments

Create environment for each chain with protection rules:

```bash
# Create environments via GitHub UI or CLI
gh api repos/baofinance/harbor-yield/environments/ethereum-mainnet \
  --method PUT \
  --field deployment_branch_policy[protected_branches]=true \
  --field deployment_branch_policy[custom_branch_policies]=false

# Add protection rules
gh api repos/baofinance/harbor-yield/environments/ethereum-mainnet/deployment-protection-rules \
  --method POST \
  --field type="required_reviewers" \
  --field reviewers[][id]=USER_ID

# Environment-specific secrets
gh secret set OPERATOR_PRIVATE_KEY --env ethereum-mainnet --body "$MAINNET_KEY"
gh secret set RPC_URL --env ethereum-mainnet --body "$MAINNET_RPC"
```

### Workflow: Deploy Infrastructure

`.github/workflows/deploy-infrastructure.yml`:

```yaml
name: Deploy Infrastructure

on:
  workflow_dispatch:
    inputs:
      chain:
        description: "Chain to deploy to"
        required: true
        type: choice
        options:
          - ethereum-mainnet
          - arbitrum
          - optimism
          - base
          - polygon

jobs:
  deploy-infrastructure:
    runs-on: ubuntu-latest
    environment: ${{ inputs.chain }}

    steps:
      - uses: actions/checkout@v4

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Deploy CREATE3Deployer
        env:
          RPC_URL: ${{ secrets.RPC_URL }}
          OPERATOR_KEY: ${{ secrets.DEPLOYMENT_OPERATOR_KEY }}
        run: |
          forge script script/DeployInfrastructure.s.sol \
            --rpc-url $RPC_URL \
            --private-key $OPERATOR_KEY \
            --broadcast \
            --verify

      - name: Generate setOperator calldata for multisig
        env:
          DEPLOYMENT_OPERATOR: ${{ secrets.DEPLOYMENT_OPERATOR_ADDRESS }}
        run: |
          cast calldata "setOperator(address)" $DEPLOYMENT_OPERATOR > set-operator-calldata.txt
          echo "Propose a multisig transaction to BaoDeployer with this calldata:" \
            && cat set-operator-calldata.txt

      - name: Verify Deployment
        run: |
          forge script script/VerifyInfrastructure.s.sol --rpc-url ${{ secrets.RPC_URL }}

      - name: Record Deployment
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.repos.createDeployment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              ref: context.ref,
              environment: '${{ inputs.chain }}',
              description: 'Infrastructure deployment',
              auto_merge: false,
              required_contexts: [],
              payload: {
                contract: 'BaoDeployer',
                chain: '${{ inputs.chain }}',
                timestamp: new Date().toISOString()
              }
            });
```

### Workflow: Multi-Chain Simultaneous Deployment

For deploying to all chains at once:

```yaml
name: Deploy Multi-Chain

on:
  workflow_dispatch:
    inputs:
      contract:
        description: "Contract to deploy"
        required: true
        type: choice
        options:
          - infrastructure
          - harbor

jobs:
  deploy:
    strategy:
      matrix:
        chain:
          - ethereum-mainnet
          - arbitrum
          - optimism
          - base
          - polygon
      fail-fast: false # Continue even if one chain fails

    runs-on: ubuntu-latest
    environment: ${{ matrix.chain }}

    steps:
      - uses: actions/checkout@v4

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Deploy ${{ inputs.contract }}
        env:
          RPC_URL: ${{ secrets.RPC_URL }}
          OPERATOR_PRIVATE_KEY: ${{ secrets.OPERATOR_PRIVATE_KEY }}
        run: |
          forge script script/Deploy${{ inputs.contract }}.s.sol \
            --rpc-url $RPC_URL \
            --private-key $OPERATOR_PRIVATE_KEY \
            --broadcast
```

### Workflow: Commit-Reveal Automation

Automate the 10-block wait between commit and reveal:

```yaml
name: Deploy Contract with Commit-Reveal

on:
  workflow_dispatch:
    inputs:
      chain:
        required: true
        type: choice
        options: [ethereum-mainnet, arbitrum, optimism]
      salt:
        required: true
        description: "User salt for deployment"
        type: string

jobs:
  commit:
    runs-on: ubuntu-latest
    environment: ${{ inputs.chain }}
    outputs:
      commit_block: ${{ steps.commit.outputs.block }}

    steps:
      - uses: actions/checkout@v4
      - uses: foundry-rs/foundry-toolchain@v1

      - name: Commit Deployment
        id: commit
        env:
          RPC_URL: ${{ secrets.RPC_URL }}
          OPERATOR_PRIVATE_KEY: ${{ secrets.OPERATOR_PRIVATE_KEY }}
          USER_SALT: ${{ inputs.salt }}
        run: |
          BLOCK=$(forge script script/CommitDeployment.s.sol \
            --rpc-url $RPC_URL \
            --private-key $OPERATOR_PRIVATE_KEY \
            --broadcast \
            --json | jq -r '.receipts[0].blockNumber')
          echo "block=$BLOCK" >> $GITHUB_OUTPUT
          echo "Committed at block $BLOCK"

  wait-for-finality:
    needs: commit
    runs-on: ubuntu-latest
    steps:
      - name: Wait 10 blocks
        run: |
          echo "Waiting for finality from block ${{ needs.commit.outputs.commit_block }}"
          sleep 120  # ~10 blocks on mainnet (12s * 10)

  reveal:
    needs: [commit, wait-for-finality]
    runs-on: ubuntu-latest
    environment: ${{ inputs.chain }}

    steps:
      - uses: actions/checkout@v4
      - uses: foundry-rs/foundry-toolchain@v1

      - name: Reveal Deployment
        env:
          RPC_URL: ${{ secrets.RPC_URL }}
          DEPLOYMENT_OPERATOR_KEY: ${{ secrets.DEPLOYMENT_OPERATOR_KEY }}
          USER_SALT: ${{ inputs.salt }}
        run: |
          forge script script/RevealDeployment.s.sol \
            --rpc-url $RPC_URL \
            --private-key $DEPLOYMENT_OPERATOR_KEY \
            --broadcast
```

### Local Testing with Anvil

For local development, test without GitHub Actions:

```bash
# Start forked mainnet
anvil --fork-url $MAINNET_RPC_URL --fork-block-number 18000000

# In another terminal, run deployment scripts
forge script script/DeployInfrastructure.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast

# Delegate operator (simulate multisig call)
forge script script/SetOperator.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast

# Test contract deployment
forge script script/DeployHarbor.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast

# Verify addresses match
forge script script/VerifyAddresses.s.sol --rpc-url http://localhost:8545
```

**Makefile for convenience:**

```makefile
# Makefile
.PHONY: anvil-fork deploy-infra set-operator deploy-harbor test-local

anvil-fork:
	anvil --fork-url $(MAINNET_RPC_URL) --chain-id 1

deploy-infra:
	forge script script/DeployInfrastructure.s.sol \
		--rpc-url http://localhost:8545 \
		--broadcast


set-operator:
  forge script script/SetOperator.s.sol \
		--rpc-url http://localhost:8545 \
		--broadcast

deploy-harbor:
	forge script script/DeployHarbor.s.sol \
		--rpc-url http://localhost:8545 \
		--broadcast

test-local: deploy-infra set-operator deploy-harbor
	forge script script/VerifyAddresses.s.sol --rpc-url http://localhost:8545
	@echo "✓ All addresses match predicted values"
```

Usage:

```bash
# Terminal 1: Start anvil
make anvil-fork

# Terminal 2: Deploy everything
make test-local
```

**Don't use `act` for local testing** - it adds Docker overhead and network complexity. Anvil + forge scripts is simpler and faster for contract development.

---

## Appendix: Deployment Checklist

### Pre-Deployment (One-Time)

- [ ] Record deployment owner (multisig) and operator addresses (`config/deployment-governance.json`)
- [ ] Store operator hot key and addresses in GitHub Secrets (with environment protection)
- [ ] Compile CREATE3Deployer with fixed settings (parameterless constructor)
- [ ] Save bytecode to `bytecode/CREATE3Deployer.hex`
- [ ] Compile BaoDeployer with owner constructor argument
- [ ] Append encoded owner and save to `bytecode/BaoDeployer-init.hex`
- [ ] Define all salts in `config/deployment-salts.json`
- [ ] Calculate all addresses, save to `addresses.json`
- [ ] Verify addresses are identical across all chains (simulation)
- [ ] Set up GitHub Environments for each chain with approval rules
- [ ] Test deployment on local anvil fork

### Per-Chain Infrastructure

- [ ] Verify Nick's Factory exists at 0x4e59...56C
- [ ] Fund deployer EOA with gas
- [ ] Deploy CREATE3Deployer via Nick's Factory (`forge script script/DeployInfrastructure.s.sol`)
- [ ] Verify CREATE3Deployer address matches `addresses.json`
- [ ] Deploy BaoDeployer via Nick's Factory (owner baked into bytecode)
- [ ] Verify BaoDeployer address matches `addresses.json`
- [ ] Submit `setOperator(deploymentOperator)` from the owner multisig
- [ ] Verify operator is set correctly via `operator()`
- [ ] Record deployment in GitHub deployment API

### Per-Contract Deployment

- [ ] Compile implementation contract (or use existing)
- [ ] Prepare proxy creation code
- [ ] Prepare initialization data with multisig as owner
- [ ] Calculate commitHash locally
- [ ] Call `commit(commitHash, userSalt)`
- [ ] Record commit block number
- [ ] Wait for finality (10+ blocks)
- [ ] Call `reveal(create3Deployer, proxyBytecode, userSalt, initData)`
- [ ] Verify deployed address matches `addresses.json`
- [ ] Verify proxy points to correct implementation
- [ ] Verify owner is multisig (not operator)
- [ ] Test basic functionality
- [ ] Document deployment in records

### Operator Rotation

- [ ] Prepare new operator address
- [ ] Fund new operator with gas (if EOA)
- [ ] Call `setOperator(newOperator)` from the owner multisig
- [ ] Verify operator changed via `operator()` view function
- [ ] Test new operator with test deployment
- [ ] Update operational documentation
- [ ] Secure old operator key (backup) or destroy

### Emergency Procedures

- [ ] Document backup operator for each chain
- [ ] Store BaoDeployer addresses for quick reference
- [ ] Prepare emergency rotation script
- [ ] Test emergency rotation on testnet
- [ ] Document multisig contacts for deployed contracts
- [ ] Verify separation: operator compromise ≠ contract compromise

---

## Deployment Strategy Comparison

### Gradual Rollout (Recommended for Most Teams)

**When to Use:**

- First major protocol launch (limited track record)
- Limited operational resources (small team)
- Uncertain market fit on specific chains
- Want to iterate on mainnet feedback before L2s
- Security-conscious approach (limit blast radius of bugs)

**Execution Timeline:**

| Phase             | Timing   | Actions                                               | Risk Level      |
| ----------------- | -------- | ----------------------------------------------------- | --------------- |
| Mainnet Launch    | Week 0   | Deploy infrastructure + contracts on Ethereum mainnet | High (new code) |
| Validation Period | Week 1-4 | Monitor mainnet, gather user feedback, fix bugs       | Medium          |
| First L2          | Week 4-6 | Deploy to Arbitrum using battle-tested code           | Low             |
| Additional L2s    | Week 8+  | Deploy to Optimism, Base, Polygon as demand dictates  | Very Low        |

**Advantages:**

- Test in production on one chain before committing to all chains
- Upgrade mainnet implementation multiple times before L2 deployment
- L2s get most stable code version (v1.5 instead of v1.0)
- Resource-efficient: focus team on one chain at a time
- If critical bug found, only one chain affected

**Example: Harbor Rollout**

```
Month 1: Mainnet only
  - Deploy Harbor v1.0.0
  - Find issue with liquidation logic
  - Upgrade to v1.0.1
  - Find gas optimization opportunity
  - Upgrade to v1.1.0

Month 2: Mainnet stable, expand to Arbitrum
  - Deploy Harbor v1.1.0 on Arbitrum (skip v1.0.x entirely)
  - Same proxy address as mainnet
  - Users trust familiar address

Month 3-6: Gradual expansion
  - Optimism: v1.1.0
  - Base: v1.1.0
  - Polygon: v1.2.0 (includes new features developed over 6 months)

Result: All chains have same proxy address, but each got most stable code available at deployment time
```

### Simultaneous Multi-Chain (Recommended for Mature Protocols)

**When to Use:**

- Well-audited code with high confidence
- Protocol upgrade to existing deployed contracts
- Marketing push requiring day-1 multi-chain presence
- Large team that can manage parallel operations
- Code has been battle-tested on testnet extensively

**Execution Timeline:**

| Phase               | Timing  | Actions                                            | Risk Level |
| ------------------- | ------- | -------------------------------------------------- | ---------- |
| Final Audit         | Week -2 | Complete security audit, freeze code               | N/A        |
| Parallel Deployment | Day 0   | Deploy infrastructure on all chains simultaneously | High       |
| Contract Deployment | Day 1-2 | Deploy contracts on all chains                     | High       |
| Coordinated Launch  | Day 3   | Public announcement, all chains live               | Medium     |

**Advantages:**

- Immediate multi-chain presence (marketing benefit)
- Single coordinated launch event
- Consistent user experience across all chains from day 1
- Address consistency is immediately visible

**Disadvantages:**

- If bug found, affects all chains
- Higher operational overhead (coordinate across many chains)
- Cannot iterate based on production feedback before wide rollout
- Must upgrade all chains if issue discovered

**Example: Harbor Simultaneous Launch**

```
Day 0: Infrastructure deployment
  - Deploy CREATE3Deployer on Ethereum, Arbitrum, Optimism, Base, Polygon
  - Deploy BaoDeployer on all chains
  - Verify all addresses match addresses.json

Day 1: Contract deployment
  - Deploy Harbor v1.0.0 implementation on all chains
  - Deploy Harbor proxy on all chains (same address: 0xHarbor...)
  - Initialize with chain-specific parameters

Day 2: Verification
  - Test all deployments
  - Verify cross-chain address consistency
  - Prepare marketing materials

Day 3: Launch
  - Public announcement
  - All chains live simultaneously
  - Single address works everywhere: "Use Harbor at 0xHarbor... on any chain"
```

### Hybrid Strategy

Combine both approaches:

**Phase 1 (Gradual)**: Deploy to Ethereum mainnet first, validate for 30 days

**Phase 2 (Simultaneous)**: Deploy to all L2s at once using mainnet-validated code

**Advantages:**

- Get mainnet validation (highest TVL, highest risk)
- Speed up L2 rollout (lower individual risk)
- Balance between safety and speed

**Example Timeline:**

```
Month 1: Mainnet only (validation)
Month 2: All L2s simultaneously (expansion)
```

### Address Consistency Guarantee

**Critical Property for All Strategies:**

Regardless of deployment strategy, addresses are **always identical** across chains:

```javascript
// Calculated in Part 1 (one-time, before any deployment)
addresses.json = {
  "HarborProxy_ETH": "0x1234...5678"
}

// Deployed Month 1 on mainnet
mainnet.HarborProxy = "0x1234...5678"  ✓

// Deployed Month 3 on Arbitrum (same address)
arbitrum.HarborProxy = "0x1234...5678"  ✓

// Deployed Month 6 on Optimism (still same address)
optimism.HarborProxy = "0x1234...5678"  ✓
```

This works because addresses depend on:

- BaoDeployer address (determined by bytecode, same everywhere)
- userSalt (defined in deployment-salts.json, same everywhere)

And NOT on:

- Deployment timing (month 1 vs month 6)
- Deployment order (mainnet first vs parallel)
- Implementation version (v1.0 vs v1.5)
- Deployer EOA
- Block number or timestamp

---

## Summary

This architecture provides:

1. **Deterministic Cross-Chain Addresses:** Same address on all EVM chains via CREATE2 (infrastructure) and CREATE3 (contracts)

2. **Operational Flexibility:** Operator can be rotated without affecting deployed addresses

3. **Cryptographic Security:** Commit-reveal prevents front-running; preimage resistance ensures commitments cannot be predicted

4. **Infrastructure Squatting Protection:** Committed operator pattern prevents attackers from capturing your namespace during gradual rollout

5. **Namespace Isolation:** msg.sender namespacing prevents address squatting even if attacker deploys identical contracts

6. **Atomic Initialization:** Deploy and initialize in same transaction eliminates initialization front-running

7. **Separation of Powers:** Operator deploys contracts, multisig owns contracts; compromise of one doesn't compromise the other

8. **Upgrade Safety:** UUPS proxies can be upgraded without changing address; implementations can differ per chain

9. **Deployment Flexibility:** Supports both gradual chain-by-chain rollout and simultaneous multi-chain deployment with identical results

10. **Automated Operations:** GitHub Actions integration provides secret management, multi-chain orchestration, approval workflows, and deployment tracking

The system is production-ready and handles all known attack vectors through cryptographic and architectural means rather than trust assumptions. Whether you deploy to all chains at once or roll out gradually over months:

- Users see the same addresses everywhere
- Attackers cannot squat your addresses (even if they deploy infrastructure first)
- Team can collaborate using GitHub without sharing raw secrets
- All deployments are logged and auditable
- Local testing with Foundry + Anvil matches production deployment flow
