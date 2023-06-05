// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC165Checker} from '@openzeppelin/contracts/utils/introspection/ERC165Checker.sol';

import {IArbitratorModule} from '../../interfaces/modules/IArbitratorModule.sol';
import {IOracle} from '../../interfaces/IOracle.sol';
import {IArbitrator} from '../../interfaces/IArbitrator.sol';
import {IAccountingExtension} from '../../interfaces/extensions/IAccountingExtension.sol';

import {Module} from '../Module.sol';

// TODO: add a way to preserve requestData length > 32 bytes (now overwritten by abi.encodePacked)

contract ArbitratorModule is Module, IArbitratorModule {
  // Module mapping 1word now used as:
  // bit 0-160 arbitrator address
  // bit 161 and 162 dispute status (0, 1, 2, 3)
  // bit 163 arbitration result (0/1)
  // bit 164 use arbitrator on each call (ie is the result in bit163 or locally in the arbitrator)

  constructor(IOracle _oracle) Module(_oracle) {}

  function moduleName() external pure returns (string memory _moduleName) {
    return 'ArbitratorModule';
  }

  function decodeRequestData(bytes32 _requestId) external view returns (address _arbitrator) {
    _arbitrator = _decodeRequestData(requestData[_requestId]);
  }

  function _decodeRequestData(bytes memory _data) internal pure returns (address _arbitrator) {
    _arbitrator = abi.decode(_data, (address));
  }

  // takes a request ID and return a bool indicating if the arbitrator has validated the observation or not.
  // always return false for pending/unknown disputes
  function isValid(bytes32 _dispute) external view returns (bool _isValid) {
    uint256 _requestData = abi.decode(requestData[_dispute], (uint256));

    // Use the arbitrator on each call?
    if ((_requestData >> 164) & 1 == 1) return IArbitrator(address(uint160(_requestData))).isValid(_dispute);

    // Is the dispute resolved ? If so, return the _valid flag
    if ((_requestData >> 162) & 1 == 1) return (_requestData >> 163) & 1 == 1;

    // else false (dispute isn't resolved)
  }

  // Return the status (unknown/not existing, active, resolved) of a dispute
  function getStatus(bytes32 _dispute) external view returns (IArbitrator.DisputeStatus _disputeStatus) {
    uint256 _requestData = abi.decode(requestData[_dispute], (uint256));

    // Use the arbitrator as a contract?
    if ((_requestData >> 164) & 1 == 1) return IArbitrator(address(uint160(_requestData))).getStatus(_dispute);

    // enum are uint -> cast and return the status
    _disputeStatus = IArbitrator.DisputeStatus((_requestData >> 161) & 3);
  }

  // call the arbitrator with the dispute to arbitrate (it might or might not answer atomically -> eg queue a snapshot
  // vote vs a chainlink call)
  // _useArbitrator if the arbitrator is expected to store the resolution in this contract's state or to be called each time
  //
  // arbitrator can either be an EOA (or contract) which sends dispute resolution to this contract (ie offchain vote later sent)
  // or a contract which implements IArbitrator which can store resolution there and expect to be queried (ie onchain voting)
  // or a contract which resolve as soon as being called (ie chainlink wrapper)
  function resolveDispute(bytes32 _disputeId) external {
    IOracle.Dispute memory _dispute = ORACLE.getDispute(_disputeId);

    if (_dispute.status != IOracle.DisputeStatus.Active) revert ArbitratorModule_InvalidDisputeId();

    bytes32 _requestId = _dispute.requestId;
    uint256 _requestData = abi.decode(requestData[_requestId], (uint256));

    address _arbitrator = address(uint160(_requestData));

    // Avoid ghost calls
    // TODO: If it's possible for the Arbitrator.resolve to exist but not have the answer, this could end in a wrong update of the dispute status
    // TODO: assuming the arbitrator returns _won as 0 in case there's no response or something, then a possible abuse would be:
    // TODO: proposer answers wrong, disputer disputes it, proposer calls this function, because there's no answer the arbitrator defaults to _won == 0
    // TODO: and the status of the request is changed to Lost.
    if (_arbitrator != address(0) && ERC165Checker.supportsInterface(_arbitrator, type(IArbitrator).interfaceId)) {
      // Try to atomically resolve
      try IArbitrator(_arbitrator).resolve(_disputeId) returns (bool _won, bool _useArbitrator) {
        // Store the returned bool + the status as resolved + if the arbitrator should be called on each resolution

        // This should be upgraded to preserve arbitrary length bytes (ie append a slice (or equivalent) starting at bytes 33)
        // pack: address (160) | dispute status (161-162) | arbitration status to true (163) | use arbitrator (164)
        bytes memory _requestDataUpdated =
          abi.encodePacked(_requestData | (_won ? 1 : 0) << 161 | 1 << 163 | (_useArbitrator ? 1 : 0) << 164);

        requestData[_disputeId] = _requestDataUpdated;
        IOracle.DisputeStatus _status = _won ? IOracle.DisputeStatus.Won : IOracle.DisputeStatus.Lost;

        ORACLE.updateDisputeStatus(_disputeId, _status);
      } catch {}
    }

    // else consider it as an unresolved dispute,
  }

  // locally store the result of a dispute → only if not answered atomically (in resolveDispute)
  // or if not stored in an arbitrator contract (called in getStatus and isValid): for instance a snapshot vote result
  function storeAnswer(bytes32 _dispute, bool _valid) external {
    uint256 _requestData = abi.decode(requestData[_dispute], (uint256));
    address _arbitrator = address(uint160(_requestData));

    if (msg.sender != _arbitrator) revert ArbitratorModule_OnlyArbitrator();

    // This should be upgraded to preserve arbitrary length bytes (ie append a slice (or equivalent) starting at bytes 33)
    // Store the answer and the status + reset the "use allocator" (as the answer is now here)
    bytes memory _requestDataUpdated = abi.encodePacked(_requestData | 2 << 162 | (_valid ? 1 : 0) << 163);

    requestData[_dispute] = _requestDataUpdated;
  }
}
