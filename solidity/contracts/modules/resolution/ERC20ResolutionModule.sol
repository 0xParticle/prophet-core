// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// solhint-disable-next-line no-unused-import
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IERC20ResolutionModule} from '../../../interfaces/modules/resolution/IERC20ResolutionModule.sol';
import {IOracle} from '../../../interfaces/IOracle.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

// solhint-disable-next-line no-unused-import
import {Module, IModule} from '../../Module.sol';

contract ERC20ResolutionModule is Module, IERC20ResolutionModule {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @inheritdoc IERC20ResolutionModule
  mapping(bytes32 _disputeId => Escalation _escalation) public escalations;

  /// @inheritdoc IERC20ResolutionModule
  mapping(bytes32 _disputeId => mapping(address _voter => uint256 _numOfVotes)) public votes;

  mapping(bytes32 _disputeId => EnumerableSet.AddressSet _votersSet) private _voters;

  constructor(IOracle _oracle) Module(_oracle) {}

  /// @inheritdoc IModule
  function moduleName() external pure returns (string memory _moduleName) {
    return 'ERC20ResolutionModule';
  }

  /// @inheritdoc IERC20ResolutionModule
  function decodeRequestData(bytes32 _requestId) public view returns (RequestParameters memory _params) {
    _params = abi.decode(requestData[_requestId], (RequestParameters));
  }

  /// @inheritdoc IERC20ResolutionModule
  function startResolution(bytes32 _disputeId) external onlyOracle {
    escalations[_disputeId].startTime = block.timestamp;
    emit VotingPhaseStarted(block.timestamp, _disputeId);
  }

  /// @inheritdoc IERC20ResolutionModule
  function castVote(bytes32 _requestId, bytes32 _disputeId, uint256 _numberOfVotes) public {
    IOracle.Dispute memory _dispute = ORACLE.getDispute(_disputeId);
    if (_dispute.createdAt == 0) revert ERC20ResolutionModule_NonExistentDispute();
    if (_dispute.status != IOracle.DisputeStatus.None) revert ERC20ResolutionModule_AlreadyResolved();

    Escalation memory _escalation = escalations[_disputeId];
    if (_escalation.startTime == 0) revert ERC20ResolutionModule_DisputeNotEscalated();

    RequestParameters memory _params = decodeRequestData(_requestId);
    uint256 _deadline = _escalation.startTime + _params.timeUntilDeadline;
    if (block.timestamp >= _deadline) revert ERC20ResolutionModule_VotingPhaseOver();

    votes[_disputeId][msg.sender] += _numberOfVotes;

    _voters[_disputeId].add(msg.sender);
    escalations[_disputeId].totalVotes += _numberOfVotes;

    _params.votingToken.safeTransferFrom(msg.sender, address(this), _numberOfVotes);
    emit VoteCast(msg.sender, _disputeId, _numberOfVotes);
  }

  /// @inheritdoc IERC20ResolutionModule
  function resolveDispute(bytes32 _disputeId) external onlyOracle {
    // 0. Check disputeId actually exists and that it isnt resolved already
    IOracle.Dispute memory _dispute = ORACLE.getDispute(_disputeId);
    if (_dispute.createdAt == 0) revert ERC20ResolutionModule_NonExistentDispute();
    if (_dispute.status != IOracle.DisputeStatus.None) revert ERC20ResolutionModule_AlreadyResolved();

    Escalation memory _escalation = escalations[_disputeId];
    // 1. Check that the dispute is actually escalated
    if (_escalation.startTime == 0) revert ERC20ResolutionModule_DisputeNotEscalated();

    // 2. Check that voting deadline is over
    RequestParameters memory _params = decodeRequestData(_dispute.requestId);
    uint256 _deadline = _escalation.startTime + _params.timeUntilDeadline;
    if (block.timestamp < _deadline) revert ERC20ResolutionModule_OnGoingVotingPhase();

    uint256 _quorumReached = _escalation.totalVotes >= _params.minVotesForQuorum ? 1 : 0;

    address[] memory __voters = _voters[_disputeId].values();

    // 5. Update status
    if (_quorumReached == 1) {
      ORACLE.updateDisputeStatus(_disputeId, IOracle.DisputeStatus.Won);
      emit DisputeResolved(_dispute.requestId, _disputeId, IOracle.DisputeStatus.Won);
    } else {
      ORACLE.updateDisputeStatus(_disputeId, IOracle.DisputeStatus.Lost);
      emit DisputeResolved(_dispute.requestId, _disputeId, IOracle.DisputeStatus.Lost);
    }

    uint256 _votersLength = __voters.length;

    // 6. Return tokens
    for (uint256 _i; _i < _votersLength;) {
      address _voter = __voters[_i];
      _params.votingToken.safeTransfer(_voter, votes[_disputeId][_voter]);
      unchecked {
        ++_i;
      }
    }
  }

  /// @inheritdoc IERC20ResolutionModule
  function getVoters(bytes32 _disputeId) external view returns (address[] memory __voters) {
    __voters = _voters[_disputeId].values();
  }
}
