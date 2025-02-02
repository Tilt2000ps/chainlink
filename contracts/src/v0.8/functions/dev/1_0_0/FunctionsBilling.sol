// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IFunctionsRouter} from "./interfaces/IFunctionsRouter.sol";
import {IFunctionsSubscriptions} from "./interfaces/IFunctionsSubscriptions.sol";
import {AggregatorV3Interface} from "../../../interfaces/AggregatorV3Interface.sol";
import {IFunctionsBilling} from "./interfaces/IFunctionsBilling.sol";
import {IFunctionsRouter} from "./interfaces/IFunctionsRouter.sol";

import {Routable} from "./Routable.sol";
import {FunctionsResponse} from "./libraries/FunctionsResponse.sol";

/**
 * @title Functions Billing contract
 * @notice Contract that calculates payment from users to the nodes of the Decentralized Oracle Network (DON).
 * @dev THIS CONTRACT HAS NOT GONE THROUGH ANY SECURITY REVIEW. DO NOT USE IN PROD.
 */
abstract contract FunctionsBilling is Routable, IFunctionsBilling {
  using FunctionsResponse for FunctionsResponse.Commitment;
  using FunctionsResponse for FunctionsResponse.FulfillResult;

  uint32 private constant REASONABLE_GAS_PRICE_CEILING = 1_000_000;
  // ================================================================
  // |                  Request Commitment state                    |
  // ================================================================

  mapping(bytes32 requestId => bytes32 commitmentHash) private s_requestCommitments;

  event CommitmentDeleted(bytes32 requestId);

  // ================================================================
  // |                     Configuration state                      |
  // ================================================================

  struct Config {
    // Maximum amount of gas that can be given to a request's client callback
    uint32 maxCallbackGasLimit;
    // How long before we consider the feed price to be stale
    // and fallback to fallbackNativePerUnitLink.
    uint32 feedStalenessSeconds;
    // Represents the average gas execution cost before the fulfillment callback.
    // This amount is always billed for every request
    uint32 gasOverheadBeforeCallback;
    // Represents the average gas execution cost after the fulfillment callback.
    // This amount is always billed for every request
    uint32 gasOverheadAfterCallback;
    // How many seconds it takes before we consider a request to be timed out
    uint32 requestTimeoutSeconds;
    // Additional flat fee (in Juels of LINK) that will be split between Node Operators
    // Max value is 2^80 - 1 == 1.2m LINK.
    uint80 donFee;
    // The highest support request data version supported by the node
    // All lower versions should also be supported
    uint16 maxSupportedRequestDataVersion;
    // Percentage of gas price overestimation to account for changes in gas price between request and response
    // Held as basis points (one hundredth of 1 percentage point)
    uint256 fulfillmentGasPriceOverEstimationBP;
    // fallback NATIVE CURRENCY / LINK conversion rate if the data feed is stale
    int256 fallbackNativePerUnitLink;
  }

  Config private s_config;

  event ConfigUpdated(Config config);

  error UnsupportedRequestDataVersion();
  error InsufficientBalance();
  error InvalidSubscription();
  error UnauthorizedSender();
  error MustBeSubOwner(address owner);
  error InvalidLinkWeiPrice(int256 linkWei);
  error PaymentTooLarge();
  error NoTransmittersSet();
  error InvalidCalldata();

  // ================================================================
  // |                        Balance state                         |
  // ================================================================

  mapping(address transmitter => uint96 balanceJuelsLink) private s_withdrawableTokens;
  // Pool together collected DON fees
  // Disperse them on withdrawal or change in OCR configuration
  uint96 internal s_feePool;

  AggregatorV3Interface private s_linkToNativeFeed;

  // ================================================================
  // |                       Initialization                         |
  // ================================================================
  constructor(address router, Config memory config, address linkToNativeFeed) Routable(router) {
    s_linkToNativeFeed = AggregatorV3Interface(linkToNativeFeed);

    updateConfig(config);
  }

  // ================================================================
  // |                        Configuration                         |
  // ================================================================

  // @notice Gets the Chainlink Coordinator's billing configuration
  // @return config
  function getConfig() external view returns (Config memory) {
    return s_config;
  }

  // @notice Sets the Chainlink Coordinator's billing configuration
  // @param config - See the contents of the Config struct in IFunctionsBilling.Config for more information
  function updateConfig(Config memory config) public {
    _onlyOwner();

    if (config.fallbackNativePerUnitLink <= 0) {
      revert InvalidLinkWeiPrice(config.fallbackNativePerUnitLink);
    }

    s_config = config;
    emit ConfigUpdated(config);
  }

  // ================================================================
  // |                       Fee Calculation                        |
  // ================================================================

  // @inheritdoc IFunctionsBilling
  function getDONFee(
    bytes memory /* requestData */,
    RequestBilling memory /* billing */
  ) public view override returns (uint80) {
    // NOTE: Optionally, compute additional fee here
    return s_config.donFee;
  }

  // @inheritdoc IFunctionsBilling
  function getAdminFee() public view override returns (uint96) {
    return _getRouter().getAdminFee();
  }

  // @inheritdoc IFunctionsBilling
  function getWeiPerUnitLink() public view returns (uint256) {
    Config memory config = s_config;
    (, int256 weiPerUnitLink, , uint256 timestamp, ) = s_linkToNativeFeed.latestRoundData();
    // solhint-disable-next-line not-rely-on-time
    if (config.feedStalenessSeconds < block.timestamp - timestamp && config.feedStalenessSeconds > 0) {
      return uint256(config.fallbackNativePerUnitLink);
    }
    if (weiPerUnitLink <= 0) {
      revert InvalidLinkWeiPrice(weiPerUnitLink);
    }
    return uint256(weiPerUnitLink);
  }

  function _getJuelsPerGas(uint256 gasPriceGwei) private view returns (uint256) {
    // (1e18 juels/link) * (wei/gas) / (wei/link) = juels per gas
    return (1e18 * gasPriceGwei) / getWeiPerUnitLink();
  }

  // ================================================================
  // |                       Cost Estimation                        |
  // ================================================================

  // @inheritdoc IFunctionsBilling
  function estimateCost(
    uint64 subscriptionId,
    bytes calldata data,
    uint32 callbackGasLimit,
    uint256 gasPriceGwei
  ) external view override returns (uint96) {
    _getRouter().isValidCallbackGasLimit(subscriptionId, callbackGasLimit);
    // Reasonable ceilings to prevent integer overflows
    if (gasPriceGwei > REASONABLE_GAS_PRICE_CEILING) {
      revert InvalidCalldata();
    }
    uint96 adminFee = getAdminFee();
    uint96 donFee = getDONFee(
      data,
      RequestBilling({
        subscriptionId: subscriptionId,
        client: msg.sender,
        callbackGasLimit: callbackGasLimit,
        expectedGasPriceGwei: gasPriceGwei,
        adminFee: adminFee
      })
    );
    return _calculateCostEstimate(callbackGasLimit, gasPriceGwei, donFee, adminFee);
  }

  // @notice Estimate the cost in Juels of LINK
  // that will be charged to a subscription to fulfill a Functions request
  // Gas Price can be overestimated to account for flucuations between request and response time
  function _calculateCostEstimate(
    uint32 callbackGasLimit,
    uint256 gasPriceGwei,
    uint96 donFee,
    uint96 adminFee
  ) internal view returns (uint96) {
    uint256 executionGas = s_config.gasOverheadBeforeCallback + s_config.gasOverheadAfterCallback + callbackGasLimit;

    uint256 gasPriceWithOverestimation = gasPriceGwei +
      ((gasPriceGwei * s_config.fulfillmentGasPriceOverEstimationBP) / 10_000);
    // @NOTE: Basis Points are 1/100th of 1%, divide by 10_000 to bring back to original units

    uint256 juelsPerGas = _getJuelsPerGas(gasPriceWithOverestimation);
    uint256 estimatedGasReimbursement = juelsPerGas * executionGas;
    uint256 fees = uint256(donFee) + uint256(adminFee);

    return uint96(estimatedGasReimbursement + fees);
  }

  // ================================================================
  // |                           Billing                            |
  // ================================================================

  // @notice Initiate the billing process for an Functions request
  // @dev Only callable by the Functions Router
  // @param data - Encoded Chainlink Functions request data, use FunctionsClient API to encode a request
  // @param requestDataVersion - Version number of the structure of the request data
  // @param billing - Billing configuration for the request
  // @return commitment - The parameters of the request that must be held consistent at response time
  function _startBilling(
    bytes memory data,
    uint16 requestDataVersion,
    RequestBilling memory billing
  ) internal returns (FunctionsResponse.Commitment memory commitment) {
    Config memory config = s_config;

    // Nodes should support all past versions of the structure
    if (requestDataVersion > config.maxSupportedRequestDataVersion) {
      revert UnsupportedRequestDataVersion();
    }

    // Check that subscription can afford the estimated cost
    uint80 donFee = getDONFee(data, billing);
    uint96 estimatedCost = _calculateCostEstimate(
      billing.callbackGasLimit,
      billing.expectedGasPriceGwei,
      donFee,
      billing.adminFee
    );
    IFunctionsSubscriptions routerWithSubscriptions = IFunctionsSubscriptions(address(_getRouter()));
    IFunctionsSubscriptions.Subscription memory subscription = routerWithSubscriptions.getSubscription(
      billing.subscriptionId
    );
    if ((subscription.balance - subscription.blockedBalance) < estimatedCost) {
      revert InsufficientBalance();
    }

    (, uint64 initiatedRequests, ) = routerWithSubscriptions.getConsumer(billing.client, billing.subscriptionId);

    bytes32 requestId = _computeRequestId(address(this), billing.client, billing.subscriptionId, initiatedRequests + 1);

    commitment = FunctionsResponse.Commitment({
      adminFee: billing.adminFee,
      coordinator: address(this),
      client: billing.client,
      subscriptionId: billing.subscriptionId,
      callbackGasLimit: billing.callbackGasLimit,
      estimatedTotalCostJuels: estimatedCost,
      timeoutTimestamp: uint40(block.timestamp + config.requestTimeoutSeconds),
      requestId: requestId,
      donFee: donFee,
      gasOverheadBeforeCallback: config.gasOverheadBeforeCallback,
      gasOverheadAfterCallback: config.gasOverheadAfterCallback
    });

    s_requestCommitments[requestId] = keccak256(abi.encode(commitment));

    return commitment;
  }

  // @notice Generate a keccak hash request ID
  function _computeRequestId(
    address don,
    address client,
    uint64 subscriptionId,
    uint64 nonce
  ) private pure returns (bytes32) {
    return keccak256(abi.encode(don, client, subscriptionId, nonce));
  }

  // @notice Finalize billing process for an Functions request by sending a callback to the Client contract and then charging the subscription
  // @param requestId identifier for the request that was generated by the Registry in the beginBilling commitment
  // @param response response data from DON consensus
  // @param err error from DON consensus
  // @return result fulfillment result
  // @dev Only callable by a node that has been approved on the Coordinator
  // @dev simulated offchain to determine if sufficient balance is present to fulfill the request
  function _fulfillAndBill(
    bytes32 requestId,
    bytes memory response,
    bytes memory err,
    bytes memory onchainMetadata,
    bytes memory /* offchainMetadata TODO: use in getDonFee() for dynamic billing */
  ) internal returns (FunctionsResponse.FulfillResult) {
    FunctionsResponse.Commitment memory commitment = abi.decode(onchainMetadata, (FunctionsResponse.Commitment));

    if (s_requestCommitments[requestId] != keccak256(abi.encode(commitment))) {
      return FunctionsResponse.FulfillResult.INVALID_COMMITMENT;
    }

    if (s_requestCommitments[requestId] == bytes32(0)) {
      return FunctionsResponse.FulfillResult.INVALID_REQUEST_ID;
    }

    uint256 juelsPerGas = _getJuelsPerGas(tx.gasprice);
    // Gas overhead without callback
    uint96 gasOverheadJuels = uint96(
      juelsPerGas * (commitment.gasOverheadBeforeCallback + commitment.gasOverheadAfterCallback)
    );

    // The Functions Router will perform the callback to the client contract
    (FunctionsResponse.FulfillResult resultCode, uint96 callbackCostJuels) = _getRouter().fulfill(
      response,
      err,
      uint96(juelsPerGas),
      gasOverheadJuels + commitment.donFee, // costWithoutFulfillment
      msg.sender,
      commitment
    );

    // The router will only pay the DON on successfully processing the fulfillment
    // In these two fulfillment results the user has been charged
    // Otherwise, the Coordinator should hold on to the request commitment
    if (
      resultCode == FunctionsResponse.FulfillResult.USER_SUCCESS ||
      resultCode == FunctionsResponse.FulfillResult.USER_ERROR
    ) {
      delete s_requestCommitments[requestId];
      // Reimburse the transmitter for the fulfillment gas cost
      s_withdrawableTokens[msg.sender] = gasOverheadJuels + callbackCostJuels;
      // Put donFee into the pool of fees, to be split later
      // Saves on storage writes that would otherwise be charged to the user
      s_feePool += commitment.donFee;
    }

    return resultCode;
  }

  // ================================================================
  // |                       Request Timeout                        |
  // ================================================================

  // @inheritdoc IFunctionsBilling
  // @dev Only callable by the Router
  // @dev Used by FunctionsRouter.sol during timeout of a request
  function deleteCommitment(bytes32 requestId) external override onlyRouter returns (bool) {
    // Ensure that commitment exists
    if (s_requestCommitments[requestId] == bytes32(0)) {
      return false;
    }
    // Delete commitment
    delete s_requestCommitments[requestId];
    emit CommitmentDeleted(requestId);
    return true;
  }

  // ================================================================
  // |                    Fund withdrawal                           |
  // ================================================================

  // @inheritdoc IFunctionsBilling
  function oracleWithdraw(address recipient, uint96 amount) external {
    _disperseFeePool();

    if (amount == 0) {
      amount = s_withdrawableTokens[msg.sender];
    } else if (s_withdrawableTokens[msg.sender] < amount) {
      revert InsufficientBalance();
    }
    s_withdrawableTokens[msg.sender] -= amount;
    IFunctionsSubscriptions(address(_getRouter())).oracleWithdraw(recipient, amount);
  }

  // @inheritdoc IFunctionsBilling
  // @dev Only callable by the Coordinator owner
  function oracleWithdrawAll() external {
    _onlyOwner();
    _disperseFeePool();

    address[] memory transmitters = _getTransmitters();

    // Bounded by "maxNumOracles" on OCR2Abstract.sol
    for (uint256 i = 0; i < transmitters.length; ++i) {
      uint96 balance = s_withdrawableTokens[msg.sender];
      s_withdrawableTokens[msg.sender] = 0;
      IFunctionsSubscriptions(address(_getRouter())).oracleWithdraw(transmitters[i], balance);
    }
  }

  // Overriden in FunctionsCoordinator, which has visibility into transmitters
  function _getTransmitters() internal view virtual returns (address[] memory);

  // DON fees are collected into a pool s_feePool
  // When OCR configuration changes, or any oracle withdraws, this must be dispersed
  function _disperseFeePool() internal {
    if (s_feePool == 0) {
      return;
    }
    // All transmitters are assumed to also be observers
    // Pay out the DON fee to all transmitters
    address[] memory transmitters = _getTransmitters();
    if (transmitters.length == 0) {
      revert NoTransmittersSet();
    }
    uint96 feePoolShare = s_feePool / uint96(transmitters.length);
    // Bounded by "maxNumOracles" on OCR2Abstract.sol
    for (uint256 i = 0; i < transmitters.length; ++i) {
      s_withdrawableTokens[transmitters[i]] += feePoolShare;
    }
    s_feePool -= feePoolShare * uint96(transmitters.length);
  }

  // Overriden in FunctionsCoordinator.sol
  function _onlyOwner() internal view virtual;
}
