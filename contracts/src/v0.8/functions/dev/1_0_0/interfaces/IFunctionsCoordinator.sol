// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FunctionsResponse} from "../libraries/FunctionsResponse.sol";

// @title Chainlink Functions Coordinator interface.
interface IFunctionsCoordinator {
  struct Request {
    address requestingContract; // The client contract that is sending the request
    address subscriptionOwner; // The owner of the billing subscription
    bytes data; // Encoded Chainlink Functions request data, use FunctionsRequest library to encode a request
    uint64 subscriptionId; // Identifier of the billing subscription that will be charged for the request
    uint16 dataVersion; // The version of the structure of the CBOR encoded request data
    bytes32 flags; // Per-subscription account flags
    uint32 callbackGasLimit; // The amount of gas that the callback to the consuming contract will be given
    uint96 adminFee; // Flat fee (in Juels of LINK) that will be paid to the Router Owner for operation of the network
  }

  // @notice Returns the DON's threshold encryption public key used to encrypt secrets
  // @dev All nodes on the DON have separate key shares of the threshold decryption key
  // and nodes must participate in a threshold decryption OCR round to decrypt secrets
  // @return thresholdPublicKey the DON's threshold encryption public key
  function getThresholdPublicKey() external view returns (bytes memory);

  // @notice Sets the DON's threshold encryption public key used to encrypt secrets
  // @dev Used to rotate the key
  // @param thresholdPublicKey The new public key
  function setThresholdPublicKey(bytes calldata thresholdPublicKey) external;

  // @notice Returns the DON's secp256k1 public key that is used to encrypt secrets
  // @dev All nodes on the DON have the corresponding private key
  // needed to decrypt the secrets encrypted with the public key
  // @return publicKey the DON's public key
  function getDONPublicKey() external view returns (bytes memory);

  // @notice Sets DON's secp256k1 public key used to encrypt secrets
  // @dev Used to rotate the key
  // @param donPublicKey The new public key
  function setDONPublicKey(bytes calldata donPublicKey) external;

  // @notice Sets a per-node secp256k1 public key used to encrypt secrets for that node
  // @dev Callable only by contract owner and DON members
  // @param node node's address
  // @param publicKey node's public key
  function setNodePublicKey(address node, bytes calldata publicKey) external;

  // @notice Deletes node's public key
  // @dev Callable only by contract owner or the node itself
  // @param node node's address
  function deleteNodePublicKey(address node) external;

  // @notice Return two arrays of equal size containing DON members' addresses and their corresponding
  // public keys (or empty byte arrays if per-node key is not defined)
  function getAllNodePublicKeys() external view returns (address[] memory, bytes[] memory);

  // @notice Sends a request (encoded as data) using the provided subscriptionId
  // @dev Callable only by the Router
  // @param request The request information, @dev see the struct for field descriptions
  // @return commitment - The parameters of the request that must be held consistent at response time
  function sendRequest(Request calldata request) external returns (FunctionsResponse.Commitment memory commitment);
}
