// ============================================================
// accesscontrol/InitializableCombinatorial.spec — ACCESS-INIT-01 for
// CombinatorialModule.
//
// Same rules as Initializable.spec; the only difference is the scene
// requirement: any scene containing CombinatorialModule must import
// CTFHelpers_summaries.spec
// ============================================================

/*
 * MODULE
 * @module Initialization Access Control
 * @contract All initializable contracts (9)
 * @impact An initialized contract or a bare implementation could be re-initialized, letting an attacker take ownership
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * @global_assumption The legacy condition-id helpers are replaced by CVL models or over-approximated
 */

import "./Initializable.spec";
import "../summaries/CTFHelpers_summaries.spec";

/**
 * @title initialized version moves only fresh to one, CombinatorialModule
 * @description The initialized version is frozen once non-zero, and the only transition any method can perform is 0 to 1.
 * @link_property ACCESS-INIT-01
 * @assumption multicall is excluded because delegatecall-to-self runs the same code on the same storage, making it equivalent to a sequence of direct calls
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/288a8bdcc75c4f56892f062a7caab2bb?anonymousKey=7242a4b0a2daaf19a34abd63b74f7afceb75c652
 */
use rule initVersionMovesOnlyFreshToOne;

/**
 * @title initialize requires a fresh state, CombinatorialModule
 * @description initialize succeeds only from the fresh state and lands at exactly version 1.
 * @link_property ACCESS-INIT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/288a8bdcc75c4f56892f062a7caab2bb?anonymousKey=7242a4b0a2daaf19a34abd63b74f7afceb75c652
 */
use rule initializeRequiresFresh;

/**
 * @title initialize succeeds at most once, CombinatorialModule
 * @description After a successful initialize, every further initialize reverts.
 * @link_property ACCESS-INIT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/288a8bdcc75c4f56892f062a7caab2bb?anonymousKey=7242a4b0a2daaf19a34abd63b74f7afceb75c652
 */
use rule initializeSucceedsAtMostOnce;
