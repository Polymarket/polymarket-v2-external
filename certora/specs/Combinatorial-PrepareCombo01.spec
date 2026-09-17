/* =============================================================================
 * [EXCHANGE-PREPARE-COMBO-01 — module-side lemmas]
 *
 * prepareCondition really binds a conditionId to its leg array, and a prepared
 * condition can never become unprepared. These lemmas are the module half of the
 * property; the Exchange half shows the entry point ties the taker's tokenId to this same conditionId.
 * ============================================================================= */

/*
 * MODULE
 * @module CombinatorialModule Conjunction Store
 * @contract CombinatorialModule
 * @impact A condition id could bind to the wrong leg set, settling a position against a different market than it was sold as
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption The combinatorial payout is summarized with an equivalent CVL model
 * PROPERTIES
 * @property COMBO-PREPARE-COMBO-01 CombinatorialModule prepareCondition binds a condition id to its leg array, and a prepared condition never becomes unprepared.
 */


using CombinatorialModuleHarness as CombinatorialModule;

methods {
    // Harness / module pure and view helpers (envfree: no msg context needed).
    function getConditionId(CombinatorialModule.PositionId[]) external returns (CombinatorialModule.ConditionId) envfree;
    function legsLength(CombinatorialModule.ConditionId) external returns (uint256) envfree;
    function legAt(CombinatorialModule.ConditionId, uint256) external returns (uint256) envfree;
    function pidUnwrap(CombinatorialModule.PositionId) external returns (uint256) envfree;
    function moduleIdOfPid(uint256) external returns (uint256) envfree;
    function outcomeOfPid(uint256) external returns (uint256) envfree;
    function condKeyOfPid(uint256) external returns (uint256) envfree;
}

definition BINARY() returns uint256 = 1;
definition NEGRISK() returns uint256 = 2;
definition MAX_LEGS() returns uint256 = 50;

/* =============================================================================
 * L1 — the returned id is exactly the id of the submitted legs
 * ============================================================================= */

/**
 * @title prepareCondition returns the id of its legs
 * @description prepareCondition returns the condition id derived from exactly the leg array it was given.
 * @link_property COMBO-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c122443faa26410380cf7c2b32c9f758?anonymousKey=3ded52b85555270000830a20b10d633829453076
 */
rule prepareConditionReturnsIdentifierOfLegs(env e) {
    CombinatorialModule.PositionId[] legsArr;

    CombinatorialModule.ConditionId expected = getConditionId(legsArr);

    CombinatorialModule.ConditionId ret = prepareCondition@withrevert(e, legsArr);
    bool ok = !lastReverted;

    assert ok => ret == expected,"prepareCondition must return getConditionId(legs) - the pure hash of the submitted legs";
    satisfy ok;
}

/* =============================================================================
 * L2 — a successful call leaves the condition prepared
 * ============================================================================= */

/**
 * @title prepareCondition prepares the condition
 * @description After a successful prepareCondition the returned condition is prepared.
 * @link_property COMBO-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c122443faa26410380cf7c2b32c9f758?anonymousKey=3ded52b85555270000830a20b10d633829453076
 */
rule prepareConditionPreparesTheCondition(env e) {
    CombinatorialModule.PositionId[] legsArr;

    CombinatorialModule.ConditionId cid = getConditionId(legsArr);

    prepareCondition@withrevert(e, legsArr);
    bool ok = !lastReverted;

    uint256 lenPost = legsLength(cid);
    assert ok => lenPost > 0, "after a successful prepareCondition the condition must be prepared";
    satisfy ok;
}

/* =============================================================================
 * L3 — fresh prepare stores exactly the submitted legs
 * ============================================================================= */

/**
 * @title a fresh condition stores exactly the legs
 * @description Preparing a fresh condition stores exactly the supplied leg array.
 * @link_property COMBO-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c122443faa26410380cf7c2b32c9f758?anonymousKey=3ded52b85555270000830a20b10d633829453076
 */
rule prepareConditionFreshStoresExactLegs(env e) {
    CombinatorialModule.PositionId[] legsArr;

    CombinatorialModule.ConditionId cid = getConditionId(legsArr);
    require legsLength(cid) == 0, "fresh case: the condition is not prepared yet";

    prepareCondition@withrevert(e, legsArr);
    bool ok = !lastReverted;

    uint256 lenPost = legsLength(cid);
    assert ok => lenPost == legsArr.length, "stored leg count must equal the submitted leg count";

    if (ok && legsArr.length > 0) {
        uint256 s0 = legAt(cid, 0);
        uint256 in0 = pidUnwrap(legsArr[0]);
        assert s0 == in0, "stored leg 0 must equal submitted leg 0";
    }
    if (ok && legsArr.length > 1) {
        uint256 s1 = legAt(cid, 1);
        uint256 in1 = pidUnwrap(legsArr[1]);
        assert s1 == in1, "stored leg 1 must equal submitted leg 1";
    }
    if (ok && legsArr.length > 2) {
        uint256 s2 = legAt(cid, 2);
        uint256 in2 = pidUnwrap(legsArr[2]);
        assert s2 == in2, "stored leg 2 must equal submitted leg 2";
    }
    satisfy ok;
}

/* =============================================================================
 * L4 — prepare on an already-prepared condition changes nothing
 * ============================================================================= */

/**
 * @title an occupied condition keeps its legs
 * @description Re-preparing an already-prepared condition leaves its stored legs unchanged.
 * @link_property COMBO-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c122443faa26410380cf7c2b32c9f758?anonymousKey=3ded52b85555270000830a20b10d633829453076
 */
rule prepareConditionOccupiedLegsUnchanged(env e) {
    CombinatorialModule.PositionId[] legsArr;

    CombinatorialModule.ConditionId cid = getConditionId(legsArr);
    uint256 lenPre = legsLength(cid);
    require lenPre > 0, "occupied case: the condition is already prepared";

    uint256 p0; uint256 p1; uint256 p2;
    if (lenPre > 0) { p0 = legAt(cid, 0); } else { p0 = 0; }
    if (lenPre > 1) { p1 = legAt(cid, 1); } else { p1 = 0; }
    if (lenPre > 2) { p2 = legAt(cid, 2); } else { p2 = 0; }

    prepareCondition@withrevert(e, legsArr);
    bool ok = !lastReverted;

    uint256 lenPost = legsLength(cid);
    assert ok => lenPost == lenPre, "an already-stored leg array must keep its length";

    if (ok && lenPre > 0) {
        uint256 q0 = legAt(cid, 0);
        assert q0 == p0, "stored leg 0 must be untouched";
    }
    if (ok && lenPre > 1) {
        uint256 q1 = legAt(cid, 1);
        assert q1 == p1, "stored leg 1 must be untouched";
    }
    if (ok && lenPre > 2) {
        uint256 q2 = legAt(cid, 2);
        assert q2 == p2, "stored leg 2 must be untouched";
    }
    satisfy ok;
}

/* =============================================================================
 * L5 — success certifies the submitted legs are canonical
 * ============================================================================= */

/**
 * @title prepareCondition accepts only canonical legs
 * @description prepareCondition rejects any leg array that is not canonical.
 * @link_property COMBO-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c122443faa26410380cf7c2b32c9f758?anonymousKey=3ded52b85555270000830a20b10d633829453076
 */
rule prepareConditionOnlyCanonicalLegs(env e) {
    CombinatorialModule.PositionId[] legsArr;

    prepareCondition@withrevert(e, legsArr);
    bool ok = !lastReverted;

    assert ok => legsArr.length >= 1, "empty leg arrays must be rejected";
    assert ok => legsArr.length <= MAX_LEGS(), "leg arrays longer than MAX_LEGS must be rejected";

    if (ok && legsArr.length > 0) {
        uint256 u0 = pidUnwrap(legsArr[0]);
        uint256 m0 = moduleIdOfPid(u0);
        uint256 o0 = outcomeOfPid(u0);
        assert m0 == BINARY() || m0 == NEGRISK(), "leg 0 must reference a binary or negrisk market";
        assert o0 <= 1, "leg 0 outcome must be YES or NO";
    }
    if (ok && legsArr.length > 1) {
        uint256 u0b = pidUnwrap(legsArr[0]);
        uint256 u1 = pidUnwrap(legsArr[1]);
        uint256 m1 = moduleIdOfPid(u1);
        uint256 o1 = outcomeOfPid(u1);
        assert m1 == BINARY() || m1 == NEGRISK(), "leg 1 must reference a binary or negrisk market";
        assert o1 <= 1, "leg 1 outcome must be YES or NO";
        assert u0b < u1, "legs must be strictly ascending (canonical order, no duplicate positionId)";
        assert condKeyOfPid(u0b) != condKeyOfPid(u1),"adjacent legs must reference distinct conditions (no ConflictingConditions)";
    }
    if (ok && legsArr.length > 2) {
        uint256 u1b = pidUnwrap(legsArr[1]);
        uint256 u2 = pidUnwrap(legsArr[2]);
        uint256 m2 = moduleIdOfPid(u2);
        uint256 o2 = outcomeOfPid(u2);
        assert m2 == BINARY() || m2 == NEGRISK(), "leg 2 must reference a binary or negrisk market";
        assert o2 <= 1, "leg 2 outcome must be YES or NO";
        assert u1b < u2, "legs must be strictly ascending (canonical order, no duplicate positionId)";
        assert condKeyOfPid(u1b) != condKeyOfPid(u2),"adjacent legs must reference distinct conditions (no ConflictingConditions)";
    }
    satisfy ok;
}

/* =============================================================================
 * L6 — once prepared, prepared forever (parametric over all module functions)
 * ============================================================================= */

/**
 * @title a prepared condition stays prepared
 * @description No entry point can make a prepared condition unprepared.
 * @link_property COMBO-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c122443faa26410380cf7c2b32c9f758?anonymousKey=3ded52b85555270000830a20b10d633829453076
 */
rule preparedConditionStaysPrepared(env e, method f, calldataarg args) filtered {
    f -> !f.isView
      && f.selector != sig:upgradeToAndCall(address,bytes).selector
} {
    CombinatorialModule.ConditionId cid;
    require legsLength(cid) > 0, "start from any prepared condition";

    f(e, args);

    uint256 lenPost = legsLength(cid);
    assert lenPost > 0, "no module function may un-prepare a condition";
}
