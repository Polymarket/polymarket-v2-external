// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { CCIPReceiver } from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import { OwnableRoles } from "@solady/src/auth/OwnableRoles.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";
import { BridgeBase } from "./abstract/BridgeBase.sol";

/// @title CcipBridge
/// @author Polymarket
/// @notice Chainlink CCIP bridge for cross-chain position and collateral transfers
/// @dev Single contract deployed on all chains (hub and spoke).
///      CCIP does not refund excess msg.value — the router keeps
///      the full amount. Callers should use the quoteBridge*()
///      functions to determine the exact fee before sending.
///      Messaging options are either empty (DEFAULT_GAS_LIMIT) or an
///      abi-encoded uint256 destination gas limit; out-of-order
///      execution is always enforced so a stuck message cannot block
///      the lane for subsequent messages.
///      UUPS-upgradeable; owner authorizes upgrades. Immutables are bytecode-bound on the
///      implementation, so each implementation deployment is parameterized for one
///      (router, positionManager, collateralToken, resolutionChainId, resolutionChainSelector) tuple.
contract CcipBridge is CCIPReceiver, UUPSUpgradeable, Initializable, OwnableRoles, BridgeBase {
    /*--------------------------------------------------------------
                              CONSTANTS
    --------------------------------------------------------------*/

    /// @notice Admin role identifier (can pause/unpause)
    uint256 public constant ADMIN_ROLE = _ROLE_0;

    /// @notice Destination gas limit applied when no options are provided
    uint256 public constant DEFAULT_GAS_LIMIT = 200_000;

    /*--------------------------------------------------------------
                            STATE VARIABLES
    --------------------------------------------------------------*/

    /// @notice CCIP selector of the resolution chain: the only lane an inbound result may arrive on.
    uint256 public immutable RESOLUTION_CHAIN_SELECTOR;

    /// @notice Chain selector => Peer bridge identifier (left-padded address for EVM chains)
    mapping(uint256 => bytes32) public peers;

    /*--------------------------------------------------------------
                                 EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when a peer bridge is set or removed.
    /// @param chainSelector The CCIP chain selector.
    /// @param peer The peer bridge identifier (bytes32(0) if removed).
    event PeerSet(uint256 indexed chainSelector, bytes32 peer);

    /*--------------------------------------------------------------
                                 ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when the sender is not a trusted peer.
    error UnauthorizedSender();
    /// @notice Thrown when the chain selector is invalid.
    error InvalidChainSelector();
    /// @notice Thrown when no peer is set for the chain.
    error PeerNotSet();
    /// @notice Thrown when the peer address is zero.
    error ZeroPeer();
    /// @notice Thrown when the options are neither empty nor an abi-encoded gas limit.
    error InvalidOptions();
    /// @notice Thrown when the resolution chain selector is zero.
    error InvalidResolutionChainSelector();
    /// @notice Thrown when the initializer receives a zero owner.
    error InvalidOwner();
    /// @notice Thrown when the initializer receives a zero admin.
    error InvalidAdmin();

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploys the CCIP bridge implementation.
    /// @param _router Chainlink CCIP router address.
    /// @param _positionManager PositionManager contract address.
    /// @param _collateralToken CollateralToken contract address.
    /// @param _resolutionChainId Chain id of the resolution chain.
    /// @param _resolutionChainSelector CCIP selector of the resolution chain; same on every deployment.
    constructor(
        address _router,
        address _positionManager,
        address _collateralToken,
        uint256 _resolutionChainId,
        uint256 _resolutionChainSelector
    ) CCIPReceiver(_router) BridgeBase(_positionManager, _collateralToken, _resolutionChainId) {
        // Neither could ever be a source chain, so both would refuse every inbound result.
        require(_resolutionChainSelector != 0, InvalidResolutionChainSelector());
        _validateChain(_resolutionChainSelector);

        RESOLUTION_CHAIN_SELECTOR = _resolutionChainSelector;

        _disableInitializers();
    }

    /*--------------------------------------------------------------
                              INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the proxied bridge owner and admin.
    /// @dev Replaces constructor ownership setup for proxy deployments.
    /// @param _owner The owner address.
    /// @param _admin The initial admin address.
    function initialize(address _owner, address _admin) external onlyProxy initializer {
        if (_owner == address(0)) revert InvalidOwner();
        if (_admin == address(0)) revert InvalidAdmin();

        _initializeOwner(_owner);
        _grantRoles(_admin, ADMIN_ROLE);
    }

    /*--------------------------------------------------------------
                           EXTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    // ============ Owner Functions ============

    /// @notice Set the peer bridge on a remote chain
    /// @dev Only callable by the owner. EVM peers are left-padded addresses.
    /// @param _chainSelector CCIP chain selector
    /// @param _peer Identifier of the peer bridge contract
    function setPeer(uint256 _chainSelector, bytes32 _peer) external onlyOwner {
        _validateChain(_chainSelector);
        require(_peer != bytes32(0), ZeroPeer());
        peers[_chainSelector] = _peer;
        emit PeerSet(_chainSelector, _peer);
    }

    /// @notice Remove the peer bridge for a remote chain
    /// @dev Only callable by the owner. Disables the route.
    /// @param _chainSelector CCIP chain selector
    function removePeer(uint256 _chainSelector) external onlyOwner {
        _validateChain(_chainSelector);
        delete peers[_chainSelector];
        emit PeerSet(_chainSelector, bytes32(0));
    }

    /// @notice Grant admin role to an address
    /// @dev Only callable by the owner. Admins can pause/unpause.
    /// @param _admin Address to grant admin role
    function addAdmin(address _admin) external onlyOwner {
        _grantRoles(_admin, ADMIN_ROLE);
    }

    /// @notice Revoke admin role from an address
    /// @dev Only callable by the owner.
    /// @param _admin Address to revoke admin role from
    function removeAdmin(address _admin) external onlyOwner {
        _removeRoles(_admin, ADMIN_ROLE);
    }

    /*--------------------------------------------------------------
                                 VIEW
    --------------------------------------------------------------*/

    /// @notice ERC-165 interface detection for CCIP and ERC1155 token receiver.
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override(CCIPReceiver, ERC1155TokenReceiver)
        returns (bool)
    {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == 0x4e2312e0 // ERC1155TokenReceiver
            || interfaceId == 0x01ffc9a7; // ERC165
    }

    /*--------------------------------------------------------------
                           INTERNAL OVERRIDES
    --------------------------------------------------------------*/

    /// @dev Send a cross-chain message via CCIP.
    ///      The full msg.value is forwarded to the CCIP router,
    ///      which does not refund overpayment.
    /// @return messageId The CCIP message identifier returned by the router.
    function _transportSend(uint256 _dstChain, bytes memory _payload, bytes calldata _options)
        internal
        override
        returns (bytes32 messageId)
    {
        return IRouterClient(getRouter()).ccipSend{ value: msg.value }(
            uint64(_dstChain), _buildMessage(_dstChain, _payload, _options)
        );
    }

    /// @dev Quote the fee for a CCIP message
    function _bridgeQuote(uint256 _dstChain, bytes memory _payload, bytes calldata _options)
        internal
        view
        override
        returns (uint256 nativeFee, uint256 alternativeFee)
    {
        return (IRouterClient(getRouter()).getFee(uint64(_dstChain), _buildMessage(_dstChain, _payload, _options)), 0);
    }

    /// @dev Build a CCIP message, always enforcing out-of-order execution.
    ///      _options is either empty (DEFAULT_GAS_LIMIT) or an abi-encoded uint256 gas limit.
    function _buildMessage(uint256 _dstChain, bytes memory _payload, bytes calldata _options)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        _validateChain(_dstChain);
        bytes32 peer = peers[_dstChain];
        require(peer != bytes32(0), PeerNotSet());

        uint256 gasLimit;
        if (_options.length == 0) gasLimit = DEFAULT_GAS_LIMIT;
        else if (_options.length == 32) gasLimit = abi.decode(_options, (uint256));
        else revert InvalidOptions();

        return Client.EVM2AnyMessage({
            receiver: abi.encode(peer),
            data: _payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({ gasLimit: gasLimit, allowOutOfOrderExecution: true })
            ),
            feeToken: address(0)
        });
    }

    /// @dev Validate CCIP chain selector range
    function _validateChain(uint256 _chain) internal pure override {
        require(_chain != 0 && _chain <= type(uint64).max, InvalidChainSelector());
    }

    /// @dev `_srcChain` arrives as `message.sourceChainSelector`.
    function _isResolutionChainSource(uint256 _srcChain) internal view override returns (bool) {
        return _srcChain == RESOLUTION_CHAIN_SELECTOR;
    }

    /// @dev Only owner for destructive operations
    function _checkBridgeOwner() internal view override {
        _checkOwner();
    }

    /// @dev Admin or owner for pause/unpause
    function _checkBridgeAdmin() internal view override {
        _checkRolesOrOwner(ADMIN_ROLE);
    }

    /*--------------------------------------------------------------
                         UUPS UPGRADE AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner { }

    // ============ Receive Handler ============

    /// @dev Internal function to handle incoming CCIP messages
    function _ccipReceive(Client.Any2EVMMessage memory _message) internal override {
        // Verify sender is a trusted peer
        bytes32 sender = abi.decode(_message.sender, (bytes32));
        require(peers[_message.sourceChainSelector] == sender, UnauthorizedSender());

        // _message.data is mutated in place by _processMessage; do not use it again after this call.
        _processMessage(_message.messageId, _message.sourceChainSelector, _message.data);
    }
}
