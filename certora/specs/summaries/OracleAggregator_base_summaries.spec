// ============================================================
// OracleAggregator_base_summaries.spec — shared wiring for the concrete aggregator scene
//
// Design rule for this family (inherited from the OOReporter* family next door):
// START CONCRETE. Nothing here replaces production behaviour. In particular
//   * `_validateResult`, `_getRequestConfigForRequestId`, `_triggerArbitration`,
//     `_finalizeConditions` and the real `keccak256(abi.encode(result))` bookkeeping all run their
//     REAL bodies;
//   * the reporter/disputer sets are read as REAL storage — there is no ghost set. What the set is
//     depends on the conf: `AggregatorAccess` and `AggregatorResolution` use Solady's production
//     `EnumerableSetLib`, while `AggregatorConfig`, `AggregatorVotes`, `AggregatorWindows` and
//     `AggregatorLifecycle` substitute the assembly-free `certora/shims/EnumerableSetLib.sol` through a
//     file-granular remapping in their `packages` list. See "[C] THE SET SUBSTITUTION" below;
//   * `upgradeToAndCall` is kept concrete.
// ============================================================

import "./Solady/OwnableRoles.spec";
import "./OptimisticOraclePayout_constants.spec";

methods {
    /*--------------------------------------------------------------
                    [B] SOLADY OWNABLEROLES GHOST MODEL
    --------------------------------------------------------------*/

    // Role bits, from src/oracle/mixins/Auth.sol and OracleAggregator.sol:206:
    //   ADMIN_ROLE        = _ROLE_0 = ghostHasRole0
    //   OPERATOR_ROLE     = _ROLE_1 = ghostHasRole1
    //   RULE_MANAGER_ROLE = _ROLE_2 = ghostHasRole2
    function _.hasAnyRole(address user, uint256 roles) internal =>
        hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal =>
        hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal =>
        rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) =>
        checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal =>
        setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal =>
        updateRolesCVL(currentContract, user, roles, on) expect void;

    function _.ownershipHandoverExpiresAt(address pendingOwner) internal =>
        ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;

    /*--------------------------------------------------------------
                    AGGREGATOR: PRODUCTION VIEWS (RAW KEYS)
    --------------------------------------------------------------*/

    function OracleAggregator.globalPaused() external returns (bool) envfree;
    function OracleAggregator.voteCount(bytes32) external returns (uint256) envfree;
    function OracleAggregator.hasReporterVoted(bytes32, address) external returns (bool) envfree;
    function OracleAggregator.hasDisputerVoted(bytes32, address) external returns (bool) envfree;
    function OracleAggregator.conflictingResultHash(bytes32) external returns (bytes32) envfree;
    function OracleAggregator.getRuleCount(bytes32) external returns (uint256) envfree;
    function OracleAggregator.owner() external returns (address) envfree;

    /*--------------------------------------------------------------
        AGGREGATOR: HARNESS PROJECTIONS (view/pure additions only)
    --------------------------------------------------------------*/

    // Config, keyed on a raw bytes32 event id (production key is the `EventId` bytes29 UDVT).
    function OracleAggregator.cfgTarget(bytes32) external returns (address) envfree;
    function OracleAggregator.cfgMarketType(bytes32) external returns (OracleAggregator.MarketType) envfree;
    function OracleAggregator.cfgResultLength(bytes32) external returns (uint16) envfree;
    function OracleAggregator.cfgResultLengthOf(OracleAggregator.EventId) external returns (uint16) envfree;
    function OracleAggregator.cfgLivenessWindow(bytes32) external returns (uint32) envfree;
    function OracleAggregator.cfgReporterThreshold(bytes32) external returns (uint16) envfree;
    function OracleAggregator.cfgDisputerThreshold(bytes32) external returns (uint16) envfree;
    function OracleAggregator.cfgArbitrator(bytes32) external returns (address) envfree;
    function OracleAggregator.cfgFinalizer(bytes32) external returns (address) envfree;
    function OracleAggregator.marketPausedRaw(bytes32) external returns (bool) envfree;

    // Config, keyed on a raw request id (the production lookup path).
    function OracleAggregator.eventIdOfRequest(bytes32) external returns (bytes32) envfree;
    function OracleAggregator.targetOfRequest(bytes32) external returns (address) envfree;
    function OracleAggregator.marketTypeOfRequest(bytes32) external returns (OracleAggregator.MarketType) envfree;
    function OracleAggregator.reporterThresholdOfRequest(bytes32) external returns (uint16) envfree;
    function OracleAggregator.disputerThresholdOfRequest(bytes32) external returns (uint16) envfree;
    function OracleAggregator.livenessWindowOfRequest(bytes32) external returns (uint32) envfree;
    function OracleAggregator.resultLengthOfRequest(bytes32) external returns (uint16) envfree;
    function OracleAggregator.arbitratorOfRequest(bytes32) external returns (address) envfree;
    function OracleAggregator.finalizerOfRequest(bytes32) external returns (address) envfree;
    function OracleAggregator.marketPausedOfRequest(bytes32) external returns (bool) envfree;

    // Resolution state, projected to scalars (the PERSISTED fields, not getRequestState's
    // synthesised `Active`).
    function OracleAggregator.statusOf(bytes32) external returns (uint8) envfree;
    function OracleAggregator.disputeCountOf(bytes32) external returns (uint16) envfree;
    function OracleAggregator.windowEndOf(bytes32) external returns (uint40) envfree;
    function OracleAggregator.proposedHashOf(bytes32) external returns (bytes32) envfree;

    // Module sets (private storage, read through the production views).
    function OracleAggregator.reporterModuleCount(bytes32) external returns (uint256) envfree;
    function OracleAggregator.disputerModuleCount(bytes32) external returns (uint256) envfree;
    function OracleAggregator.isReporterModuleRaw(bytes32, address) external returns (bool) envfree;
    function OracleAggregator.isDisputerModuleRaw(bytes32, address) external returns (bool) envfree;
    function OracleAggregator.isReporterOfRequest(bytes32, address) external returns (bool) envfree;
    function OracleAggregator.isDisputerOfRequest(bytes32, address) external returns (bool) envfree;

    // Hash projections (fixed-size pre-images, computed Solidity-side).
    function OracleAggregator.resultHashFor(uint256) external returns (bytes32) envfree;
    function OracleAggregator.voteKeyFor(bytes32, bytes32) external returns (bytes32) envfree;
    function OracleAggregator.voteKeyForValue(bytes32, uint256) external returns (bytes32) envfree;

    // Id bit fields.
    function OracleAggregator.isCanonicalRequestId(bytes32) external returns (bool) envfree;
    function OracleAggregator.isValidEventIdRaw(bytes32) external returns (bool) envfree;
    function OracleAggregator.conditionIndexOf(bytes32) external returns (uint256) envfree;
    function OracleAggregator.arityOfRequest(bytes32) external returns (uint256) envfree;
    function OracleAggregator.conditionIdOfRequestIndex(bytes32, uint256) external returns (bytes32) envfree;

    // Internal predicates.
    function OracleAggregator.isActiveStatusExt(uint8) external returns (bool) envfree;
    function OracleAggregator.validateResultForRequest(
        bytes32, OracleAggregator.MarketType, uint16, uint256[]
    ) external envfree;

    // Proxy / init slots.
    function OracleAggregator.implementationSlotValue() external returns (address) envfree;
    function OracleAggregator.initializedVersion() external returns (uint64) envfree;

    /*--------------------------------------------------------------
                    SCENE COUNTERPARTIES: RECORDER VIEWS
    --------------------------------------------------------------*/

    // Resolution target recorder — the only scalar view of `_finalizeConditions`'s output.
    function BinaryReporterTargetMock.reportCount() external returns (uint256) envfree;
    function BinaryReporterTargetMock.lastConditionId() external returns (bytes32) envfree;
    function BinaryReporterTargetMock.lastResultLen() external returns (uint256) envfree;
    function BinaryReporterTargetMock.lastResult0() external returns (uint256) envfree;
    function BinaryReporterTargetMock.lastResult1() external returns (uint256) envfree;

    // Well-behaved arbitrator's own bookkeeping.
    function MockArbitratorModule.isActive(bytes32) external returns (bool) envfree;
    function MockArbitratorModule.proposedHashes(bytes32) external returns (bytes32) envfree;
    function MockArbitratorModule.initCallCount() external returns (uint256) envfree;

    /*--------------------------------------------------------------
                        [A] CALL RESOLUTION
    --------------------------------------------------------------*/

    // Aggregator -> resolution target, through `cfg.targetContract` (high-level `try` call, so the
    // sighash is known and only the address is symbolic).
    function _.reportResult(OracleAggregator.ConditionId, uint256[]) external => DISPATCHER(true);

    // Aggregator -> reporter / disputer / arbitrator modules, through calldata-supplied addresses.
    function _.initializeReporterModule(OracleAggregator.EventId, bytes) external => DISPATCHER(true);
    function _.initializeDisputerModule(OracleAggregator.EventId, bytes) external => DISPATCHER(true);
    function _.initializeArbitratorModule(OracleAggregator.EventId, bytes) external => DISPATCHER(true);
    function _.updateRules(bytes32, bytes) external => DISPATCHER(true);

    // Aggregator -> arbitrator lifecycle hooks. These are reached through a LOW-LEVEL
    // `arbitratorModule.call(abi.encodeCall(...))`, but `abi.encodeCall` leaves the selector a
    // compile-time constant, so at the admin-resolve site (:482-485) the sighash survives and only the
    // address is symbolic — which is precisely the case `DISPATCHER` handles, and it also pins the
    // callee address (the trace shows `assume callee == <impl>`), so the request's configured
    // arbitrator decides which implementation runs.
    //
    // Without these two entries that site fell through to "UNRESOLVED AUTO summary ... a havoc that
    // havocs all contracts except OracleAggregator" (job 1b0edc8f, line 5402 of the
    // adminResolveCompletesDespiteFailingHook counterexample), which havocs the resolution target's
    // code and storage and made the subsequent `try target.reportResult(...)` fail — failing
    // ORACLE-ARB-01(b) for a reason unrelated to the arbitrator.
    //
    // The `unresolved external in ...` directives below are still required and are NOT redundant with
    // these: they cover the OTHER hook site, inside `_triggerArbitration`, where the analysis loses the
    // sighash as well as the callee, so no by-name summary can match.
    function _.onArbitrationTriggered(bytes32, bytes32) external => DISPATCHER(true);
    function _.onArbitrationResolved(bytes32) external => DISPATCHER(true);

    // The two low-level arbitration hooks: `arbitratorModule.call(abi.encodeCall(...))` at
    // OracleAggregator.sol:689-692 (`_triggerArbitration`) and :482-485 (admin resolve). Here BOTH
    // the callee and the sighash are lost by the analysis, so DISPATCHER cannot help and the
    // Prover falls back to "AUTO havoc ... havocs all contracts except OracleAggregator" — which
    // wipes the target recorder and every counterparty's storage. Diagnosed in job f817ab9a and
    // documented in certora/specs/oracle/README.md (refinement 1); the aggregator reaches the same
    // call site from three entry points, so each needs its own directive.
    //
    // The selector is a compile-time constant that only the ANALYSIS lost, so `optimistic=true` is
    // sound for the sighash and narrows only the ADDRESS. Both arbitrator behaviours the aggregator
    // is designed to tolerate are in the list: MockArbitratorModule (well-behaved, writes its own
    // isActive/proposedHashes) and RevertingArbitratorMock (hooks always revert). Out of model: the
    // codeless opt-out address, whose effect (`ok == true`, no state change) is subsumed by a
    // well-behaved hook that writes nothing.
    unresolved external in OracleAggregator.reportResult(bytes32, uint256[]) => DISPATCH(optimistic=true) [
        MockArbitratorModule.onArbitrationTriggered(bytes32, bytes32),
        RevertingArbitratorMock.onArbitrationTriggered(bytes32, bytes32)
    ];
    unresolved external in OracleAggregator.disputeResult(bytes32) => DISPATCH(optimistic=true) [
        MockArbitratorModule.onArbitrationTriggered(bytes32, bytes32),
        RevertingArbitratorMock.onArbitrationTriggered(bytes32, bytes32)
    ];
    // The admin-notification hook (:482-485). Kept for symmetry with the two trigger sites even
    // though job b4413237 reports it "unused": in that scene both of `resolveResult`'s outbound calls
    // resolve on their own (known sighash plus a scene implementer), so the directive costs nothing
    // and guards against a future refactor losing that resolution.
    unresolved external in OracleAggregator.resolveResult(bytes32, uint256[]) => DISPATCH(optimistic=true) [
        MockArbitratorModule.onArbitrationResolved(bytes32),
        RevertingArbitratorMock.onArbitrationResolved(bytes32)
    ];

    // The module-initialization and rule-broadcast call sites lose their SIGHASH too, so the
    // `DISPATCHER(true)` entries above never match there. Evidence: job c8193060 (the scene bring-up
    // run) reported "Pointer analysis for call resolution failed" for
    // `_registerReporterModules` (from addReporterModules), `_registerDisputerModules` (from
    // addDisputerModules) and `updateRequestRules`, and correspondingly reported
    // "Summarization for external calls of _.initializeReporterModule / _.initializeDisputerModule /
    // _.initializeArbitratorModule / _.updateRules is unused" — i.e. those wildcard entries matched
    // nothing and the calls were left to AUTO havoc. The cause is the same in each case: the callee
    // address comes from calldata (`ModuleConfig.module`) or from the reporter set, and the role
    // modifier's assembly sits between the entry point and the call. One directive per entry point
    // that reaches such a call:
    function PositionManager.moduleById(uint256) external returns (address) => NONDET;
    unresolved external in OracleAggregator.initializeRequest(OracleAggregator.InitParams) =>
        DISPATCH(optimistic=true) [
            PositionManager.moduleById(uint256),
            EOAReporterModule.initializeReporterModule(EOAReporterModule.EventId, bytes),
            MockDisputerModule.initializeDisputerModule(MockDisputerModule.EventId, bytes),
            MockArbitratorModule.initializeArbitratorModule(MockArbitratorModule.EventId, bytes),
            RevertingArbitratorMock.initializeArbitratorModule(RevertingArbitratorMock.EventId, bytes)
        ];
    unresolved external in
        OracleAggregator.addReporterModules(bytes32, OracleAggregator.ModuleConfig[]) =>
        DISPATCH(optimistic=true) [
            EOAReporterModule.initializeReporterModule(EOAReporterModule.EventId, bytes)
        ];
    unresolved external in
        OracleAggregator.addDisputerModules(bytes32, OracleAggregator.ModuleConfig[]) =>
        DISPATCH(optimistic=true) [
            MockDisputerModule.initializeDisputerModule(MockDisputerModule.EventId, bytes)
        ];
    unresolved external in OracleAggregator.setArbitratorModule(bytes32, address, bytes) =>
        DISPATCH(optimistic=true) [
            MockArbitratorModule.initializeArbitratorModule(MockArbitratorModule.EventId, bytes),
            RevertingArbitratorMock.initializeArbitratorModule(RevertingArbitratorMock.EventId, bytes)
        ];
    unresolved external in OracleAggregator.updateRequestRules(bytes32, bytes) => DISPATCH(optimistic=true) [
        EOAReporterModule.updateRules(bytes32, bytes)
    ];
}

/*--------------------------------------------------------------
        SHARED DEFINITIONS — status, roles, method sets
--------------------------------------------------------------*/

// OracleAggregator.ResolutionStatus (OracleAggregator.sol:47-52). `ACTIVE` is never persisted: the
// only status writers are `_triggerArbitration` (:679) and `_finalizeConditions` (:702).
definition NONE() returns uint8 = 0;
definition ACTIVE() returns uint8 = 1;
definition ARBITRATION_REQUESTED() returns uint8 = 2;
definition RESOLVED() returns uint8 = 3;

// Role bits: ADMIN_ROLE = _ROLE_0, OPERATOR_ROLE = _ROLE_1 (src/oracle/mixins/Auth.sol:15,18),
// RULE_MANAGER_ROLE = _ROLE_2 (OracleAggregator.sol:206). Read from the ghost role model.
definition isAdmin(address u) returns bool = ghostHasRole0[currentContract][u];
definition isOperator(address u) returns bool = ghostHasRole1[currentContract][u];
definition isRuleManager(address u) returns bool = ghostHasRole2[currentContract][u];

// The UUPS entry point. Excluded from every state-frame rule and invariant in this family: its
// `delegatecall(gas(), newImplementation, ...)` may rewrite ANY slot, which is semantically correct
// for an upgrade — a state frame over it asserts nothing. The surviving guarantee, "only the owner
// can upgrade", is ORACLE-ACC-06's `implementationChangesRequireOwner`, which keeps it CONCRETE.
definition IS_UPGRADE(method f) returns bool =
    f.selector == sig:upgradeToAndCall(address, bytes).selector;

// The four `whenUnpaused` lifecycle entry points (OracleAggregator.sol:396, :438, :465, :503).
definition IS_LIFECYCLE(method f) returns bool =
    f.selector == sig:reportResult(bytes32, uint256[]).selector
        || f.selector == sig:disputeResult(bytes32).selector
        || f.selector == sig:resolveResult(bytes32, uint256[]).selector
        || f.selector == sig:finalize(bytes32, uint256[]).selector;

// The ten `onlyOperatorOrAdmin` entry points listed in ORACLE-ACC-05's Scope field.
definition IS_CONFIG_MUTATOR(method f) returns bool =
    f.selector == sig:updateRequestRules(bytes32, bytes).selector
        || f.selector == sig:pauseMarkets(OracleAggregator.EventId[]).selector
        || f.selector == sig:unpauseMarkets(OracleAggregator.EventId[]).selector
        || f.selector
            == sig:addReporterModules(bytes32, OracleAggregator.ModuleConfig[]).selector
        || f.selector == sig:removeReporterModules(bytes32, address[]).selector
        || f.selector
            == sig:addDisputerModules(bytes32, OracleAggregator.ModuleConfig[]).selector
        || f.selector == sig:removeDisputerModules(bytes32, address[]).selector
        || f.selector == sig:setArbitratorModule(bytes32, address, bytes).selector
        || f.selector == sig:setFinalizer(bytes32, address).selector
        || f.selector == sig:setLivenessWindow(bytes32, uint32).selector;

// The global pause toggles (`onlyAdmin`) and the role-management surface that must stay reachable
// while the oracle is paused (ORACLE-PAUSE-01's second sentence).
definition IS_PAUSE_TOGGLE(method f) returns bool =
    f.selector == sig:pauseOracle().selector || f.selector == sig:unpauseOracle().selector;

definition IS_ROLE_WRITER(method f) returns bool =
    f.selector == sig:addAdmin(address).selector
        || f.selector == sig:removeAdmin(address).selector
        || f.selector == sig:addOperator(address).selector
        || f.selector == sig:removeOperator(address).selector
        || f.selector == sig:addRuleManager(address).selector
        || f.selector == sig:removeRuleManager(address).selector;

definition IS_INITIALIZE_REQUEST(method f) returns bool =
    f.selector == sig:initializeRequest(OracleAggregator.InitParams).selector;

/*--------------------------------------------------------------
                        SCENE WIRING HELPERS
--------------------------------------------------------------*/

// Pins the request's resolution target to the recording mock, so a rule that asserts on
// `BinaryReporterTargetMock.lastResult0` is reading the numbers THIS request produced. Not a
// precondition on the aggregator's behaviour: `targetContract` is operator-chosen config, and every
// implementer in the scene is dispatched to regardless.
function requireRecordingTarget(bytes32 requestId) {
    require OracleAggregator.targetOfRequest(requestId) == BinaryReporterTargetMock,
        "scene wiring: the request reports to the recording target mock";
    // Scene hygiene, not a property assumption: the recorder counts with `reportCount = reportCount + 1`
    // (checked arithmetic), so a saturated counter makes the MOCK panic. Job 409d6f20 spent
    // `adminResolveCompletesDespiteFailingHook` on exactly that — the Prover set `reportCount` to
    // 2^256-1, the target reverted with `Panic(uint256)` (0x4e487b71), the aggregator's catch saw a
    // non-matching selector and re-reverted verbatim, which looks like the arbitrator bricking the
    // lifecycle but is only the recorder overflowing.
    require to_mathint(BinaryReporterTargetMock.reportCount()) < max_uint256,
        "scene hygiene: the recorder's report counter is not saturated";
}

// Pins the request's arbitrator to the well-behaved mock, for rules that read its own bookkeeping.
// ORACLE-ARB-01 deliberately does NOT use this: it must range over both arbitrator behaviours.
function requireWellBehavedArbitrator(bytes32 requestId) {
    require OracleAggregator.arbitratorOfRequest(requestId) == MockArbitratorModule,
        "scene wiring: the request's arbitrator is the well-behaved mock";
}

// The one visible precondition every aggregator entry point enforces: `ConditionIdLib.from`
// rejects a dirty outcome byte. Kept as an explicit require (never asserted away) so rules quantify
// over the ids the contract actually accepts.
function requireCanonicalRequestId(bytes32 requestId) {
    require OracleAggregator.isCanonicalRequestId(requestId),
        "visible precondition: canonical (outcome-byte-clear) request id";
}

// Everything `_getRequestConfigForRequestId` (OracleAggregator.sol:783-803) demands: a canonical id,
// a registered request, and the right id SHAPE for the request's market type — event-level for
// binary and atomic, any in-range subcondition for incremental neg-risk.
//
// Used ONLY by liveness rules ("this call must not revert"), which have to say when the call is
// supposed to succeed. Safety rules never require these: they assert on successful calls and let the
// Prover find a reachable state, per the family rule.
function requireResolvableRequestId(bytes32 requestId) {
    requireCanonicalRequestId(requestId);
    require OracleAggregator.targetOfRequest(requestId) != 0,
        "visible precondition: the request is registered";
    if (OracleAggregator.marketTypeOfRequest(requestId) == OracleAggregator.MarketType.INCREMENTAL_NEGRISK) {
        require OracleAggregator.conditionIndexOf(requestId) < OracleAggregator.arityOfRequest(requestId),
            "visible precondition: incremental neg-risk subcondition index in range";
    } else {
        require OracleAggregator.isValidEventIdRaw(requestId),
            "visible precondition: binary and atomic requests resolve at the event id";
    }
}

/*--------------------------------------------------------------
        RESULT VALIDITY — independent CVL restatement
--------------------------------------------------------------*/

// An independent restatement of `_validateResult`'s per-market-type bound for a SINGLETON result
// (OracleAggregator.sol:740-760). Deliberately written from the catalogue statement rather than by
// reading the production branches, so the iff rule in AggregatorResolution.spec is a real
// cross-check and not a tautology.
//
// The canonicality conjunct on the atomic branch is not decoration: that branch is the only one that
// calls `ConditionIdLib.from(_requestId)` (to read the event's arity), so it also rejects a dirty
// outcome byte, while the binary and incremental branches never look at the id at all.
// The market type is a PARAMETER, not a read of the request's config, so a rule can range over
// every type the guard could receive instead of only the one its request happens to carry.
function validSingletonResult(bytes32 requestId, OracleAggregator.MarketType marketType, uint256 value) returns bool {
    if (marketType == OracleAggregator.MarketType.ATOMIC_NEGRISK) {
        return OracleAggregator.isCanonicalRequestId(requestId)
            && to_mathint(value) < to_mathint(OracleAggregator.arityOfRequest(requestId));
    }
    if (marketType == OracleAggregator.MarketType.BINARY) {
        return to_mathint(value) <= RESULT_DENOMINATOR();
    }
    // INCREMENTAL_NEGRISK: binary payouts only, no fractional values.
    return to_mathint(value) == 0 || to_mathint(value) == RESULT_DENOMINATOR();
}
