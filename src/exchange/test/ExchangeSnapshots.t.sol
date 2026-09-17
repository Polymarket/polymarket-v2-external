// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Test } from "lib/forge-std/src/Test.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { Positions, PositionManagerSetup } from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { Router } from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

import { Exchange, TakerAmounts } from "@polymarket-v2/src/exchange/Exchange.sol";
import { Order, Side, SignatureType } from "@polymarket-v2/src/exchange/OrderStructs.sol";
import { MockProxyFactory } from "./mocks/MockProxyFactory.sol";
import { MockSafeFactory } from "./mocks/MockSafeFactory.sol";

/// @notice Gas snapshot tests for matchOrders
/// @dev Run with: forge test --match-contract ExchangeSnapshotsTest --gas-report
/// @dev Snapshots are written to snapshots/ExchangeSnapshotsTest.json
contract ExchangeSnapshotsTest is Test {
    Collateral collateral;
    Positions positions;
    Exchange exchange;
    Router router;

    address owner;
    address admin;
    address creator;
    address oracle;
    address operator;
    address feeReceiver;

    // Wallets for signing (matches ctf-exchange-v2: bob = taker, carla = maker)
    uint256 internal bobPK = 0xB0B;
    uint256 internal carlaPK = 0xCA414;
    address public bob;
    address public carla;
    MockProxyFactory public proxyFactory;
    MockSafeFactory public safeFactory;

    bytes32 conditionId;
    uint256 yes;
    uint256 no;

    function setUp() public virtual {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        creator = makeAddr("creator");
        oracle = makeAddr("oracle");
        operator = makeAddr("operator");
        feeReceiver = makeAddr("feeReceiver");

        bob = vm.addr(bobPK);
        vm.label(bob, "bob");
        carla = vm.addr(carlaPK);
        vm.label(carla, "carla");

        proxyFactory = new MockProxyFactory();
        safeFactory = new MockSafeFactory();
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);

        // forgefmt: disable-next-item
        address exchangeImplementation = address(new Exchange(
            address(positions.manager),
            address(0),
            feeReceiver,
            1000,
            address(proxyFactory),
            address(safeFactory),
            proxyFactory.bytecodeHash(),
            safeFactory.bytecodeHash()
        ));
        address exchangeProxy = LibClone.deployERC1967(exchangeImplementation);
        exchange = Exchange(exchangeProxy);
        exchange.initialize(owner, admin);

        // Deploy router for splitting
        router = RouterSetup.deployRouter(address(positions.manager), owner);

        // Setup roles
        vm.startPrank(admin);
        exchange.addOperator(operator);
        vm.stopPrank();

        // Create a binary market condition
        ConditionId cid = positions.binaryModule.getConditionId("test question");
        conditionId = bytes32(ConditionId.unwrap(cid));

        // Grant resolver role to oracle
        vm.prank(admin);
        positions.binaryModule.addResolver(oracle);

        // Get position IDs
        yes = PositionId.unwrap(ConditionIdLib.computePositionId(cid, 0));
        no = PositionId.unwrap(ConditionIdLib.computePositionId(cid, 1));
    }

    /*--------------------------------------------------------------
                             SETUP HELPERS
    --------------------------------------------------------------*/

    function _prepareComplementary(uint256 numMakers)
        internal
        returns (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        )
    {
        uint256 usdcPerMaker = 10_000_000;
        uint256 tokensPerMaker = 20_000_000;
        uint256 totalUsdc = usdcPerMaker * numMakers;
        uint256 totalTokens = tokensPerMaker * numMakers;

        dealCollateralAndApprove(bob, address(exchange), totalUsdc);

        takerOrder = _createAndSignOrder(bobPK, yes, totalUsdc, totalTokens, Side.BUY);
        makerOrders = new Order[](numMakers);
        fillAmounts = new uint256[](numMakers);
        feeAmounts = new uint256[](numMakers);

        for (uint256 i = 0; i < numMakers; i++) {
            uint256 makerPk = _makerPk(1, i, numMakers);
            address maker = vm.addr(makerPk);
            dealOutcomeTokensAndApprove(maker, address(exchange), tokensPerMaker);
            makerOrders[i] = _createAndSignOrderWithSalt(makerPk, yes, tokensPerMaker, usdcPerMaker, Side.SELL, i + 100);
            fillAmounts[i] = tokensPerMaker;
            feeAmounts[i] = 0;
        }

        takerFillAmount = totalUsdc;
    }

    function _prepareMint(uint256 numMakers)
        internal
        returns (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        )
    {
        uint256 usdcPerMaker = 10_000_000;
        uint256 tokensPerMaker = 20_000_000;
        uint256 totalTokens = tokensPerMaker * numMakers;
        uint256 takerUsdc = totalTokens / 2;

        dealCollateralAndApprove(bob, address(exchange), takerUsdc);

        takerOrder = _createAndSignOrder(bobPK, yes, takerUsdc, totalTokens, Side.BUY);
        makerOrders = new Order[](numMakers);
        fillAmounts = new uint256[](numMakers);
        feeAmounts = new uint256[](numMakers);

        for (uint256 i = 0; i < numMakers; i++) {
            uint256 makerPk = _makerPk(2, i, numMakers);
            address maker = vm.addr(makerPk);
            dealCollateralAndApprove(maker, address(exchange), usdcPerMaker);
            makerOrders[i] = _createAndSignOrderWithSalt(makerPk, no, usdcPerMaker, tokensPerMaker, Side.BUY, i + 100);
            fillAmounts[i] = usdcPerMaker;
            feeAmounts[i] = 0;
        }

        takerFillAmount = takerUsdc;
    }

    function _prepareComplementarySell(uint256 numMakers)
        internal
        returns (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        )
    {
        uint256 tokensPerMaker = 20_000_000;
        uint256 usdcPerMaker = 10_000_000;
        uint256 totalTokens = tokensPerMaker * numMakers;
        uint256 totalUsdc = usdcPerMaker * numMakers;

        dealOutcomeTokensAndApprove(bob, address(exchange), totalTokens);

        takerOrder = _createAndSignOrder(bobPK, yes, totalTokens, totalUsdc, Side.SELL);
        makerOrders = new Order[](numMakers);
        fillAmounts = new uint256[](numMakers);
        feeAmounts = new uint256[](numMakers);

        for (uint256 i = 0; i < numMakers; i++) {
            uint256 makerPk = _makerPk(6, i, numMakers);
            address maker = vm.addr(makerPk);
            dealCollateralAndApprove(maker, address(exchange), usdcPerMaker);
            makerOrders[i] = _createAndSignOrderWithSalt(makerPk, yes, usdcPerMaker, tokensPerMaker, Side.BUY, i + 100);
            fillAmounts[i] = usdcPerMaker;
            feeAmounts[i] = 0;
        }

        takerFillAmount = totalTokens;
    }

    function _prepareMerge(uint256 numMakers)
        internal
        returns (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        )
    {
        uint256 tokensPerMaker = 20_000_000;
        uint256 usdcPerMaker = 10_000_000;
        uint256 totalTokens = tokensPerMaker * numMakers;
        uint256 totalUsdc = usdcPerMaker * numMakers;

        dealOutcomeTokensAndApprove(bob, address(exchange), totalTokens);

        takerOrder = _createAndSignOrder(bobPK, yes, totalTokens, totalUsdc, Side.SELL);
        makerOrders = new Order[](numMakers);
        fillAmounts = new uint256[](numMakers);
        feeAmounts = new uint256[](numMakers);

        for (uint256 i = 0; i < numMakers; i++) {
            uint256 makerPk = _makerPk(3, i, numMakers);
            address maker = vm.addr(makerPk);
            dealOutcomeTokensAndApprove(maker, address(exchange), tokensPerMaker);
            makerOrders[i] = _createAndSignOrderWithSalt(makerPk, no, tokensPerMaker, usdcPerMaker, Side.SELL, i + 100);
            fillAmounts[i] = tokensPerMaker;
            feeAmounts[i] = 0;
        }

        takerFillAmount = totalTokens;
    }

    /// @notice Combo: Taker BUY YES, half makers SELL YES (complementary), half makers BUY NO
    /// (mint)
    function _prepareComboComplementaryMint(uint256 numMakers)
        internal
        returns (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        )
    {
        uint256 half = numMakers / 2;
        uint256 usdcPerMaker = 10_000_000;
        uint256 tokensPerMaker = 20_000_000;

        uint256 totalTakerUsdc = usdcPerMaker * half + (tokensPerMaker * half / 2);
        uint256 totalTakerTokens = tokensPerMaker * numMakers;

        dealCollateralAndApprove(bob, address(exchange), totalTakerUsdc);

        takerOrder = _createAndSignOrder(bobPK, yes, totalTakerUsdc, totalTakerTokens, Side.BUY);
        makerOrders = new Order[](numMakers);
        fillAmounts = new uint256[](numMakers);
        feeAmounts = new uint256[](numMakers);

        // First half: complementary (SELL YES)
        for (uint256 i = 0; i < half; i++) {
            uint256 makerPk = _makerPk(4, i, numMakers);
            address maker = vm.addr(makerPk);
            dealOutcomeTokensAndApprove(maker, address(exchange), tokensPerMaker);
            makerOrders[i] = _createAndSignOrderWithSalt(makerPk, yes, tokensPerMaker, usdcPerMaker, Side.SELL, i + 100);
            fillAmounts[i] = tokensPerMaker;
            feeAmounts[i] = 0;
        }

        // Second half: mint (BUY NO)
        for (uint256 i = half; i < numMakers; i++) {
            uint256 makerPk = _makerPk(4, i, numMakers);
            address maker = vm.addr(makerPk);
            dealCollateralAndApprove(maker, address(exchange), usdcPerMaker);
            makerOrders[i] = _createAndSignOrderWithSalt(makerPk, no, usdcPerMaker, tokensPerMaker, Side.BUY, i + 100);
            fillAmounts[i] = usdcPerMaker;
            feeAmounts[i] = 0;
        }

        takerFillAmount = totalTakerUsdc;
    }

    /// @notice Combo: Taker SELL YES, half makers BUY YES (complementary), half makers SELL NO
    /// (merge)
    function _prepareComboComplementaryMerge(uint256 numMakers)
        internal
        returns (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        )
    {
        uint256 half = numMakers / 2;
        uint256 tokensPerMaker = 20_000_000;
        uint256 usdcPerMaker = 10_000_000;

        uint256 totalTakerTokens = tokensPerMaker * numMakers;
        uint256 totalTakerUsdc = usdcPerMaker * half + usdcPerMaker * half;

        dealOutcomeTokensAndApprove(bob, address(exchange), totalTakerTokens);

        takerOrder = _createAndSignOrder(bobPK, yes, totalTakerTokens, totalTakerUsdc, Side.SELL);
        makerOrders = new Order[](numMakers);
        fillAmounts = new uint256[](numMakers);
        feeAmounts = new uint256[](numMakers);

        // First half: complementary (BUY YES)
        for (uint256 i = 0; i < half; i++) {
            uint256 makerPk = _makerPk(5, i, numMakers);
            address maker = vm.addr(makerPk);
            dealCollateralAndApprove(maker, address(exchange), usdcPerMaker);
            makerOrders[i] = _createAndSignOrderWithSalt(makerPk, yes, usdcPerMaker, tokensPerMaker, Side.BUY, i + 100);
            fillAmounts[i] = usdcPerMaker;
            feeAmounts[i] = 0;
        }

        // Second half: merge (SELL NO)
        for (uint256 i = half; i < numMakers; i++) {
            uint256 makerPk = _makerPk(5, i, numMakers);
            address maker = vm.addr(makerPk);
            dealOutcomeTokensAndApprove(maker, address(exchange), tokensPerMaker);
            makerOrders[i] = _createAndSignOrderWithSalt(makerPk, no, tokensPerMaker, usdcPerMaker, Side.SELL, i + 100);
            fillAmounts[i] = tokensPerMaker;
            feeAmounts[i] = 0;
        }

        takerFillAmount = totalTakerTokens;
    }

    function _prepareComboComplementaryMergeWithFees(uint256 numMakers)
        internal
        returns (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256 takerFee,
            uint256[] memory feeAmounts
        )
    {
        uint256 half = numMakers / 2;
        takerFillAmount = 20_000_000 * numMakers;
        takerFee = 250_000;

        dealOutcomeTokensAndApprove(bob, address(exchange), takerFillAmount);

        takerOrder = _createAndSignOrderWithSaltAndMaxFee(
            bobPK, yes, takerFillAmount, 10_000_000 * numMakers, Side.SELL, 1, takerFee
        );
        makerOrders = new Order[](numMakers);
        fillAmounts = new uint256[](numMakers);
        feeAmounts = new uint256[](numMakers);

        for (uint256 i = 0; i < numMakers / 2; i++) {
            uint256 makerPk = _makerPk(7, i, numMakers);
            address maker = vm.addr(makerPk);
            dealCollateralAndApprove(maker, address(exchange), 10_100_000);
            makerOrders[i] = _createAndSignOrderWithSaltAndMaxFee(
                makerPk, yes, 10_000_000, 20_000_000, Side.BUY, i + 100, 100_000
            );
            fillAmounts[i] = 10_000_000;
            feeAmounts[i] = 100_000;
        }

        for (uint256 i = numMakers / 2; i < numMakers; i++) {
            uint256 makerPk = _makerPk(7, i, numMakers);
            address maker = vm.addr(makerPk);
            dealOutcomeTokensAndApprove(maker, address(exchange), 20_000_000);
            dealCollateralAndApprove(maker, address(exchange), 100_000);
            makerOrders[i] = _createAndSignOrderWithSaltAndMaxFee(
                makerPk, no, 20_000_000, 10_000_000, Side.SELL, i + 100, 100_000
            );
            fillAmounts[i] = 20_000_000;
            feeAmounts[i] = 100_000;
        }
    }

    /*--------------------------------------------------------------
                                HELPERS
    --------------------------------------------------------------*/

    function dealCollateralAndApprove(address to, address spender, uint256 amount) internal {
        collateral.usdc.mint(to, amount);
        vm.startPrank(to);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), to, amount);
        collateral.token.approve(spender, amount);
        vm.stopPrank();
    }

    function dealOutcomeTokensAndApprove(address to, address spender, uint256 amount) internal {
        // First give collateral to mint positions
        collateral.usdc.mint(to, amount);
        vm.startPrank(to);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), to, amount);
        collateral.token.approve(address(router), amount);
        router.split(ConditionIdLib.from(conditionId), amount);
        positions.manager.setApprovalForAll(spender, true);
        vm.stopPrank();
    }

    function _createAndSignOrder(uint256 pk, uint256 tokenId, uint256 makerAmount, uint256 takerAmount, Side side)
        internal
        view
        returns (Order memory)
    {
        return _createAndSignOrderWithSalt(pk, tokenId, makerAmount, takerAmount, side, 1);
    }

    function _createAndSignOrderWithSalt(
        uint256 pk,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side,
        uint256 salt
    ) internal view returns (Order memory) {
        return _createAndSignOrderWithSaltAndMaxFee(pk, tokenId, makerAmount, takerAmount, side, salt, 0);
    }

    function _makerPk(uint256 domain, uint256 i, uint256 numMakers) internal view returns (uint256) {
        if (numMakers == 1) return carlaPK;
        return uint256(keccak256(abi.encodePacked("snapshot-maker", domain, i))) | 1;
    }

    function _createAndSignOrderWithSaltAndMaxFee(
        uint256 pk,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side,
        uint256 salt,
        uint256 /* maxFee */
    ) internal view returns (Order memory) {
        address maker = vm.addr(pk);
        Order memory order = Order({
            salt: salt,
            maker: maker,
            signer: maker,
            tokenId: PositionId.wrap(tokenId),
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            side: side,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });

        bytes32 orderHash = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, orderHash);
        order.signature = abi.encodePacked(r, s, v);
        return order;
    }

    function _snapshotMatchOrders(
        string memory name,
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts,
        uint256 takerFeeAmount,
        uint256[] memory makerFeeAmounts
    ) internal {
        uint256 takerReceiveAmount = _takerReceiveAmount(takerOrder, makerOrders, makerFillAmounts);
        vm.prank(operator);
        vm.startSnapshotGas(name);
        exchange.matchOrders(
            takerOrder,
            makerOrders,
            makerFillAmounts,
            makerFeeAmounts,
            TakerAmounts({
                takerFillAmount: takerFillAmount, takerReceiveAmount: takerReceiveAmount, takerFeeAmount: takerFeeAmount
            })
        );
        vm.stopSnapshotGas();
    }

    function _takerReceiveAmount(Order memory takerOrder, Order[] memory makerOrders, uint256[] memory makerFillAmounts)
        internal
        pure
        returns (uint256 receiveAmount)
    {
        if (_isAllComplementary(takerOrder, makerOrders)) {
            for (uint256 i; i < makerOrders.length; ++i) {
                receiveAmount += makerFillAmounts[i];
            }
            return receiveAmount;
        }

        for (uint256 i; i < makerOrders.length; ++i) {
            Order memory makerOrder = makerOrders[i];
            uint256 fillAmount = makerFillAmounts[i];
            if (fillAmount == 0 || makerOrder.makerAmount == 0) continue;
            if (takerOrder.side == Side.BUY) {
                receiveAmount += makerOrder.side == Side.SELL
                    ? fillAmount
                    : _calculateTakingAmount(fillAmount, makerOrder.makerAmount, makerOrder.takerAmount);
            } else if (makerOrder.side == Side.BUY) {
                receiveAmount += fillAmount;
            } else {
                uint256 takingAmount =
                    _calculateTakingAmount(fillAmount, makerOrder.makerAmount, makerOrder.takerAmount);
                if (fillAmount > takingAmount) receiveAmount += fillAmount - takingAmount;
            }
        }
    }

    function _isAllComplementary(Order memory takerOrder, Order[] memory makerOrders) internal pure returns (bool) {
        for (uint256 i; i < makerOrders.length; ++i) {
            Order memory makerOrder = makerOrders[i];
            if (makerOrder.side == takerOrder.side || makerOrder.tokenId != takerOrder.tokenId) return false;
        }
        return true;
    }

    function _calculateTakingAmount(uint256 makingAmount, uint256 makerAmount, uint256 takerAmount)
        internal
        pure
        returns (uint256)
    {
        return makingAmount * takerAmount / makerAmount;
    }
}

/*--------------------------------------------------------------
                  COMPLEMENTARY (BUY VS SELL)
--------------------------------------------------------------*/

contract ExchangeSnapshotsTest_complementary is ExchangeSnapshotsTest {
    function test_oneMaker() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComplementary(1);

        _snapshotMatchOrders(
            "complementary_1maker", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }

    function test_fiveMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComplementary(5);

        _snapshotMatchOrders(
            "complementary_5makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }

    function test_tenMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComplementary(10);

        _snapshotMatchOrders(
            "complementary_10makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }

    function test_twentyMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComplementary(20);

        _snapshotMatchOrders(
            "complementary_20makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }
}

/*--------------------------------------------------------------
             COMPLEMENTARY SELL (SELL VS BUY, ZERO FEE)
--------------------------------------------------------------*/

contract ExchangeSnapshotsTest_complementarySell is ExchangeSnapshotsTest {
    function test_oneMaker() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComplementarySell(1);

        _snapshotMatchOrders(
            "complementary_sell_1maker", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }

    function test_tenMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComplementarySell(10);

        _snapshotMatchOrders(
            "complementary_sell_10makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }

    function test_twentyMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComplementarySell(20);

        _snapshotMatchOrders(
            "complementary_sell_20makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }
}

/*--------------------------------------------------------------
                      MINT (BUY VS BUY)
--------------------------------------------------------------*/

contract ExchangeSnapshotsTest_mint is ExchangeSnapshotsTest {
    function test_oneMaker() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareMint(1);

        _snapshotMatchOrders("mint_1maker", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts);
    }

    function test_fiveMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareMint(5);

        _snapshotMatchOrders("mint_5makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts);
    }

    function test_tenMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareMint(10);

        _snapshotMatchOrders("mint_10makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts);
    }

    function test_twentyMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareMint(20);

        _snapshotMatchOrders("mint_20makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts);
    }
}

/*--------------------------------------------------------------
                    MERGE (SELL VS SELL)
--------------------------------------------------------------*/

contract ExchangeSnapshotsTest_merge is ExchangeSnapshotsTest {
    function test_oneMaker() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareMerge(1);

        _snapshotMatchOrders("merge_1maker", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts);
    }

    function test_fiveMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareMerge(5);

        _snapshotMatchOrders("merge_5makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts);
    }

    function test_tenMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareMerge(10);

        _snapshotMatchOrders("merge_10makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts);
    }

    function test_twentyMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareMerge(20);

        _snapshotMatchOrders("merge_20makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts);
    }
}

/*--------------------------------------------------------------
                COMBO: COMPLEMENTARY + MINT
--------------------------------------------------------------*/

contract ExchangeSnapshotsTest_comboComplementaryMint is ExchangeSnapshotsTest {
    function test_tenMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComboComplementaryMint(10);

        _snapshotMatchOrders(
            "combo_complementary_mint_10makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }

    function test_twentyMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComboComplementaryMint(20);

        _snapshotMatchOrders(
            "combo_complementary_mint_20makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }
}

/*--------------------------------------------------------------
                COMBO: COMPLEMENTARY + MERGE
--------------------------------------------------------------*/

contract ExchangeSnapshotsTest_comboComplementaryMerge is ExchangeSnapshotsTest {
    function test_tenMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComboComplementaryMerge(10);

        _snapshotMatchOrders(
            "combo_complementary_merge_10makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }

    function test_twentyMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256[] memory feeAmounts
        ) = _prepareComboComplementaryMerge(20);

        _snapshotMatchOrders(
            "combo_complementary_merge_20makers", takerOrder, makerOrders, takerFillAmount, fillAmounts, 0, feeAmounts
        );
    }
}

/*--------------------------------------------------------------
         COMBO: COMPLEMENTARY + MERGE (BATCH SELL, WITH FEES)
--------------------------------------------------------------*/

contract ExchangeSnapshotsTest_comboComplementaryMergeFees is ExchangeSnapshotsTest {
    function test_tenMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256 takerFee,
            uint256[] memory feeAmounts
        ) = _prepareComboComplementaryMergeWithFees(10);

        _snapshotMatchOrders(
            "combo_complementary_merge_fees_10makers",
            takerOrder,
            makerOrders,
            takerFillAmount,
            fillAmounts,
            takerFee,
            feeAmounts
        );
    }

    function test_twentyMakers() public {
        (
            Order memory takerOrder,
            Order[] memory makerOrders,
            uint256 takerFillAmount,
            uint256[] memory fillAmounts,
            uint256 takerFee,
            uint256[] memory feeAmounts
        ) = _prepareComboComplementaryMergeWithFees(20);

        _snapshotMatchOrders(
            "combo_complementary_merge_fees_20makers",
            takerOrder,
            makerOrders,
            takerFillAmount,
            fillAmounts,
            takerFee,
            feeAmounts
        );
    }
}
