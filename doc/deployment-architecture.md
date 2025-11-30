# Deployment Architecture Overview

This document describes the bao-base deployment framework architecture, showing the inheritance hierarchy and how downstream projects (like Harbor) extend it.

## Design Principles

1. **Linear core inheritance** - The main chain is strictly linear to avoid diamond inheritance issues
2. **Single override per virtual** - Each virtual function is overridden on exactly one path to any concrete class
3. **Deployment is the memory-based test class** - No separate "memory testing" class needed
4. **DeploymentJson hides setters for production** - Testing variants re-expose them

## Core Inheritance Hierarchy

```mermaid
flowchart TB
    classDef core fill:#e3f2fd,stroke:#1976d2,color:#0d47a1,stroke-width:2px;
    classDef mixin fill:#fff3e0,stroke:#f57c00,color:#e65100,stroke-width:1px;
    classDef concrete fill:#e8f5e9,stroke:#388e3c,color:#1b5e20,stroke-width:2px;

    subgraph core["Core Linear Chain (abstract)"]
        DeploymentKeys["DeploymentKeys<br/><i>Key registry, schema validation</i>"]
        DeploymentDataMemory["DeploymentDataMemory<br/><i>In-memory storage maps</i><br/><i>Public getters/setters</i><br/><small>defines: _afterValueChanged (abstract)</small>"]
        Deployment["Deployment<br/><i>Deployment operations</i><br/><small>defines: _ensureBaoDeployerOperator (abstract)</small>"]

        DeploymentKeys --> DeploymentDataMemory
        DeploymentDataMemory --> Deployment
    end

    subgraph concretes["Concrete Classes"]
        DeploymentTesting["DeploymentTesting<br/><i>Memory-only testing</i><br/><small>overrides: _afterValueChanged (no-op)</small><br/><small>overrides: _ensureBaoDeployerOperator (vm.prank)</small>"]
        DeploymentJson["DeploymentJson<br/><i>JSON persistence (production)</i><br/><i>Hides setters (internal only)</i><br/><small>overrides: _afterValueChanged (persist)</small><br/><small>overrides: _ensureBaoDeployerOperator (production check)</small>"]
        DeploymentJsonTesting["DeploymentJsonTesting<br/><i>JSON + testing features</i><br/><i>Re-exposes setters as public</i><br/><small>overrides: _ensureBaoDeployerOperator (vm.prank)</small>"]
    end

    Deployment --> DeploymentTesting
    Deployment --> DeploymentJson
    DeploymentJson --> DeploymentJsonTesting

    class DeploymentKeys,DeploymentDataMemory,Deployment core
    class DeploymentTesting,DeploymentJson,DeploymentJsonTesting concrete
```

## Key Insight: Visibility Control

- `DeploymentDataMemory` has **public** getters/setters (usable in tests)
- `DeploymentJson` makes setters **internal** (production safety)
- `DeploymentJsonTesting` re-exposes setters as **public** (test harnesses need them)

This means:

- `DeploymentTesting` is for memory-only unit tests (fast, no persistence)
- `DeploymentJson` is for production scripts (persists to filesystem)
- `DeploymentJsonTesting` is for integration tests that need persistence + test helpers

## Virtual Function Override Paths

Each virtual is overridden on **exactly one path** to avoid diamond conflicts:

| Virtual Function               | Defined In           | Override Path                       | Purpose               |
| ------------------------------ | -------------------- | ----------------------------------- | --------------------- |
| `_afterValueChanged()`         | DeploymentDataMemory | → DeploymentTesting (no-op)         | Hook after data write |
| `_afterValueChanged()`         | DeploymentDataMemory | → DeploymentJson (persist)          | Hook after data write |
| `_ensureBaoDeployerOperator()` | Deployment           | → DeploymentTesting (vm.prank)      | Setup for tests       |
| `_ensureBaoDeployerOperator()` | Deployment           | → DeploymentJson (production check) | Setup for production  |
| `_ensureBaoDeployerOperator()` | Deployment           | → DeploymentJsonTesting (vm.prank)  | Setup for tests       |

## No Diamond Inheritance

With this design, there are no diamonds:

```
DeploymentKeys → DeploymentDataMemory → Deployment
                                            │
                              ┌─────────────┼─────────────┐
                              │             │             │
                              ▼             ▼             │
                    DeploymentTesting  DeploymentJson     │
                                            │             │
                                            ▼             │
                                  DeploymentJsonTesting ──┘
```

Each concrete class has exactly one path from `Deployment`.

## File Layout

```
script/deployment/
├── DeploymentKeys.sol              # Key registry (abstract)
├── DeploymentDataMemory.sol        # Storage layer (abstract, extends Keys)
├── Deployment.sol                  # Core operations (abstract, extends DataMemory)
├── DeploymentTesting.sol           # Concrete: Memory-only testing
├── DeploymentJson.sol              # Concrete: JSON persistence (production)
├── DeploymentJsonTesting.sol       # Concrete: JSON + Testing
├── BaoDeployerSetOperator.sol      # Helper: VM.prank operator setup
└── BaoDeployer.sol                 # CREATE3 factory
```

## Downstream Usage (Harbor example)

```mermaid
flowchart TB
    classDef baobase fill:#e3f2fd,stroke:#1976d2,color:#0d47a1;
    classDef harbor fill:#fff3e0,stroke:#f57c00,color:#e65100;
    classDef usage fill:#e8f5e9,stroke:#388e3c,color:#1b5e20;

    subgraph baobase["bao-base"]
        DeploymentJson["DeploymentJson"]
        DeploymentJsonTesting["DeploymentJsonTesting"]
    end

    subgraph harbor["harbor"]
        HarborDeployment["HarborDeployment<br/><i>Harbor-specific keys & operations</i><br/><i>Extends DeploymentJson</i>"]
        HarborDeploymentTesting["HarborDeploymentTesting<br/><i>Extends DeploymentJsonTesting</i><br/><i>Re-exposes setters for tests</i>"]
    end

    subgraph usage["Usage"]
        ProdScript[["script/DeployHarbor.s.sol"]]
        TestSuite[["test/*.t.sol"]]
    end

    DeploymentJson --> HarborDeployment
    DeploymentJsonTesting --> HarborDeploymentTesting

    HarborDeployment -.-> ProdScript
    HarborDeploymentTesting -.-> TestSuite

    class DeploymentJson,DeploymentJsonTesting baobase
    class HarborDeployment,HarborDeploymentTesting harbor
    class ProdScript,TestSuite usage
```

## Key Changes from Previous Architecture

1. **Merged data storage into inheritance chain** - No more separate data layer instance via `_data` pointer
2. **Removed `_createDeploymentData()` factory pattern** - Data storage is inherited, not composed
3. **Removed `DeploymentDataJson`** - JSON serialization moved directly to `DeploymentJson`
4. **Removed `IDeploymentDataWritable` interface** - No longer needed since we use inheritance
5. **No diamonds** - Linear paths from `Deployment` to each concrete class
6. **Visibility control via inheritance** - `DeploymentJson` hides setters; `DeploymentJsonTesting` re-exposes them
7. **Renamed `DeploymentMemoryTesting`** → `DeploymentTesting` (it's the simple memory-based test class)
