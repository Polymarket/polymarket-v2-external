// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { IPositionManagerModule } from "@polymarket-v2/src/positionManager/IPositionManagerModule.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { OOReporterModule } from "@polymarket-v2/src/oracle/modules/OOReporterModule.sol";
import { USDC } from "@polymarket-v2/src/mocks/USDC.sol";
import { USDCe } from "@polymarket-v2/src/mocks/USDCe.sol";
import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";

contract SlotTestModuleMock is IPositionManagerModule, ERC1155TokenReceiver {
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

    function mint(address _to, ConditionId _conditionId, uint256 _outcomeIndex, uint256 _amount) external {
        uint256 positionId = getPositionId(_conditionId, _outcomeIndex);
        positionManager.mint(_to, PositionId.wrap(positionId), _amount);
    }
}

/// @dev Asserts that all custom storage slots — both Solady inherited slots and token-specific
///      slots — have not been accidentally modified. If a slot constant, keccak string, or
///      inheritance chain changes, these tests fail. Exchange adds only shared Solady slots.
contract StorageSlotsTest is TestHelper {
    /*--------------------------------------------------------------
          INHERITED SOLADY SLOTS (shared by all upgradeable contracts)
    --------------------------------------------------------------*/

    bytes32 internal constant _EXPECTED_ERC1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant _EXPECTED_INITIALIZABLE_SLOT =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffbf601132;
    bytes32 internal constant _EXPECTED_OWNER_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927;
    uint32 internal constant _EXPECTED_HANDOVER_SLOT_SEED = 0x389a75e1;
    uint32 internal constant _EXPECTED_ROLE_SLOT_SEED = 0x8b78c6d8;

    /*--------------------------------------------------------------
              ERC1155 SLOTS (PositionManager only)
    --------------------------------------------------------------*/

    uint256 internal constant _EXPECTED_ERC1155_MASTER_SLOT_SEED = 0x9a31110384e0b0c9;

    /*--------------------------------------------------------------
              ERC20 SLOTS (CollateralToken only)
    --------------------------------------------------------------*/

    uint256 internal constant _EXPECTED_TOTAL_SUPPLY_SLOT = 0x05345cdf77eb68f44c;
    uint32 internal constant _EXPECTED_BALANCE_SLOT_SEED = 0x87a211a2;
    uint32 internal constant _EXPECTED_ALLOWANCE_SLOT_SEED = 0x7f5e9f20;
    uint32 internal constant _EXPECTED_NONCES_SLOT_SEED = 0x38377508;

    /*--------------------------------------------------------------
                          CONTRACT INSTANCES
    --------------------------------------------------------------*/

    PositionManager positionManager;
    address positionManagerImpl;

    CollateralToken collateralToken;
    address collateralTokenImpl;

    OracleAggregator oracleAggregator;
    address oracleAggregatorImpl;

    OOReporterModule ooReporterModule;
    address ooReporterModuleImpl;
    address ooReporter = address(0x0A0E);

    BinaryModule binaryModule;
    address binaryModuleImpl;

    NegRiskModule negRiskModule;
    address negRiskModuleImpl;

    CombinatorialModule combinatorialModule;
    address combinatorialModuleImpl;

    SlotTestModuleMock moduleMock;

    /*--------------------------------------------------------------
                              SETUP
    --------------------------------------------------------------*/

    function setUp() public virtual {
        // --- CollateralToken ---
        USDC usdc = new USDC();
        USDCe usdce = new USDCe();
        address vault = address(0xBA01);

        collateralTokenImpl = address(new CollateralToken(address(usdc), address(usdce), vault));
        address collateralProxy = LibClone.deployERC1967(collateralTokenImpl);
        collateralToken = CollateralToken(collateralProxy);
        collateralToken.initialize(owner);

        // --- PositionManager ---
        positionManagerImpl = address(new PositionManager(address(collateralToken)));
        address positionManagerProxy = LibClone.deployERC1967(positionManagerImpl);
        positionManager = PositionManager(positionManagerProxy);
        positionManager.initialize(owner, admin);

        moduleMock = new SlotTestModuleMock(address(positionManager));
        vm.prank(admin);
        positionManager.addModule(address(moduleMock));

        // --- OracleAggregator ---
        oracleAggregatorImpl = address(new OracleAggregator(address(positionManager)));
        address oracleAggregatorProxy = LibClone.deployERC1967(oracleAggregatorImpl);
        oracleAggregator = OracleAggregator(oracleAggregatorProxy);
        oracleAggregator.initialize(owner, owner);

        // --- OOReporterModule ---
        ooReporterModuleImpl = address(new OOReporterModule(ooReporter));
        address ooReporterModuleProxy = LibClone.deployERC1967(ooReporterModuleImpl);
        ooReporterModule = OOReporterModule(ooReporterModuleProxy);
        ooReporterModule.initialize(owner, admin, address(oracleAggregator));

        // --- BinaryModule ---
        binaryModuleImpl =
            address(new BinaryModule(address(positionManager), address(0), address(0), ResolutionChain.POLYGON));
        address binaryModuleProxy = LibClone.deployERC1967(binaryModuleImpl);
        binaryModule = BinaryModule(binaryModuleProxy);
        binaryModule.initialize(owner, admin);

        // --- NegRiskModule ---
        negRiskModuleImpl = address(
            new NegRiskModule(address(positionManager), address(0), address(0), address(0), ResolutionChain.POLYGON)
        );
        address negRiskModuleProxy = LibClone.deployERC1967(negRiskModuleImpl);
        negRiskModule = NegRiskModule(negRiskModuleProxy);
        negRiskModule.initialize(owner, admin);

        // --- CombinatorialModule ---
        combinatorialModuleImpl = address(new CombinatorialModule(address(positionManager)));
        address combinatorialModuleProxy = LibClone.deployERC1967(combinatorialModuleImpl);
        combinatorialModule = CombinatorialModule(combinatorialModuleProxy);
        combinatorialModule.initialize(owner, admin);
    }

    /*--------------------------------------------------------------
                          HELPER FUNCTIONS
    --------------------------------------------------------------*/

    function _computeRoleSlot(address _user) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x0c, _EXPECTED_ROLE_SLOT_SEED)
            mstore(0x00, _user)
            slot := keccak256(0x0c, 0x20)
        }
    }

    function _computeHandoverSlot(address _user) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x0c, _EXPECTED_HANDOVER_SLOT_SEED)
            mstore(0x00, _user)
            slot := keccak256(0x0c, 0x20)
        }
    }

    function _computeERC1155BalanceSlot(address _owner, uint256 _id) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x20, _EXPECTED_ERC1155_MASTER_SLOT_SEED)
            mstore(0x14, _owner)
            mstore(0x00, _id)
            slot := keccak256(0x00, 0x40)
        }
    }

    function _computeERC1155ApprovalSlot(address _owner, address _operator) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x20, _EXPECTED_ERC1155_MASTER_SLOT_SEED)
            mstore(0x14, _owner)
            mstore(0x00, _operator)
            slot := keccak256(0x0c, 0x34)
        }
    }

    function _computeERC20BalanceSlot(address _owner) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x0c, _EXPECTED_BALANCE_SLOT_SEED)
            mstore(0x00, _owner)
            slot := keccak256(0x0c, 0x20)
        }
    }

    function _computeERC20AllowanceSlot(address _owner, address _spender) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x20, _spender)
            mstore(0x0c, _EXPECTED_ALLOWANCE_SLOT_SEED)
            mstore(0x00, _owner)
            slot := keccak256(0x0c, 0x34)
        }
    }

    function _computeERC20NoncesSlot(address _owner) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x0c, _EXPECTED_NONCES_SLOT_SEED)
            mstore(0x00, _owner)
            slot := keccak256(0x0c, 0x20)
        }
    }
}

/*--------------------------------------------------------------
              SOLADY SHARED SLOTS (PURE COMPUTATION)
--------------------------------------------------------------*/

contract StorageSlotsTest_soladySharedSlots is StorageSlotsTest {
    function test_erc1967ImplementationSlot() public pure {
        bytes32 actual = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assertEq(actual, _EXPECTED_ERC1967_IMPL_SLOT);
    }

    function test_initializableSlot() public pure {
        bytes32 actual = bytes32(~uint256(uint32(bytes4(keccak256("_INITIALIZABLE_SLOT")))));
        assertEq(actual, _EXPECTED_INITIALIZABLE_SLOT);
    }

    function test_ownerSlot() public pure {
        bytes32 actual = bytes32(~uint256(uint32(bytes4(keccak256("_OWNER_SLOT_NOT")))));
        assertEq(actual, _EXPECTED_OWNER_SLOT);
    }

    function test_handoverSlotSeed() public {
        // Verify by triggering requestOwnershipHandover and checking the
        // derived slot
        PositionManager pm = PositionManager(LibClone.deployERC1967(address(new PositionManager(address(1)))));
        pm.initialize(address(this), address(this));

        address requester = address(0xBEEF);
        vm.prank(requester);
        pm.requestOwnershipHandover();

        bytes32 handoverSlot;
        assembly {
            mstore(0x0c, _EXPECTED_HANDOVER_SLOT_SEED)
            mstore(0x00, requester)
            handoverSlot := keccak256(0x0c, 0x20)
        }

        uint256 storedExpiry = uint256(vm.load(address(pm), handoverSlot));
        assertGt(storedExpiry, 0);
    }

    function test_roleSlotSeed() public pure {
        // _ROLE_SLOT_SEED equals _OWNER_SLOT_NOT in Solady
        uint32 actual = uint32(bytes4(keccak256("_OWNER_SLOT_NOT")));
        assertEq(actual, _EXPECTED_ROLE_SLOT_SEED);
    }
}

/*--------------------------------------------------------------
              POSITION MANAGER STORAGE SLOTS
--------------------------------------------------------------*/

contract StorageSlotsTest_positionManager is StorageSlotsTest {
    function test_implementationStoredInSlot() public view {
        bytes32 stored = vm.load(address(positionManager), _EXPECTED_ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), positionManagerImpl);
    }

    function test_ownerStoredInSlot() public view {
        bytes32 stored = vm.load(address(positionManager), _EXPECTED_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), owner);
    }

    function test_roleStoredInSlot() public view {
        // admin was granted _ROLE_0 (= 1) during initialize
        bytes32 roleSlot = _computeRoleSlot(admin);
        uint256 storedRoles = uint256(vm.load(address(positionManager), roleSlot));
        assertEq(storedRoles, 1); // _ROLE_0 = 1 << 0
    }

    function test_handoverStoredInSlot() public {
        vm.prank(alice);
        positionManager.requestOwnershipHandover();

        bytes32 handoverSlot = _computeHandoverSlot(alice);
        uint256 storedExpiry = uint256(vm.load(address(positionManager), handoverSlot));
        assertGt(storedExpiry, 0);
    }

    function test_erc1155BalanceStoredInSlot() public {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(uint256(1)));
        uint256 positionId = moduleMock.getPositionId(conditionId, 0);
        uint256 amount = 500;

        moduleMock.mint(alice, conditionId, 0, amount);

        bytes32 balanceSlot = _computeERC1155BalanceSlot(alice, positionId);
        uint256 storedBalance = uint256(vm.load(address(positionManager), balanceSlot));
        assertEq(storedBalance, amount);
    }

    function test_erc1155ApprovalStoredInSlot() public {
        vm.prank(alice);
        positionManager.setApprovalForAll(brian, true);

        bytes32 approvalSlot = _computeERC1155ApprovalSlot(alice, brian);
        uint256 storedApproval = uint256(vm.load(address(positionManager), approvalSlot));
        assertEq(storedApproval, 1);
    }
}

/*--------------------------------------------------------------
              COLLATERAL TOKEN STORAGE SLOTS
--------------------------------------------------------------*/

contract StorageSlotsTest_collateralToken is StorageSlotsTest {
    function test_implementationStoredInSlot() public view {
        bytes32 stored = vm.load(address(collateralToken), _EXPECTED_ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), collateralTokenImpl);
    }

    function test_ownerStoredInSlot() public view {
        bytes32 stored = vm.load(address(collateralToken), _EXPECTED_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), owner);
    }

    function test_roleStoredInSlot() public {
        vm.prank(owner);
        collateralToken.addMinter(alice);

        bytes32 roleSlot = _computeRoleSlot(alice);
        uint256 storedRoles = uint256(vm.load(address(collateralToken), roleSlot));
        assertEq(storedRoles, 1); // MINTER_ROLE = _ROLE_0 = 1 << 0
    }

    function test_totalSupplyStoredInSlot() public {
        uint256 amount = 1000;

        vm.prank(owner);
        collateralToken.addMinter(address(this));
        collateralToken.mint(alice, amount);

        uint256 storedSupply = uint256(vm.load(address(collateralToken), bytes32(_EXPECTED_TOTAL_SUPPLY_SLOT)));
        assertEq(storedSupply, amount);
    }

    function test_balanceStoredInSlot() public {
        uint256 amount = 1000;

        vm.prank(owner);
        collateralToken.addMinter(address(this));
        collateralToken.mint(alice, amount);

        bytes32 balanceSlot = _computeERC20BalanceSlot(alice);
        uint256 storedBalance = uint256(vm.load(address(collateralToken), balanceSlot));
        assertEq(storedBalance, amount);
    }

    function test_allowanceStoredInSlot() public {
        uint256 amount = 100;

        vm.prank(alice);
        collateralToken.approve(brian, amount);

        bytes32 allowanceSlot = _computeERC20AllowanceSlot(alice, brian);
        uint256 storedAllowance = uint256(vm.load(address(collateralToken), allowanceSlot));
        assertEq(storedAllowance, amount);
    }

    function test_noncesStoredInSlot() public {
        bytes32 noncesSlot = _computeERC20NoncesSlot(alice);

        // Write a known value to the computed slot, then verify via the
        // public nonces() getter. If the slot formula were wrong, nonces()
        // would still return 0.
        vm.store(address(collateralToken), noncesSlot, bytes32(uint256(42)));
        assertEq(collateralToken.nonces(alice), 42);
    }
}

/*--------------------------------------------------------------
              ORACLE AGGREGATOR STORAGE SLOTS
--------------------------------------------------------------*/

contract StorageSlotsTest_oracleAggregator is StorageSlotsTest {
    function test_implementationStoredInSlot() public view {
        bytes32 stored = vm.load(address(oracleAggregator), _EXPECTED_ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), oracleAggregatorImpl);
    }

    function test_ownerStoredInSlot() public view {
        bytes32 stored = vm.load(address(oracleAggregator), _EXPECTED_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), owner);
    }

    function test_roleStoredInSlot() public {
        vm.prank(owner);
        oracleAggregator.addAdmin(alice);

        bytes32 roleSlot = _computeRoleSlot(alice);
        uint256 storedRoles = uint256(vm.load(address(oracleAggregator), roleSlot));
        assertEq(storedRoles, 1); // _ROLE_0 = 1 << 0
    }

    function test_globalPausedStoredInSlot() public {
        vm.prank(owner);
        oracleAggregator.addAdmin(address(this));

        oracleAggregator.pauseOracle();

        // globalPaused is at slot 0 (first state variable from Pausable)
        uint256 storedPaused = uint256(vm.load(address(oracleAggregator), bytes32(uint256(0))));
        assertEq(storedPaused, 1);
    }
}

/*--------------------------------------------------------------
              OO REPORTER MODULE STORAGE SLOTS
--------------------------------------------------------------*/

contract StorageSlotsTest_ooReporterModule is StorageSlotsTest {
    function test_implementationStoredInSlot() public view {
        bytes32 stored = vm.load(address(ooReporterModule), _EXPECTED_ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), ooReporterModuleImpl);
    }

    function test_ownerStoredInSlot() public view {
        bytes32 stored = vm.load(address(ooReporterModule), _EXPECTED_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), owner);
    }

    function test_roleStoredInSlot() public view {
        bytes32 roleSlot = _computeRoleSlot(admin);
        uint256 storedRoles = uint256(vm.load(address(ooReporterModule), roleSlot));
        assertEq(storedRoles, 1); // ADMIN_ROLE = _ROLE_0 = 1 << 0
    }

    function test_aggregatorStoredInSlotZero() public view {
        bytes32 stored = vm.load(address(ooReporterModule), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(stored))), address(oracleAggregator));
    }

    // `ooReporter` is immutable (baked into the implementation bytecode), so it occupies no proxy
    // storage slot; `OOReporterModuleTest_initializer.test_constructor` verifies its value instead.
}

/*--------------------------------------------------------------
                 BINARY MODULE STORAGE SLOTS
--------------------------------------------------------------*/

contract StorageSlotsTest_binaryModule is StorageSlotsTest {
    function test_implementationStoredInSlot() public view {
        bytes32 stored = vm.load(address(binaryModule), _EXPECTED_ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), binaryModuleImpl);
    }

    function test_ownerStoredInSlot() public view {
        bytes32 stored = vm.load(address(binaryModule), _EXPECTED_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), owner);
    }

    function test_roleStoredInSlot() public view {
        bytes32 roleSlot = _computeRoleSlot(admin);
        uint256 storedRoles = uint256(vm.load(address(binaryModule), roleSlot));
        assertEq(storedRoles, 1); // _ROLE_0 = 1 << 0
    }
}

/*--------------------------------------------------------------
                NEGRISK MODULE STORAGE SLOTS
--------------------------------------------------------------*/

contract StorageSlotsTest_negRiskModule is StorageSlotsTest {
    function test_implementationStoredInSlot() public view {
        bytes32 stored = vm.load(address(negRiskModule), _EXPECTED_ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), negRiskModuleImpl);
    }

    function test_ownerStoredInSlot() public view {
        bytes32 stored = vm.load(address(negRiskModule), _EXPECTED_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), owner);
    }

    function test_roleStoredInSlot() public view {
        bytes32 roleSlot = _computeRoleSlot(admin);
        uint256 storedRoles = uint256(vm.load(address(negRiskModule), roleSlot));
        assertEq(storedRoles, 1); // _ROLE_0 = 1 << 0
    }
}

/*--------------------------------------------------------------
            COMBINATORIAL MODULE STORAGE SLOTS
--------------------------------------------------------------*/

contract StorageSlotsTest_combinatorialModule is StorageSlotsTest {
    function test_implementationStoredInSlot() public view {
        bytes32 stored = vm.load(address(combinatorialModule), _EXPECTED_ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), combinatorialModuleImpl);
    }

    function test_ownerStoredInSlot() public view {
        bytes32 stored = vm.load(address(combinatorialModule), _EXPECTED_OWNER_SLOT);
        assertEq(address(uint160(uint256(stored))), owner);
    }

    function test_roleStoredInSlot() public view {
        bytes32 roleSlot = _computeRoleSlot(admin);
        uint256 storedRoles = uint256(vm.load(address(combinatorialModule), roleSlot));
        assertEq(storedRoles, 1); // _ROLE_0 = 1 << 0
    }
}

