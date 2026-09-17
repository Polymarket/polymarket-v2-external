// ============================================================
// accesscontrol/Initializable.spec — ACCESS-INIT-01
//
// Initializers run exactly once, and implementations are
// permanently non-initializable.
//
// Generic, contract-agnostic spec: every initializable production contract
// uses Solady's Initializable, whose entire state lives in ONE constant slot
//   bytes32(~uint256(uint32(bytes4(keccak256("_INITIALIZABLE_SLOT")))))
//   = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffbf601132
// packed as [bit 0: initializing | bits 1..64: initializedVersion].
// ============================================================

/*
 * MODULE
 * @module Initialization Access Control
 * @contract All initializable contracts (9)
 * @impact An initialized contract or a bare implementation could be re-initialized, letting an attacker take ownership
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * @global_assumption The legacy condition-id helpers are replaced by CVL models or over-approximated
 * PROPERTIES
 * @property ACCESS-INIT-01 Initializers run exactly once and implementations are permanently non-initializable, for each of PositionManager, CollateralToken, Exchange, OracleAggregator, OOReporterModule, BinaryModule, NegRiskModule, CombinatorialModule and CcipBridge.
 */

import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";
import "../summaries/Solady/SafeTransferLib.spec";
import "../summaries/CTFHelpers_summaries.spec";

methods {
    // Harness view over Solady's internal _getInitializedVersion().
    function initializedVersion() external returns (uint64) envfree;

    // ---- OwnableRoles ghost model ----
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
}

// ------------------------------------------------------------
// Rules
// ------------------------------------------------------------

// Excluding multicall loses no coverage: delegatecall-to-self runs the same 
// code on the same storage, so anything multicall can do equals a sequence 
// of direct calls to the contract's own methods
definition MULTICALL_SELECTOR() returns uint32 = 0xac9650d8;

/**
 * @title initialized version moves only fresh to one
 * @description The initialized version is frozen once non-zero, and the only transition any method can perform is 0 to 1.
 * @link_property ACCESS-INIT-01
 * @assumption multicall is excluded because delegatecall-to-self runs the same code on the same storage, making it equivalent to a sequence of direct calls
 * @status VERIFIED
 * @report Initializable_BinaryModule https://prover.certora.com/output/10505052/369013ab45b4416cb06d947f376047e1?anonymousKey=c293456b94af4aad542230ad64c73dc5bb4adf5a
 * @report Initializable_CcipBridge https://prover.certora.com/output/10505052/cfc3c346ef7f4693b26c9f99b1809fcb?anonymousKey=023429b5ded3576f39a8b180629dbef06a3f65df
 * @report Initializable_CollateralToken https://prover.certora.com/output/10505052/faba7a8d72d943449ec37066b6edf883?anonymousKey=2bd0a40b040bcb38547913ba109fd68fad8e94f2
 * @report Initializable_Exchange https://prover.certora.com/output/10505052/c0f4e085ad764abfabd4b0ae34c76d1d?anonymousKey=56f6a343ec34eda327b059aad453b232e944a084
 * @report Initializable_NegRiskModule https://prover.certora.com/output/10505052/4df974dbe6c54a2f835cc3c4391cad46?anonymousKey=99074330af0f1cbc94f2cd922e14ee3832056b06
 * @report Initializable_OOReporterModule https://prover.certora.com/output/10505052/a0728c3cd12240859eff475ca986cfb5?anonymousKey=d7d6ec48534cc5fdafad89993d869bcc3cfb5d03
 * @report Initializable_OracleAggregator https://prover.certora.com/output/10505052/8b95c338a44b45ca82c77e872fb4238b?anonymousKey=a06d2d0a4029e3e3c222ca71df789f94bef23321
 * @report Initializable_PositionManager https://prover.certora.com/output/10505052/8f042d1528054dea9008ea1891030144?anonymousKey=cef3f501d926ffb6b29e090ff7431826d03a7b49
 */
rule initVersionMovesOnlyFreshToOne(env e, method f, calldataarg args)
filtered { f -> !f.isView && f.selector != MULTICALL_SELECTOR() } {
    mathint versionBefore = initializedVersion();

    f(e, args);

    mathint versionAfter = initializedVersion();
    assert versionBefore != 0 => versionAfter == versionBefore,
        "a method changed the initialized version after initialization or disabling";
    assert versionAfter != versionBefore => (versionBefore == 0 && versionAfter == 1),
        "a method performed an initialization transition other than fresh -> version 1";
}

/**
 * @title initialize requires a fresh state
 * @description initialize succeeds only from the fresh state and lands at exactly version 1.
 * @link_property ACCESS-INIT-01
 * @status VERIFIED
 * @report Initializable_BinaryModule https://prover.certora.com/output/10505052/369013ab45b4416cb06d947f376047e1?anonymousKey=c293456b94af4aad542230ad64c73dc5bb4adf5a
 * @report Initializable_CcipBridge https://prover.certora.com/output/10505052/cfc3c346ef7f4693b26c9f99b1809fcb?anonymousKey=023429b5ded3576f39a8b180629dbef06a3f65df
 * @report Initializable_CollateralToken https://prover.certora.com/output/10505052/faba7a8d72d943449ec37066b6edf883?anonymousKey=2bd0a40b040bcb38547913ba109fd68fad8e94f2
 * @report Initializable_Exchange https://prover.certora.com/output/10505052/c0f4e085ad764abfabd4b0ae34c76d1d?anonymousKey=56f6a343ec34eda327b059aad453b232e944a084
 * @report Initializable_NegRiskModule https://prover.certora.com/output/10505052/4df974dbe6c54a2f835cc3c4391cad46?anonymousKey=99074330af0f1cbc94f2cd922e14ee3832056b06
 * @report Initializable_OOReporterModule https://prover.certora.com/output/10505052/a0728c3cd12240859eff475ca986cfb5?anonymousKey=d7d6ec48534cc5fdafad89993d869bcc3cfb5d03
 * @report Initializable_OracleAggregator https://prover.certora.com/output/10505052/8b95c338a44b45ca82c77e872fb4238b?anonymousKey=a06d2d0a4029e3e3c222ca71df789f94bef23321
 * @report Initializable_PositionManager https://prover.certora.com/output/10505052/8f042d1528054dea9008ea1891030144?anonymousKey=cef3f501d926ffb6b29e090ff7431826d03a7b49
 */
rule initializeRequiresFresh(env e, calldataarg a) {
    mathint versionBefore = initializedVersion();

    initialize@withrevert(e, a);
    bool reverted = lastReverted;

    assert !reverted => versionBefore == 0,
        "initialize succeeded from an already-initialized or disabled state";
    assert !reverted => initializedVersion() == 1,
        "initialize left a version other than 1";

    satisfy !reverted;
}

/**
 * @title initialize succeeds at most once
 * @description After a successful initialize, every further initialize reverts.
 * @link_property ACCESS-INIT-01
 * @status VERIFIED
 * @report Initializable_BinaryModule https://prover.certora.com/output/10505052/369013ab45b4416cb06d947f376047e1?anonymousKey=c293456b94af4aad542230ad64c73dc5bb4adf5a
 * @report Initializable_CcipBridge https://prover.certora.com/output/10505052/cfc3c346ef7f4693b26c9f99b1809fcb?anonymousKey=023429b5ded3576f39a8b180629dbef06a3f65df
 * @report Initializable_CollateralToken https://prover.certora.com/output/10505052/faba7a8d72d943449ec37066b6edf883?anonymousKey=2bd0a40b040bcb38547913ba109fd68fad8e94f2
 * @report Initializable_Exchange https://prover.certora.com/output/10505052/c0f4e085ad764abfabd4b0ae34c76d1d?anonymousKey=56f6a343ec34eda327b059aad453b232e944a084
 * @report Initializable_NegRiskModule https://prover.certora.com/output/10505052/4df974dbe6c54a2f835cc3c4391cad46?anonymousKey=99074330af0f1cbc94f2cd922e14ee3832056b06
 * @report Initializable_OOReporterModule https://prover.certora.com/output/10505052/a0728c3cd12240859eff475ca986cfb5?anonymousKey=d7d6ec48534cc5fdafad89993d869bcc3cfb5d03
 * @report Initializable_OracleAggregator https://prover.certora.com/output/10505052/8b95c338a44b45ca82c77e872fb4238b?anonymousKey=a06d2d0a4029e3e3c222ca71df789f94bef23321
 * @report Initializable_PositionManager https://prover.certora.com/output/10505052/8f042d1528054dea9008ea1891030144?anonymousKey=cef3f501d926ffb6b29e090ff7431826d03a7b49
 */
rule initializeSucceedsAtMostOnce(env e1, env e2, calldataarg a1, calldataarg a2) {
    initialize(e1, a1);

    initialize@withrevert(e2, a2);

    assert lastReverted, "initialize succeeded twice";
}
