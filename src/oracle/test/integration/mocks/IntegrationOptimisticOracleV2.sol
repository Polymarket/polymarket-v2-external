// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IOptimisticOracleV2 } from "managed-oracle/pm-v2-oo-reporter/interfaces/IOptimisticOracleV2.sol";
import { IOptimisticRequester } from "managed-oracle/pm-v2-oo-reporter/interfaces/IOptimisticRequester.sol";

/// @notice Minimal Managed OO boundary used to exercise the real OOReporter contract.
/// @dev This mock owns only the external oracle behavior. OOReporter state and callbacks are production code.
contract IntegrationOptimisticOracleV2 is IOptimisticOracleV2 {
    error CallerNotRequesterAdmin();
    error CallerNotResolver();
    error RequesterNotEnabled();

    struct StoredRequest {
        bool requested;
        bool eventBased;
        bool callbackOnPriceDisputed;
        bool callbackOnPriceSettled;
        bool settled;
        IERC20 currency;
        uint256 reward;
        uint256 bond;
        uint256 customLiveness;
        int256 resolvedPrice;
    }

    mapping(bytes32 requestKey => StoredRequest request) internal _requests;
    mapping(IERC20 currency => mapping(address recipient => uint256 amount)) public override deferredPayouts;
    mapping(address requester => bool enabled) public isRequester;

    uint256 public override minimumDisputeWindow = 5 minutes;
    address public immutable requesterAdmin;
    address public immutable resolver;

    constructor(address _requesterAdmin, address _resolver) {
        requesterAdmin = _requesterAdmin;
        resolver = _resolver;
    }

    function setRequesterEnabled(address _requester, bool _enabled) external {
        if (msg.sender != requesterAdmin) revert CallerNotRequesterAdmin();
        isRequester[_requester] = _enabled;
    }

    function requestKey(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(requester, identifier, timestamp, requestRules));
    }

    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory requestRules,
        IERC20 currency,
        uint256 reward
    ) external override returns (uint256 totalBond) {
        if (!isRequester[msg.sender]) revert RequesterNotEnabled();

        StoredRequest storage request = _requests[requestKey(msg.sender, identifier, timestamp, requestRules)];
        require(!request.requested, "already requested");

        request.requested = true;
        request.currency = currency;
        request.reward = reward;

        if (reward != 0) require(currency.transferFrom(msg.sender, address(this), reward), "reward transfer failed");
        return request.bond;
    }

    function setBond(bytes32 identifier, uint256 timestamp, bytes memory requestRules, uint256 bond)
        external
        override
        returns (uint256 totalBond)
    {
        _requests[requestKey(msg.sender, identifier, timestamp, requestRules)].bond = bond;
        return bond;
    }

    function setCustomLiveness(bytes32 identifier, uint256 timestamp, bytes memory requestRules, uint256 liveness)
        external
        override
    {
        require(liveness >= minimumDisputeWindow, "liveness below minimum");
        _requests[requestKey(msg.sender, identifier, timestamp, requestRules)].customLiveness = liveness;
    }

    function setEventBased(bytes32 identifier, uint256 timestamp, bytes memory requestRules) external override {
        _requests[requestKey(msg.sender, identifier, timestamp, requestRules)].eventBased = true;
    }

    function setCallbacks(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory requestRules,
        bool,
        bool callbackOnPriceDisputed,
        bool callbackOnPriceSettled
    ) external override {
        StoredRequest storage request = _requests[requestKey(msg.sender, identifier, timestamp, requestRules)];
        request.callbackOnPriceDisputed = callbackOnPriceDisputed;
        request.callbackOnPriceSettled = callbackOnPriceSettled;
    }

    function getRequest(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        external
        view
        override
        returns (Request memory)
    {
        StoredRequest storage stored = _requests[requestKey(requester, identifier, timestamp, requestRules)];
        RequestSettings memory settings = RequestSettings({
            eventBased: stored.eventBased,
            refundOnDispute: stored.eventBased,
            callbackOnPriceProposed: false,
            callbackOnPriceDisputed: stored.callbackOnPriceDisputed,
            callbackOnPriceSettled: stored.callbackOnPriceSettled,
            bond: stored.bond,
            customLiveness: stored.customLiveness
        });

        return Request({
            proposer: address(0),
            disputer: address(0),
            currency: stored.currency,
            settled: stored.settled,
            requestSettings: settings,
            proposedPrice: 0,
            resolvedPrice: stored.resolvedPrice,
            expirationTime: 0,
            reward: stored.reward,
            finalFee: 0,
            proposalTime: 0
        });
    }

    function claimDeferredPayout(IERC20 currency, address repaymentAddress) external override {
        uint256 amount = deferredPayouts[currency][msg.sender];
        require(amount != 0, "no deferred payout");
        deferredPayouts[currency][msg.sender] = 0;
        require(currency.transfer(repaymentAddress, amount), "deferred payout transfer failed");
    }

    function settle(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules, int256 price)
        external
    {
        if (msg.sender != resolver) revert CallerNotResolver();

        StoredRequest storage request = _requests[requestKey(requester, identifier, timestamp, requestRules)];
        require(request.requested, "not requested");

        request.settled = true;
        request.resolvedPrice = price;
        if (request.callbackOnPriceSettled) {
            IOptimisticRequester(requester).priceSettled(identifier, timestamp, requestRules, price);
        }
    }

    function dispute(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules) external {
        StoredRequest storage request = _requests[requestKey(requester, identifier, timestamp, requestRules)];
        require(request.requested, "not requested");

        if (request.callbackOnPriceDisputed) {
            IOptimisticRequester(requester).priceDisputed(identifier, timestamp, requestRules, 0);
        }
    }
}
