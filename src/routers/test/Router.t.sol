// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { Ownable } from "@solady/src/auth/Ownable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";
import { CallContextChecker } from "@solady/src/utils/CallContextChecker.sol";

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import {
    Collateral,
    Positions,
    PositionManagerSetup
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { Router, RouterErrors } from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

contract Router_Test is TestHelper, RouterErrors {
    Positions positions;
    Collateral collateral;

    Router router;

    function setUp() public virtual {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);

        router = RouterSetup.deployRouter(address(positions.manager), owner);
    }
}

/*--------------------------------------------------------------
                          INITIALIZE
--------------------------------------------------------------*/

contract Router_Test_initialize is Router_Test {
    function test_initialize_setsOwner() public view {
        assertEq(router.owner(), owner);
    }

    function test_revert_initialize_zeroOwner() public {
        address impl = address(new Router(address(positions.manager)));
        address proxy = LibClone.deployERC1967(impl);

        vm.expectRevert(InvalidOwner.selector);
        Router(proxy).initialize(address(0));
    }

    function test_revert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        router.initialize(alice);
    }

    function test_revert_initialize_onImplementation() public {
        address impl = address(new Router(address(positions.manager)));
        // `onlyProxy` reverts before `initializer` is checked; either modifier alone is
        // sufficient to lock the impl, but `onlyProxy` is the outer guard so it fires first.
        vm.expectRevert(CallContextChecker.UnauthorizedCallContext.selector);
        Router(impl).initialize(alice);
    }
}

/*--------------------------------------------------------------
                       AUTHORIZE UPGRADE
--------------------------------------------------------------*/

contract Router_Test_authorizeUpgrade is Router_Test {
    function test_upgrade_ownerSucceeds() public {
        // Owner can upgrade to any impl, including one pinning a different PositionManager.
        (Positions memory otherPositions,,) = PositionManagerSetup._deploy(owner, admin, creator);
        address newImpl = address(new Router(address(otherPositions.manager)));
        vm.prank(owner);
        router.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(new Router(address(positions.manager)));
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        router.upgradeToAndCall(newImpl, "");
    }
}
