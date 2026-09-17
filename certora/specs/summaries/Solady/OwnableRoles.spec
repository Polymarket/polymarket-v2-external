// ============================================================
// OwnableRoles.spec — Solady OwnableRoles ghost model + summaries
//
// Solady's OwnableRoles stores per-user role bitmaps behind a keccak256
// slot computed in inline assembly (the `_ROLE_SLOT_SEED` pattern). That
// computation breaks CVL's points-to / storage analysis, producing the
// "Storage analysis / Storage splitting / Pointer analysis failed" alerts
// the AutoSetup completeness report flags across OwnableRoles functions.
//
// We replace the role bitmap with five boolean ghosts per user — one per
// role bit — and intercept EVERY function that reads or writes it, so the
// ghost is the single source of truth for both the public views and the
// `onlyRoles` modifier:
//
//   Reads:
//     * hasAnyRole  -> hasAnyRoleCVL   (bool, avoids `& roles` bitvector op)
//     * hasAllRoles -> hasAllRolesCVL  (bool)
//     * _checkRoles -> checkRolesCVL   (modifier guard; reverts via ghost)
//   Writes:
//     * _setRoles   -> setRolesCVL     (overwrite)
//     * _updateRoles-> updateRolesCVL  (grant/revoke bits)
//
// Per-contract ghost keying
// -------------------------
// All ghosts carry an extra leading `address contract_` key so that
// multiple contracts inheriting OwnableRoles in the same verification run
// (e.g. CollateralToken + PositionManager) never share ghost state. Every
// methods-block entry passes `currentContract` as the first argument, which
// CVL resolves to the actual contract instance being summarized. As a
// consequence, each consuming spec that wants contract-specific wiring must
// re-declare the summary entries explicitly (rather than relying on the
// wildcard alone) so the correct `currentContract` is bound.
//
// Role maps (Solady _ROLE_N = 1 << N):
//
//   CollateralToken (src/collateral/CollateralToken.sol):
//     MINTER_ROLE  = _ROLE_0 = bit 0 = 1   (mint, burn)
//     WRAPPER_ROLE = _ROLE_1 = bit 1 = 2   (wrap, unwrap)
//
//   PositionManager (src/auth/InitializableRoles.sol):
//     ADMIN_ROLE    = _ROLE_0 = bit 0 = 1
//     OPERATOR_ROLE = _ROLE_1 = bit 1 = 2
//     CREATOR_ROLE  = _ROLE_2 = bit 2 = 4
//     BRIDGE_ROLE   = _ROLE_3 = bit 3 = 8
//     RESOLVER_ROLE = _ROLE_4 = bit 4 = 16
//
// `_checkRoles(uint256 roles)` checks `caller()` and has no `user` param, so
// it is summarized with `with (env e)`, which hands the summary the calling
// environment and lets it read `e.msg.sender`. This is what makes the
// modifier consult the ghost: granting a role (addAdmin -> _updateRoles ->
// ghost) and then calling a guarded method (-> _checkRoles -> same ghost)
// now stay consistent.
//
// `rolesOf` is summarized via `rolesOfCVL` (external) for direct calls from spec
// rules. Internal callers are already cut by the hasAnyRole/hasAllRoles summaries.
//
// `ownershipHandoverExpiresAt` reads the pending-handover expiry timestamp from a
// keccak256-derived slot (_HANDOVER_SLOT_SEED). Modeled with ghostHandoverExpiry.
// If rules exercise requestOwnershipHandover / cancelOwnershipHandover /
// completeOwnershipHandover, those must be summarized too so the ghost stays in sync.
//
// No methods block here — each consuming spec declares its own using the explicit
// contract name (e.g. `CollateralToken.hasAnyRole`) rather than a wildcard, so
// only the intended contracts are intercepted per run.
// ============================================================

// ------------------------------------------------------------
// Ghost model
// ------------------------------------------------------------

// ghostHasRoleN[contract_][user] — whether `user` holds role bit N in `contract_`.
// Keyed by contract address to isolate state across multiple OwnableRoles inheritors
// verified in the same run.
//
// ghostHasRole0 — _ROLE_0 = 1:  MINTER_ROLE (CollateralToken) / ADMIN_ROLE    (PositionManager)
// ghostHasRole1 — _ROLE_1 = 2:  WRAPPER_ROLE (CollateralToken) / OPERATOR_ROLE (PositionManager)
// ghostHasRole2 — _ROLE_2 = 4:  CREATOR_ROLE  (PositionManager)
// ghostHasRole3 — _ROLE_3 = 8:  BRIDGE_ROLE   (PositionManager)
// ghostHasRole4 — _ROLE_4 = 16: RESOLVER_ROLE (PositionManager)
ghost mapping(address => mapping(address => bool)) ghostHasRole0;
ghost mapping(address => mapping(address => bool)) ghostHasRole1;
ghost mapping(address => mapping(address => bool)) ghostHasRole2;
ghost mapping(address => mapping(address => bool)) ghostHasRole3;
ghost mapping(address => mapping(address => bool)) ghostHasRole4;

// ghostHandoverExpiry[contract_][pendingOwner] — expiry timestamp set by requestOwnershipHandover.
ghost mapping(address => mapping(address => uint256)) ghostHandoverExpiry;

// ------------------------------------------------------------
// Bit-check helpers
// ------------------------------------------------------------

// Extract individual role bits from a bitmask using integer division + modulo,
// avoiding bitwise-AND which would pull in bitvector theory.
// Bit N is set iff (roles / 2^N) % 2 != 0.
function hasBit0(uint256 roles) returns bool { return roles      % 2 != 0; }
function hasBit1(uint256 roles) returns bool { return roles / 2  % 2 != 0; }
function hasBit2(uint256 roles) returns bool { return roles / 4  % 2 != 0; }
function hasBit3(uint256 roles) returns bool { return roles / 8  % 2 != 0; }
function hasBit4(uint256 roles) returns bool { return roles / 16 % 2 != 0; }

// hasAnyRole: true iff `user` holds at least one bit of `roles` in `contract_`.
function hasAnyRoleCVL(address contract_, address user, uint256 roles) returns bool {
    bool r0 = hasBit0(roles) && ghostHasRole0[contract_][user];
    bool r1 = hasBit1(roles) && ghostHasRole1[contract_][user];
    bool r2 = hasBit2(roles) && ghostHasRole2[contract_][user];
    bool r3 = hasBit3(roles) && ghostHasRole3[contract_][user];
    bool r4 = hasBit4(roles) && ghostHasRole4[contract_][user];

    return r0 || r1 || r2 || r3 || r4;
}

// hasAllRoles: true iff `user` holds every bit of `roles` in `contract_`.
function hasAllRolesCVL(address contract_, address user, uint256 roles) returns bool {
    bool r0 = !hasBit0(roles) || ghostHasRole0[contract_][user];
    bool r1 = !hasBit1(roles) || ghostHasRole1[contract_][user];
    bool r2 = !hasBit2(roles) || ghostHasRole2[contract_][user];
    bool r3 = !hasBit3(roles) || ghostHasRole3[contract_][user];
    bool r4 = !hasBit4(roles) || ghostHasRole4[contract_][user];
    if (roles > 31) {
        return false;
    }
    return r0 && r1 && r2 && r3 && r4;
}

// _checkRoles: Solady reverts with `Unauthorized()` when the intersection of
// the caller's roles and `roles` is empty. Mirror that against the ghost.
function checkRolesCVL(env e, address contract_, uint256 roles) {
    if (!hasAnyRoleCVL(contract_, e.msg.sender, roles)) {
        revert();
    }
}

// _setRoles: overwrite the entire role bitmap for `user` in `contract_`.
function setRolesCVL(address contract_, address user, uint256 roles) {
    ghostHasRole0[contract_][user] = hasBit0(roles);
    ghostHasRole1[contract_][user] = hasBit1(roles);
    ghostHasRole2[contract_][user] = hasBit2(roles);
    ghostHasRole3[contract_][user] = hasBit3(roles);
    ghostHasRole4[contract_][user] = hasBit4(roles);
}

// _updateRoles: grant (on=true) or revoke (on=false) specific role bits in `contract_`.
function updateRolesCVL(address contract_, address user, uint256 roles, bool on) {
    if (hasBit0(roles)) { ghostHasRole0[contract_][user] = on; }
    if (hasBit1(roles)) { ghostHasRole1[contract_][user] = on; }
    if (hasBit2(roles)) { ghostHasRole2[contract_][user] = on; }
    if (hasBit3(roles)) { ghostHasRole3[contract_][user] = on; }
    if (hasBit4(roles)) { ghostHasRole4[contract_][user] = on; }
}

// rolesOf: reconstruct the role bitmap for `user` in `contract_` from the ghost booleans.
// Uses integer addition instead of bitwise-OR to avoid bitvector theory.
// Inverse of the hasBitN helpers: each ghost contributes its 2^N weight.
function rolesOfCVL(address contract_, address user) returns uint256 {
    uint256 roles0 = 0;
    uint256 roles1 = 0;
    uint256 roles2 = 0;
    uint256 roles3 = 0;
    uint256 roles4 = 0;

    if (ghostHasRole0[contract_][user]) { roles0 = 1;  }
    if (ghostHasRole1[contract_][user]) { roles1 = 2;  }
    if (ghostHasRole2[contract_][user]) { roles2 = 4;  }
    if (ghostHasRole3[contract_][user]) { roles3 = 8;  }
    if (ghostHasRole4[contract_][user]) { roles4 = 16; }

    // Require is safe because the max value is capped at 31
    return require_uint256(roles0 + roles1 + roles2 + roles3 + roles4);
}

// ownershipHandoverExpiresAt: read the pending-handover expiry for `pendingOwner` in `contract_`.
function ownershipHandoverExpiresAtCVL(address contract_, address pendingOwner) returns uint256 {
    return ghostHandoverExpiry[contract_][pendingOwner];
}
