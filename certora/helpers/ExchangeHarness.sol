// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Exchange, MatchContext, TakerAmounts } from "@polymarket-v2/src/exchange/Exchange.sol";
import { Order } from "@polymarket-v2/src/exchange/OrderStructs.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
// Re-imported so CVL can resolve `ExchangeHarness.ConditionId` / `.PositionId` (the `_merge` /
// `_split` summaries and any UDVT-typed references in the spec resolve through the harness alias).
import { ConditionId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title ExchangeHarness
/// @notice Certora harness exposing the Exchange's internal batch-match executors as external
///         entry points so CVL rules can drive them directly.
contract ExchangeHarness is Exchange {
    constructor(
        address _positionManager,
        address _combinatorialModule,
        address _feeReceiver,
        uint256 _maxFeeRate,
        address _proxyFactory,
        address _safeFactory,
        bytes32 _proxyBytecodeHash,
        bytes32 _safeBytecodeHash
    )
        Exchange(
            _positionManager,
            _combinatorialModule,
            _feeReceiver,
            _maxFeeRate,
            _proxyFactory,
            _safeFactory,
            _proxyBytecodeHash,
            _safeBytecodeHash
        )
    { }

    /// @notice Drives the batch BUY executor with a faithfully-reconstructed MatchContext. 
    /// @dev ctx is built exactly as `_matchOrders` builds it; `moduleAddr` is supplied so the
    ///      `moduleById` lookup is never executed — the rule constrains it to a registered module
    ///      (moduleGuard), mirroring what `moduleById` returns by construction.
    function h_executeBatchBuyMatch(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata makerFeeAmounts,
        TakerAmounts calldata takerAmounts,
        address moduleAddr
    ) external returns (uint256 takerMakingAmount, uint256 takerTakingAmount) {
        MatchContext memory ctx = MatchContext({
            takerFillAmount: takerAmounts.takerFillAmount,
            takerFee: takerAmounts.takerFeeAmount,
            takerAddr: takerOrder.maker,
            moduleAddr: moduleAddr,
            takerTokenId: takerOrder.tokenId,
            takerReceiveAmount: takerAmounts.takerReceiveAmount
        });
        return _executeBatchBuyMatch(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
    }

    /// @notice Drives the batch SELL executor with a faithfully-reconstructed MatchContext.
    function h_executeBatchSellMatch(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata makerFeeAmounts,
        TakerAmounts calldata takerAmounts,
        address moduleAddr
    ) external returns (uint256 takerTakingAmount) {
        MatchContext memory ctx = MatchContext({
            takerFillAmount: takerAmounts.takerFillAmount,
            takerFee: takerAmounts.takerFeeAmount,
            takerAddr: takerOrder.maker,
            moduleAddr: moduleAddr,
            takerTokenId: takerOrder.tokenId,
            takerReceiveAmount: takerAmounts.takerReceiveAmount
        });
        return _executeBatchSellMatch(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
    }

    function h_executeComplementaryBuyFastPath(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata makerFeeAmounts,
        TakerAmounts calldata takerAmounts
    ) external returns (uint256, uint256, uint256) {
        MatchContext memory ctx = MatchContext({
            takerFillAmount: takerAmounts.takerFillAmount,
            takerFee: takerAmounts.takerFeeAmount,
            takerAddr: takerOrder.maker,
            moduleAddr: address(0),
            takerTokenId: takerOrder.tokenId,
            takerReceiveAmount: takerAmounts.takerReceiveAmount
        });
        return _executeComplementaryBuyFastPath(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
    }

    function h_executeComplementarySellFastPath(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata makerFeeAmounts,
        TakerAmounts calldata takerAmounts
    ) external returns (uint256, uint256, uint256) {
        MatchContext memory ctx = MatchContext({
            takerFillAmount: takerAmounts.takerFillAmount,
            takerFee: takerAmounts.takerFeeAmount,
            takerAddr: takerOrder.maker,
            moduleAddr: address(0),
            takerTokenId: takerOrder.tokenId,
            takerReceiveAmount: takerAmounts.takerReceiveAmount
        });
        return _executeComplementarySellFastPath(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
    }

    function h_executeComplementaryZeroFeeSellFastPath(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        TakerAmounts calldata takerAmounts
    ) external returns (uint256, uint256) {
        MatchContext memory ctx = MatchContext({
            takerFillAmount: takerAmounts.takerFillAmount,
            takerFee: takerAmounts.takerFeeAmount,
            takerAddr: takerOrder.maker,
            moduleAddr: address(0),
            takerTokenId: takerOrder.tokenId,
            takerReceiveAmount: takerAmounts.takerReceiveAmount
        });
        return _executeComplementaryZeroFeeSellFastPath(takerOrder, makerOrders, makerFillAmounts, ctx);
    }

    /// @notice Drives the FULL complementary wrapper (not just a fast path), so the
    ///         taker -> FEE_RECEIVER fee transfer that lives in `_matchComplementaryOrders`
    ///         actually executes. WHY: the fast-path executors never route pUSD through the
    ///         Exchange or the fee receiver, so a fast-path-only rule cannot observe fee
    ///         routing. Driving the wrapper makes the fee-receiver delta a real, falsifiable
    ///         check. ctx is rebuilt exactly as `_matchOrders` builds it (moduleAddr unused on
    ///         the complementary paths).
    function h_matchComplementaryOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata makerFeeAmounts,
        TakerAmounts calldata takerAmounts
    ) external {
        MatchContext memory ctx = MatchContext({
            takerFillAmount: takerAmounts.takerFillAmount,
            takerFee: takerAmounts.takerFeeAmount,
            takerAddr: takerOrder.maker,
            moduleAddr: address(0),
            takerTokenId: takerOrder.tokenId,
            takerReceiveAmount: takerAmounts.takerReceiveAmount
        });
        _matchComplementaryOrders(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
    }

    /*--------------------------------------------------------------
        PREPARE+BIND PREFIX WRAPPER  (for [EXCHANGE-PREPARE-COMBO-01])
    --------------------------------------------------------------*/

    /// @notice Verbatim copy of the prepare+bind prefix of matchOrdersAndPrepareCombinatorial
    ///         (Exchange.sol:570-571): the real linked prepareCondition call plus the real
    ///         InvalidTokenId binding check, without the trailing `_matchOrders`.
    /// @dev WHY: inside the full public entry the Prover cannot recover the selector at the
    ///      prepareCondition call site (assembly saturation, see the header above) and
    ///      AUTO-havocs it even when the CombinatorialModule is linked. This 2-statement wrapper
    ///      sits below the saturation so the call resolves to the real module. Sound decompositions, as
    //       the public entry is exactly [these two statements] ; _matchOrders,
    ///      and _matchOrders cannot un-prepare a condition (proven parametrically in
    ///      PrepareCombo01-CombinatorialModule.spec, rule preparedConditionStaysPrepared).
    function h_prepareAndBindCombinatorial(Order calldata takerOrder, PositionId[] calldata combinatorialLegs)
        external
    {
        ConditionId conditionId = CombinatorialModule(COMBINATORIAL_MODULE).prepareCondition(combinatorialLegs);
        require(conditionId == takerOrder.tokenId.conditionId(), InvalidTokenId());
    }

    /*--------------------------------------------------------------
        ORDER-STATUS WRAPPERS  (for [ORDER-FILL-MONOTONE-01])
    --------------------------------------------------------------*/

    /// @notice Drives the maker-path validate+store choke-point directly.
    /// @dev Runs the REAL guards (`_validateOrder`: filled-latch, fill<=remaining, first-fill
    ///      substitution) and the REAL packed store (`_storeOrderStatus`). This is the exact code
    ///      that mutates `orderStatus` on every maker fill, isolated from the assembly-saturated
    ///      match dispatch. Returns the order hash so the rule can read the same slot back.
    function h_validateAndUpdate(Order calldata order, uint256 fillAmount, uint256 fee)
        external
        returns (bytes32)
    {
        return _validateAndUpdate(order, fillAmount, fee);
    }

    /// @notice Drives the complementary-taker store path directly.
    /// @dev `_updateOrderStatus` does NOT itself re-check the filled latch (unlike `_validateOrder`);
    ///      in production the earlier `_validateOrder(takerHash, ...)` in the same match gates it.
    ///      Exposed separately so a rule can confirm monotonicity of THIS path in isolation.
    function h_updateOrderStatus(Order calldata order, uint256 fillAmount) external {
        _updateOrderStatus(_hashOrder(order), order, fillAmount);
    }

    /// @notice Drives the packed store in isolation, so a rule can prove the
    ///         `filled <=> remaining == 0` encoding without trusting the assembly.
    function h_storeOrderStatus(bytes32 orderHash, uint256 remaining) external {
        _storeOrderStatus(orderHash, remaining);
    }

    /// @notice Exposes the internal order hash so a rule can key `orderStatus` reads to the same
    ///         slot the fill paths write. Under the CVL `_hashOrder => CONSTANT` summary this is a
    ///         single fixed key, matching the slot every wrapper above mutates.
    function h_hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashOrder(order);
    }

    /*--------------------------------------------------------------
        SIGNATURE WRAPPERS  (for [EXCHANGE-SIG-01b])
    --------------------------------------------------------------*/

    /// @notice Exposes the internal signature verifier so binding rules run the REAL
    ///         per-signatureType code (Sig01a ghosts this same function at the fill paths).
    function h_isValidSignature(bytes32 orderHash, Order calldata order) external view returns (bool) {
        return _isValidSignature(orderHash, order);
    }

    /// @notice Exposes the preapproval-vs-signature dispatch gate (reverts on failure).
    function h_validateSignature(bytes32 orderHash, Order calldata order) external view {
        _validateSignature(orderHash, order);
    }

    /*--------------------------------------------------------------
                        SUMMARY REGRESSION PROBES
    --------------------------------------------------------------*/
    // Regression guard for Exchange-TakerCredit01. probe3 is the load-bearing one: it went
    // VIOLATED -> VERIFIED the moment the inert `_.unsafeTransferFrom(address, address,
    // uint256, uint256)` wildcard was replaced with the explicit-contract + PositionId form.
    // If probe3 ever goes red again, a summary has stopped applying.

    /// @notice Probe 1: bare unchecked accumulator over a calldata array. Nothing else.
    function h_probeSumOnly(uint256[] calldata fills) external pure returns (uint256 acc) {
        for (uint256 i; i < fills.length; ++i) {
            unchecked {
                acc += fills[i];
            }
        }
    }

    /// @notice Probe 2: probe 1 plus Order[] calldata indexing and the real taking-amount math.
    function h_probeSumWithCalc(Order[] calldata makerOrders, uint256[] calldata fills)
        external
        pure
        returns (uint256 acc, uint256 mk)
    {
        for (uint256 i; i < makerOrders.length; ++i) {
            Order calldata m = makerOrders[i];
            uint256 fill = fills[i];
            uint256 taking = _calculateTakingAmount(fill, m.makerAmount, m.takerAmount);
            unchecked {
                acc += fill;
                mk += taking;
            }
        }
    }

    /// @notice Probe 3: probe 2 plus the in-loop external position-token transfer.
    function h_probeSumWithTransfer(Order[] calldata makerOrders, uint256[] calldata fills, PositionId tokenId)
        external
        returns (uint256 acc, uint256 mk)
    {
        for (uint256 i; i < makerOrders.length; ++i) {
            Order calldata m = makerOrders[i];
            uint256 fill = fills[i];
            uint256 taking = _calculateTakingAmount(fill, m.makerAmount, m.takerAmount);
            POSITION_MANAGER.unsafeTransferFrom(msg.sender, m.maker, tokenId, taking);
            unchecked {
                acc += fill;
                mk += taking;
            }
        }
    }
}
