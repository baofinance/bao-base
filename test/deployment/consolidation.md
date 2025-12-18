resume has not been deprecated - its functionality is now in start and so tests that test the resumption of deployments are still valid: they just start from a different input file.

I'm not doing "data layer consolidation" I'm doing test consolidation and some tests have "harbor specifics" but these are just mocks to test functionality that will be used  by other projects (e.g. harbor) so these are very relevant. They should be in their own test files, of course, but I want to ensure we don't lose them.

So:
* test_MultipleWritesWithProxyDeployment is moved into the harbor mock tests - it can go in it's own file for now, commented out
* test_LoadFromJson can go
* test_RevertWhen_ResumeNonexistentPath needs to be added to the data layer tests but using start(, , <non-existing start point>)
* test_RevertWhen_ResumeFromUnfinishedRun this should be retained using start
* test_ResumeFromJsonHelperCreatesActiveRun should be retained

I think we have four layers/categories of testing:
* data layer - Does DeploymentData* work (no persistence, just json strings)
* deployment persistence - Do the start/finish features work, are new files created for each network, etc.
* deployment - do simple deploys work - including using the CREATE3 deployment and the operator setup
* mock harbor layer - where we actually do a mock of what harbor might use - more complex deployments with intersharing of addresses between contracts etc.

Test files should not have more than one layer in them

I want to start by bringing back, in-situ, the commented out tests, other than the ones I agreed above that can be removed





abstract test + concrete for json and memory, for data layer
some persistence but minor




Test File Consolidation Analysis52
Based on my review, here's my brutal assessment and consolidation recommendations:


Core Consolidation Opportunities:
Group 1: Data Layer Tests → Consolidate into DeploymentData.t.sol
DeploymentDataMemory.t.sol (26 tests) - Memory-backed storage
DeploymentDataJson.t.sol (45 tests) - JSON-backed storage
DeploymentDataJsonPersistence.t.sol (7 tests) - File persistence
Rationale: These all test the same interface (IDeploymentData) with different backends. Combine into ONE file with THREE test contracts:

DeploymentDataMemoryTest - Keep memory tests
DeploymentDataJsonTest - Keep JSON tests
DeploymentDataPersistenceTest - Keep persistence tests
Result: 3 contracts in 1 file instead of 3 separate files. Tests remain isolated.

Group 2: JSON Serialization → Merge into DeploymentData.t.sol
DeploymentJson.t.sol (7 active tests) - JSON serialization of deployments
DeploymentJsonString.t.sol (8 tests) - String-based JSON (toJson/fromJson)
Rationale: Both test JSON serialization. DeploymentJsonString tests the same functionality as DeploymentJson but without file I/O. Merge DeploymentJsonString tests into DeploymentJson as additional test cases.

Result: DELETE DeploymentJsonString.t.sol, add its 8 tests to DeploymentJson.t.sol (15 total tests).

Group 3: Deployment Operations → Create DeploymentOperations.t.sol
DeploymentBasic.t.sol (14 tests) - Basic contract deployment, useExisting, finish
DeploymentDependency.t.sol (7 tests) - Dependency management
DeploymentProxy.t.sol (8 tests, ALL commented out) - Proxy deployment
Rationale: These test core deployment operations. DeploymentProxy is entirely commented out (can uncomment after Harbor updates). DeploymentBasic and DeploymentDependency cover overlapping territory.

Action:

Merge DeploymentDependency.t.sol INTO DeploymentBasic.t.sol → Rename to DeploymentOperations.t.sol (21 tests)
Keep DeploymentProxy.t.sol separate (Harbor-specific, all commented out pending fixes)
Result: 2 files → 1 active file + 1 pending file

Group 4: High-Level Workflows → All COMMENTED OUT
DeploymentWorkflow.t.sol (8 tests, ALL commented out)
DeploymentIntegration.t.sol (6 tests) - End-to-end integration
DeploymentUpgrade.t.sol (12 tests, ALL commented out)
Rationale: DeploymentWorkflow and DeploymentUpgrade are ENTIRELY commented out. DeploymentIntegration has 6 active tests doing end-to-end workflows.

Action:

KEEP DeploymentIntegration.t.sol (6 active tests) - Only file with active integration tests
DELETE DeploymentWorkflow.t.sol - Entirely commented out, overlap with Integration
KEEP DeploymentUpgrade.t.sol - All commented out but represents important future functionality
Result: Keep Integration (active), delete Workflow (redundant), keep Upgrade (future work)

Group 5: Infrastructure Tests → Keep Separate
DeploymentKeys.t.sol (24 tests) - Key registration & validation
BaoDeployer.t.sol (15 tests) - Deterministic deployment infrastructure
UUPSProxyDeployStub.t.sol (4 tests) - UUPS proxy stub
Rationale: Each tests a distinct, independent component. No overlap.

Action: KEEP ALL THREE as-is.

Group 6: Harbor-Specific → Keep for Harbor team
MockHarborDeployment.t.sol (5 tests, ALL commented out)
Rationale: Harbor-specific example. All commented out pending Harbor updates.

Action: KEEP (Harbor team will uncomment when ready)

FINAL CONSOLIDATION SUMMARY:
Action	Files	Result
DELETE	StdJsonKeyTest.t.sol, DeploymentConfigParameterBag.t.sol, DeploymentWorkflow.t.sol	-3 files
MERGE	DataMemory + DataJson + DataJsonPersistence → DeploymentData.t.sol	-2 files (3→1)
MERGE	DeploymentJsonString → DeploymentJson.t.sol	-1 file
MERGE	DeploymentBasic + DeploymentDependency → DeploymentOperations.t.sol	-1 file (2→1)
KEEP	DeploymentKeys, BaoDeployer, UUPSProxyDeployStub, DeploymentIntegration, DeploymentJson, DeploymentUpgrade, DeploymentProxy, MockHarborDeployment	8 files
Result: 17 files → 10 files (41% reduction)

Active tests: ~140 active tests (down from ~170 after removing commented/stub tests)

test/deployment/
├── DeploymentData.t.sol          ← DataMemory + DataJson + DataJsonPersistence (78 tests, 3 contracts)
├── DeploymentJson.t.sol          ← JSON serialization + JsonString tests (15 tests)
├── DeploymentOperations.t.sol    ← Basic + Dependency tests (21 tests)
├── DeploymentIntegration.t.sol   ← End-to-end workflows (6 tests) - KEEP
├── DeploymentKeys.t.sol          ← Key validation (24 tests) - KEEP
├── BaoDeployer.t.sol             ← Deployment infrastructure (15 tests) - KEEP
├── UUPSProxyDeployStub.t.sol     ← UUPS proxy stub (4 tests) - KEEP
├── DeploymentUpgrade.t.sol       ← Upgrade tests (all commented) - KEEP for future
├── DeploymentProxy.t.sol         ← Proxy tests (all commented) - KEEP for Harbor
└── MockHarborDeployment.t.sol    ← Harbor example (all commented) - KEEP for Harbor