// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IFunctionsCoordinator} from "./interfaces/IFunctionsCoordinator.sol";
import {IFunctionsBilling} from "./interfaces/IFunctionsBilling.sol";
import {ITypeAndVersion} from "../../../shared/interfaces/ITypeAndVersion.sol";

import {FunctionsBilling} from "./FunctionsBilling.sol";
import {OCR2Base} from "./ocr/OCR2Base.sol";
import {FunctionsResponse} from "./libraries/FunctionsResponse.sol";

// @title Functions Coordinator contract
// @notice Contract that nodes of a Decentralized Oracle Network (DON) interact with
// @dev THIS CONTRACT HAS NOT GONE THROUGH ANY SECURITY REVIEW. DO NOT USE IN PROD.
contract FunctionsCoordinator is OCR2Base, IFunctionsCoordinator, FunctionsBilling {
  using FunctionsResponse for FunctionsResponse.Commitment;
  using FunctionsResponse for FunctionsResponse.FulfillResult;

  // @inheritdoc ITypeAndVersion
  string public constant override typeAndVersion = "Functions Coordinator v1.0.0";

  event OracleRequest(
    bytes32 indexed requestId,
    address indexed requestingContract,
    address requestInitiator,
    uint64 subscriptionId,
    address subscriptionOwner,
    bytes data,
    uint16 dataVersion,
    bytes32 flags,
    uint64 callbackGasLimit,
    bytes commitment
  );
  event OracleResponse(bytes32 indexed requestId, address transmitter);

  error EmptyRequestData();
  error InconsistentReportData();
  error EmptyPublicKey();
  error UnauthorizedPublicKeyChange();

  bytes private s_donPublicKey;
  mapping(address signerAddress => bytes publicKey) private s_nodePublicKeys;
  bytes private s_thresholdPublicKey;

  constructor(
    address router,
    Config memory config,
    address linkToNativeFeed
  ) OCR2Base(true) FunctionsBilling(router, config, linkToNativeFeed) {}

  // @inheritdoc IFunctionsCoordinator
  function getThresholdPublicKey() external view override returns (bytes memory) {
    if (s_thresholdPublicKey.length == 0) {
      revert EmptyPublicKey();
    }
    return s_thresholdPublicKey;
  }

  // @inheritdoc IFunctionsCoordinator
  function setThresholdPublicKey(bytes calldata thresholdPublicKey) external override onlyOwner {
    if (thresholdPublicKey.length == 0) {
      revert EmptyPublicKey();
    }
    s_thresholdPublicKey = thresholdPublicKey;
  }

  // @inheritdoc IFunctionsCoordinator
  function getDONPublicKey() external view override returns (bytes memory) {
    if (s_donPublicKey.length == 0) {
      revert EmptyPublicKey();
    }
    return s_donPublicKey;
  }

  // @inheritdoc IFunctionsCoordinator
  function setDONPublicKey(bytes calldata donPublicKey) external override onlyOwner {
    if (donPublicKey.length == 0) {
      revert EmptyPublicKey();
    }
    s_donPublicKey = donPublicKey;
  }

  // @dev check if node is in current transmitter list
  function _isTransmitter(address node) internal view returns (bool) {
    address[] memory nodes = s_transmitters;
    // Bounded by "maxNumOracles" on OCR2Abstract.sol
    for (uint256 i = 0; i < nodes.length; ++i) {
      if (nodes[i] == node) {
        return true;
      }
    }
    return false;
  }

  // @inheritdoc IFunctionsCoordinator
  function setNodePublicKey(address node, bytes calldata publicKey) external override {
    // Owner can set anything. Transmitters can set only their own key.
    if (!(msg.sender == owner() || (_isTransmitter(msg.sender) && msg.sender == node))) {
      revert UnauthorizedPublicKeyChange();
    }
    s_nodePublicKeys[node] = publicKey;
  }

  // @inheritdoc IFunctionsCoordinator
  function deleteNodePublicKey(address node) external override {
    // Owner can delete anything. Others can delete only their own key.
    if (msg.sender != owner() && msg.sender != node) {
      revert UnauthorizedPublicKeyChange();
    }
    delete s_nodePublicKeys[node];
  }

  // @inheritdoc IFunctionsCoordinator
  function getAllNodePublicKeys() external view override returns (address[] memory, bytes[] memory) {
    address[] memory nodes = s_transmitters;
    bytes[] memory keys = new bytes[](nodes.length);
    // Bounded by "maxNumOracles" on OCR2Abstract.sol
    for (uint256 i = 0; i < nodes.length; ++i) {
      bytes memory nodePublicKey = s_nodePublicKeys[nodes[i]];
      if (nodePublicKey.length == 0) {
        revert EmptyPublicKey();
      }
      keys[i] = nodePublicKey;
    }
    return (nodes, keys);
  }

  // @inheritdoc IFunctionsCoordinator
  function sendRequest(
    Request calldata request
  ) external override onlyRouter returns (FunctionsResponse.Commitment memory commitment) {
    if (request.data.length == 0) {
      revert EmptyRequestData();
    }

    RequestBilling memory billing = RequestBilling({
      subscriptionId: request.subscriptionId,
      client: request.requestingContract,
      callbackGasLimit: request.callbackGasLimit,
      expectedGasPriceGwei: tx.gasprice,
      adminFee: request.adminFee
    });

    commitment = _startBilling(request.data, request.dataVersion, billing);

    emit OracleRequest(
      commitment.requestId,
      request.requestingContract,
      tx.origin,
      request.subscriptionId,
      request.subscriptionOwner,
      request.data,
      request.dataVersion,
      request.flags,
      request.callbackGasLimit,
      abi.encode(commitment)
    );
  }

  // DON fees are pooled together. If the OCR configuration is going to change, these need to be distributed.
  function _beforeSetConfig(uint8 /* _f */, bytes memory /* _onchainConfig */) internal override {
    if (_getTransmitters().length > 0) {
      _disperseFeePool();
    }
  }

  // Used by FunctionsBilling.sol
  function _getTransmitters() internal view override returns (address[] memory) {
    return s_transmitters;
  }

  // Report hook called within OCR2Base.sol
  function _report(
    uint256 /*initialGas*/,
    address /*transmitter*/,
    uint8 /*signerCount*/,
    address[MAX_NUM_ORACLES] memory /*signers*/,
    bytes calldata report
  ) internal override {
    bytes32[] memory requestIds;
    bytes[] memory results;
    bytes[] memory errors;
    bytes[] memory onchainMetadata;
    bytes[] memory offchainMetadata;
    (requestIds, results, errors, onchainMetadata, offchainMetadata) = abi.decode(
      report,
      (bytes32[], bytes[], bytes[], bytes[], bytes[])
    );

    if (
      requestIds.length == 0 ||
      requestIds.length != results.length ||
      requestIds.length != errors.length ||
      requestIds.length != onchainMetadata.length ||
      requestIds.length != offchainMetadata.length
    ) {
      revert ReportInvalid();
    }

    // Bounded by "MaxRequestBatchSize" on the Job's ReportingPluginConfig
    for (uint256 i = 0; i < requestIds.length; ++i) {
      FunctionsResponse.FulfillResult result = FunctionsResponse.FulfillResult(
        _fulfillAndBill(requestIds[i], results[i], errors[i], onchainMetadata[i], offchainMetadata[i])
      );

      // Emit on successfully processing the fulfillment
      // In these two fulfillment results the user has been charged
      // Otherwise, the DON will re-try
      if (
        result == FunctionsResponse.FulfillResult.USER_SUCCESS || result == FunctionsResponse.FulfillResult.USER_ERROR
      ) {
        emit OracleResponse(requestIds[i], msg.sender);
      }
    }
  }

  // Used in FunctionsBilling.sol
  function _onlyOwner() internal view override {
    _validateOwnership();
  }
}
