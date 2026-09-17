// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";
import { Collateral, CollateralSetup } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { IPositionManagerModule } from "@polymarket-v2/src/positionManager/IPositionManagerModule.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";

/// @dev A contract that does NOT implement ERC1155TokenReceiver
contract NonReceiver { }

contract UnsafeTransferModuleMock is IPositionManagerModule, ERC1155TokenReceiver {
    PositionManager public immutable positionManager;
    uint256 public constant MODULE_ID = 99;

    constructor(address _positionManager) {
        positionManager = PositionManager(_positionManager);
    }

    function moduleId() external pure returns (uint256) {
        return MODULE_ID;
    }

    function getConditionId(bytes32 _dataHash) public pure returns (ConditionId) {
        return ConditionIdLib.encode(MODULE_ID, _dataHash, 0, 0);
    }

    function getPositionId(ConditionId _conditionId, uint256 _outcomeIndex) public pure returns (uint256) {
        return PositionId.unwrap(ConditionIdLib.computePositionId(_conditionId, _outcomeIndex));
    }

    function getPayout(PositionId, uint256) public pure returns (uint256) {
        return 0;
    }

    function mintTo(address _to, ConditionId _conditionId, uint256 _amount) external {
        uint256 posId0 = getPositionId(_conditionId, 0);
        uint256 posId1 = getPositionId(_conditionId, 1);
        positionManager.mint(_to, PositionId.wrap(posId0), _amount);
        positionManager.mint(_to, PositionId.wrap(posId1), _amount);
    }
}

contract UnsafeTransferTest is TestHelper {
    Collateral collateral;
    PositionManager positionManager;
    UnsafeTransferModuleMock moduleMock;

    ConditionId conditionId;
    uint256 positionId0;
    uint256 positionId1;

    /*--------------------------------------------------------------
                           ERC1155 EVENTS
    --------------------------------------------------------------*/

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    event TransferBatch(
        address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values
    );

    /*--------------------------------------------------------------
                       SOLADY ERC1155 ERRORS
    --------------------------------------------------------------*/

    error TransferToZeroAddress();
    error NotOwnerNorApproved();
    error InsufficientBalance();
    error AccountBalanceOverflow();
    error ArrayLengthsMismatch();

    function setUp() public virtual {
        collateral = CollateralSetup._deploy(owner);

        address impl = address(new PositionManager(address(collateral.token)));
        address proxy = LibClone.deployERC1967(impl);

        positionManager = PositionManager(proxy);
        positionManager.initialize(owner, admin);

        moduleMock = new UnsafeTransferModuleMock(address(positionManager));

        vm.prank(admin);
        positionManager.addModule(address(moduleMock));

        conditionId = moduleMock.getConditionId(bytes32(0));
        positionId0 = moduleMock.getPositionId(conditionId, 0);
        positionId1 = moduleMock.getPositionId(conditionId, 1);

        // Mint positions to alice
        moduleMock.mintTo(alice, conditionId, 1000);
    }
}

/*--------------------------------------------------------------
                     unsafeTransferFrom
--------------------------------------------------------------*/

contract UnsafeTransferTest_unsafeTransferFrom is UnsafeTransferTest {
    function test_basic() public {
        vm.prank(alice);
        positionManager.unsafeTransferFrom(alice, brian, PositionId.wrap(positionId0), 100);

        assertEq(positionManager.balanceOf(alice, positionId0), 900);
        assertEq(positionManager.balanceOf(brian, positionId0), 100);
    }

    function test_emitsTransferSingle() public {
        vm.expectEmit(true, true, true, true);
        emit TransferSingle(alice, alice, brian, positionId0, 100);

        vm.prank(alice);
        positionManager.unsafeTransferFrom(alice, brian, PositionId.wrap(positionId0), 100);
    }

    function test_approved() public {
        vm.prank(alice);
        positionManager.setApprovalForAll(brian, true);

        vm.prank(brian);
        positionManager.unsafeTransferFrom(alice, carly, PositionId.wrap(positionId0), 100);

        assertEq(positionManager.balanceOf(alice, positionId0), 900);
        assertEq(positionManager.balanceOf(carly, positionId0), 100);
    }

    function test_toNonReceiver() public {
        NonReceiver nonReceiver = new NonReceiver();

        // This would revert with safeTransferFrom but succeeds with unsafe
        vm.prank(alice);
        positionManager.unsafeTransferFrom(alice, address(nonReceiver), PositionId.wrap(positionId0), 100);

        assertEq(positionManager.balanceOf(address(nonReceiver), positionId0), 100);
    }

    function test_zeroAmount() public {
        vm.prank(alice);
        positionManager.unsafeTransferFrom(alice, brian, PositionId.wrap(positionId0), 0);

        assertEq(positionManager.balanceOf(alice, positionId0), 1000);
        assertEq(positionManager.balanceOf(brian, positionId0), 0);
    }

    function test_selfTransfer() public {
        vm.prank(alice);
        positionManager.unsafeTransferFrom(alice, alice, PositionId.wrap(positionId0), 100);

        assertEq(positionManager.balanceOf(alice, positionId0), 1000);
    }

    function test_revert_notApproved() public {
        vm.prank(brian);
        vm.expectRevert(NotOwnerNorApproved.selector);
        positionManager.unsafeTransferFrom(alice, brian, PositionId.wrap(positionId0), 100);
    }

    function test_revert_insufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        positionManager.unsafeTransferFrom(alice, brian, PositionId.wrap(positionId0), 1001);
    }

    function test_revert_toZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(TransferToZeroAddress.selector);
        positionManager.unsafeTransferFrom(alice, address(0), PositionId.wrap(positionId0), 100);
    }
}

/*--------------------------------------------------------------
                   unsafeBatchTransferFrom
--------------------------------------------------------------*/

contract UnsafeTransferTest_unsafeBatchTransferFrom is UnsafeTransferTest {
    function test_basic() public {
        PositionId[] memory ids = new PositionId[](2);
        ids[0] = PositionId.wrap(positionId0);
        ids[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(alice);
        positionManager.unsafeBatchTransferFrom(alice, brian, ids, amounts);

        assertEq(positionManager.balanceOf(alice, positionId0), 900);
        assertEq(positionManager.balanceOf(alice, positionId1), 800);
        assertEq(positionManager.balanceOf(brian, positionId0), 100);
        assertEq(positionManager.balanceOf(brian, positionId1), 200);
    }

    function test_emitsTransferBatch() public {
        PositionId[] memory ids = new PositionId[](2);
        ids[0] = PositionId.wrap(positionId0);
        ids[1] = PositionId.wrap(positionId1);
        uint256[] memory rawIds = new uint256[](2);
        rawIds[0] = positionId0;
        rawIds[1] = positionId1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.expectEmit(true, true, true, true);
        emit TransferBatch(alice, alice, brian, rawIds, amounts);

        vm.prank(alice);
        positionManager.unsafeBatchTransferFrom(alice, brian, ids, amounts);
    }

    function test_approved() public {
        vm.prank(alice);
        positionManager.setApprovalForAll(brian, true);

        PositionId[] memory ids = new PositionId[](2);
        ids[0] = PositionId.wrap(positionId0);
        ids[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(brian);
        positionManager.unsafeBatchTransferFrom(alice, carly, ids, amounts);

        assertEq(positionManager.balanceOf(carly, positionId0), 100);
        assertEq(positionManager.balanceOf(carly, positionId1), 200);
    }

    function test_toNonReceiver() public {
        NonReceiver nonReceiver = new NonReceiver();

        PositionId[] memory ids = new PositionId[](1);
        ids[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        // This would revert with safeBatchTransferFrom but succeeds with unsafe
        vm.prank(alice);
        positionManager.unsafeBatchTransferFrom(alice, address(nonReceiver), ids, amounts);

        assertEq(positionManager.balanceOf(address(nonReceiver), positionId0), 100);
    }

    function test_emptyArrays() public {
        PositionId[] memory ids = new PositionId[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(alice);
        positionManager.unsafeBatchTransferFrom(alice, brian, ids, amounts);
    }

    function test_revert_lengthMismatch() public {
        PositionId[] memory ids = new PositionId[](2);
        ids[0] = PositionId.wrap(positionId0);
        ids[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(alice);
        vm.expectRevert(ArrayLengthsMismatch.selector);
        positionManager.unsafeBatchTransferFrom(alice, brian, ids, amounts);
    }

    function test_revert_notApproved() public {
        PositionId[] memory ids = new PositionId[](1);
        ids[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(brian);
        vm.expectRevert(NotOwnerNorApproved.selector);
        positionManager.unsafeBatchTransferFrom(alice, brian, ids, amounts);
    }

    function test_revert_insufficientBalance() public {
        PositionId[] memory ids = new PositionId[](1);
        ids[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1001;

        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        positionManager.unsafeBatchTransferFrom(alice, brian, ids, amounts);
    }

    function test_revert_toZeroAddress() public {
        PositionId[] memory ids = new PositionId[](1);
        ids[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(alice);
        vm.expectRevert(TransferToZeroAddress.selector);
        positionManager.unsafeBatchTransferFrom(alice, address(0), ids, amounts);
    }
}
