// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Test } from "lib/forge-std/src/Test.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { Positions, PositionManagerSetup } from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { Router } from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

import { Exchange, TakerAmounts } from "@polymarket-v2/src/exchange/Exchange.sol";
import { Order, Side, SignatureType, OrderStatus } from "@polymarket-v2/src/exchange/OrderStructs.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";

import { ERC1271Mock } from "./mocks/ERC1271Mock.sol";
import { MockProxyFactory } from "./mocks/MockProxyFactory.sol";
import { MockSafeFactory } from "./mocks/MockSafeFactory.sol";

contract BaseExchangeTest is Test {
    Collateral collateral;
    Positions positions;
    Exchange exchange;
    Router router;
    CombinatorialModule combinatorialModule;

    address owner;
    address admin;
    address creator;
    address oracle;
    address feeReceiver;

    uint256 internal bobPK = 0xB0B;
    uint256 internal carlaPK = 0xCA414;
    address public bob;
    address public carla;

    bytes32 conditionId;
    uint256 yes;
    uint256 no;

    ERC1271Mock public contractWallet;
    MockProxyFactory public proxyFactory;
    MockSafeFactory public safeFactory;

    // Errors
    error Unauthorized();
    error NotOperator();
    error Paused();
    error UserIsPaused();
    error OrderAlreadyFilled();
    error InvalidSignature();
    error InvalidTokenId();
    error InvalidComplement();
    error NotCrossing();
    error MismatchedTokenIds();
    error FeeExceedsMaxRate();
    error FeeExceedsProceeds();
    error MaxFeeRateExceedsCeiling();
    error MakingGtRemaining();
    error NoMakerOrders();
    error MismatchedArrayLengths();
    error ZeroMakerAmount();
    error ZeroTakerAmount();
    error ComplementaryFillExceedsTakerFill();
    error TakerFillMismatch();
    error AssetAccountingMismatch();
    error UserAlreadyPaused();
    error ExceedsMaxPauseInterval();

    // Events from Exchange
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        Side side,
        PositionId tokenId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee,
        bytes32 builder,
        bytes32 metadata
    );
    event OrdersMatched(
        bytes32 indexed takerOrderHash,
        address indexed takerOrderMaker,
        Side side,
        PositionId tokenId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled
    );
    event FeeCharged(address indexed receiver, uint256 amount);
    event TradingPaused(address indexed pauser);
    event TradingUnpaused(address indexed pauser);
    event OrderPreapproved(bytes32 indexed orderHash);
    event OrderPreapprovalInvalidated(bytes32 indexed orderHash);
    event UserPaused(address indexed user, uint256 effectivePauseBlock);
    event UserUnpaused(address indexed user);
    event UserPauseBlockIntervalUpdated(uint256 oldInterval, uint256 newInterval);

    function setUp() public virtual {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        creator = makeAddr("creator");
        oracle = makeAddr("oracle");
        feeReceiver = makeAddr("feeReceiver");

        bob = vm.addr(bobPK);
        vm.label(bob, "bob");
        carla = vm.addr(carlaPK);
        vm.label(carla, "carla");

        proxyFactory = new MockProxyFactory();
        safeFactory = new MockSafeFactory();
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);
        combinatorialModule = _deployCombinatorialModule();

        // Register combinatorial module with position manager and collateral token
        vm.prank(owner);
        collateral.token.addMinter(address(combinatorialModule));

        vm.startPrank(admin);
        positions.manager.addModule(address(combinatorialModule));
        positions.manager.setCrossModuleAuth(address(combinatorialModule), true);
        vm.stopPrank();

        exchange = _deployExchange(1000); // 10% to accommodate test fee levels

        // Deploy router for splitting
        router = RouterSetup.deployRouter(address(positions.manager), owner);

        // Deploy ERC1271 mock wallet with carla as signer
        contractWallet = new ERC1271Mock(carla);

        // Setup roles
        vm.startPrank(admin);
        exchange.addOperator(admin);
        exchange.addOperator(bob);
        exchange.addOperator(carla);
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
                        EXCHANGE DEPLOYMENT
    --------------------------------------------------------------*/

    /// @dev Deploys a fresh Exchange proxy with the given max fee rate.
    function _deployExchange(uint256 _maxFeeRate) internal returns (Exchange) {
        // forgefmt: disable-next-item
        address impl = address(new Exchange(
            address(positions.manager),
            address(combinatorialModule),
            feeReceiver,
            _maxFeeRate,
            address(proxyFactory),
            address(safeFactory),
            proxyFactory.bytecodeHash(),
            safeFactory.bytecodeHash()
        ));
        address proxy = LibClone.deployERC1967(impl);
        Exchange ex = Exchange(proxy);
        ex.initialize(owner, admin);
        return ex;
    }

    function _deployCombinatorialModule() internal returns (CombinatorialModule module_) {
        address impl = address(new CombinatorialModule(address(positions.manager)));
        address proxy = LibClone.deployERC1967(impl);
        module_ = CombinatorialModule(proxy);
        module_.initialize(owner, admin);
    }

    /*--------------------------------------------------------------
                            ORDER HELPERS
    --------------------------------------------------------------*/

    function _createOrder(address maker, uint256 tokenId, uint256 makerAmount, uint256 takerAmount, Side side)
        internal
        pure
        returns (Order memory)
    {
        return Order({
            salt: 1,
            maker: maker,
            signer: maker,
            tokenId: PositionId.wrap(tokenId),
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            side: side,
            signatureType: SignatureType.EOA,
            timestamp: 0,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: new bytes(0)
        });
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

    function _createAndSign1271Order(
        uint256 signerPk,
        address wallet,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side
    ) internal view returns (Order memory) {
        Order memory order = _createOrder(wallet, tokenId, makerAmount, takerAmount, side);
        order.signatureType = SignatureType.POLY_1271;
        order.signature = _signMessage(signerPk, exchange.hashOrder(order));
        return order;
    }

    function _createAndSignProxyOrder(
        uint256 signerPk,
        address proxyWallet,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side
    ) internal view returns (Order memory order) {
        address signer = vm.addr(signerPk);
        order = _createOrder(proxyWallet, tokenId, makerAmount, takerAmount, side);
        order.signer = signer;
        order.signatureType = SignatureType.POLY_PROXY;
        order.signature = _signMessage(signerPk, exchange.hashOrder(order));
    }

    function _createAndSignSafeOrder(
        uint256 signerPk,
        address safeWallet,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side
    ) internal view returns (Order memory order) {
        address signer = vm.addr(signerPk);
        order = _createOrder(safeWallet, tokenId, makerAmount, takerAmount, side);
        order.signer = signer;
        order.signatureType = SignatureType.POLY_GNOSIS_SAFE;
        order.signature = _signMessage(signerPk, exchange.hashOrder(order));
    }

    function _deployProxy(address signer) internal returns (address) {
        return proxyFactory.deployProxy(signer);
    }

    function _deploySafe(address signer) internal returns (address) {
        return safeFactory.deploySafe(signer);
    }

    function _signMessage(uint256 pk, bytes32 message) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, message);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Re-signs the order with a wrong key so signature validation fails.
    function _invalidateSignature(Order memory order) internal view {
        order.signature = _signMessage(0xDEAD, exchange.hashOrder(order));
    }

    function _matchOrders(
        bytes32,
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts,
        uint256 takerFeeAmount,
        uint256[] memory makerFeeAmounts
    ) internal {
        uint256 takerReceiveAmount;
        if (makerOrders.length == makerFillAmounts.length) {
            takerReceiveAmount = _takerReceiveAmount(takerOrder, makerOrders, makerFillAmounts);
        }
        exchange.matchOrders(
            takerOrder,
            makerOrders,
            makerFillAmounts,
            makerFeeAmounts,
            TakerAmounts({
                takerFillAmount: takerFillAmount, takerReceiveAmount: takerReceiveAmount, takerFeeAmount: takerFeeAmount
            })
        );
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

    /*--------------------------------------------------------------
                           DEAL HELPERS
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
        collateral.usdc.mint(to, amount);
        vm.startPrank(to);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), to, amount);
        collateral.token.approve(address(router), amount);
        router.split(ConditionIdLib.from(conditionId), amount);
        positions.manager.setApprovalForAll(spender, true);
        vm.stopPrank();
    }

    function _dealCombinatorialTokens(address _to, address _spender, ConditionId _condId, uint256 _amount) internal {
        collateral.usdc.mint(_to, _amount);
        vm.startPrank(_to);
        collateral.usdc.approve(address(collateral.onramp), _amount);
        collateral.onramp.wrap(address(collateral.usdc), _to, _amount);
        collateral.token.transfer(address(combinatorialModule), _amount);
        address[] memory to = new address[](2);
        to[0] = _to;
        to[1] = _to;
        combinatorialModule.split(to, _condId, _amount);
        positions.manager.setApprovalForAll(_spender, true);
        vm.stopPrank();
    }

    /*--------------------------------------------------------------
                         ASSERTION HELPERS
    --------------------------------------------------------------*/

    function assertCollateralBalance(address _who, uint256 _amount) public view {
        assertEq(collateral.token.balanceOf(_who), _amount);
    }

    function assertCTFBalance(address _who, uint256 _tokenId, uint256 _amount) public view {
        assertEq(positions.manager.balanceOf(_who, _tokenId), _amount);
    }
}
