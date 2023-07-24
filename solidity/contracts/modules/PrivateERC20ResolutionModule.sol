// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IPrivateERC20ResolutionModule} from '../../interfaces/modules/IPrivateERC20ResolutionModule.sol';
import {IOracle} from '../../interfaces/IOracle.sol';
import {IAccountingExtension} from '../../interfaces/extensions/IAccountingExtension.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {Module} from '../Module.sol';

contract PrivateERC20ResolutionModule is Module, IPrivateERC20ResolutionModule {
  using SafeERC20 for IERC20;

  uint256 public constant BASE = 100;

  mapping(bytes32 _disputeId => EscalationData _escalationData) public escalationData;
  mapping(bytes32 _disputeId => VoterData[]) public votes;
  mapping(bytes32 _disputeId => uint256 _numOfVotes) public totalNumberOfVotes;
  mapping(bytes32 _disputeId => mapping(address _voter => bytes32 _commitment)) public commitments;

  constructor(IOracle _oracle) Module(_oracle) {}

  function moduleName() external pure returns (string memory _moduleName) {
    return 'PrivateERC20ResolutionModule';
  }

  function decodeRequestData(bytes32 _requestId)
    public
    view
    returns (
      IAccountingExtension _accountingExtension,
      IERC20 _token,
      uint256 _minVotesForQuorum,
      uint256 _commitingTimeWindow,
      uint256 _revealingTimeWindow
    )
  {
    (_accountingExtension, _token, _minVotesForQuorum, _commitingTimeWindow, _revealingTimeWindow) =
      abi.decode(requestData[_requestId], (IAccountingExtension, IERC20, uint256, uint256, uint256));
  }

  function startResolution(bytes32 _disputeId) external onlyOracle {
    escalationData[_disputeId].startTime = uint128(block.timestamp);
    emit CommitingPhaseStarted(uint128(block.timestamp), _disputeId);
  }

  // commit vote in favor of dispute
  function commitVote(bytes32 _requestId, bytes32 _disputeId, bytes32 _commitment) public {
    /*
      1. Check that the disputeId is Escalated - TODO
      2. Check that the commiting deadline is not over
      3. Check that the user did not provide an empty commitment
      4. Emit VoteCommited event

      @dev we are allowing users to commit multiple times, changing the amount of votes being commited
    */
    IOracle.Dispute memory _dispute = ORACLE.getDispute(_disputeId);
    if (_dispute.createdAt == 0) revert PrivateERC20ResolutionModule_NonExistentDispute();
    if (_dispute.status != IOracle.DisputeStatus.None) revert PrivateERC20ResolutionModule_AlreadyResolved();

    EscalationData memory _escalationData = escalationData[_disputeId];
    if (_escalationData.startTime == 0) revert PrivateERC20ResolutionModule_DisputeNotEscalated();

    (,,, uint256 _commitingTimeWindow,) = decodeRequestData(_requestId);
    uint256 _deadline = _escalationData.startTime + _commitingTimeWindow;
    if (block.timestamp >= _deadline) revert PrivateERC20ResolutionModule_CommitingPhaseOver();

    if (_commitment == bytes32('')) revert PrivateERC20ResolutionModule_EmptyCommitment();
    commitments[_disputeId][msg.sender] = _commitment;

    emit VoteCommited(msg.sender, _disputeId, _commitment);
  }

  function revealVote(bytes32 _requestId, bytes32 _disputeId, uint256 _numberOfVotes, bytes32 _salt) public {
    /*
      1. Check that the commiting deadline is not over
      2. Check that the user did not provide an empty commitment
      3. Emit VoteCommited event

      @dev we are allowing users to commit multiple times, changing the amount of votes being commited
    */
    EscalationData memory _escalationData = escalationData[_disputeId];
    if (_escalationData.startTime == 0) revert PrivateERC20ResolutionModule_DisputeNotEscalated();

    (, IERC20 _token,, uint256 _commitingTimeWindow, uint256 _revealingTimeWindow) = decodeRequestData(_requestId);
    (uint256 _revealStartTime, uint256 _revealEndTime) = (
      _escalationData.startTime + _commitingTimeWindow,
      _escalationData.startTime + _commitingTimeWindow + _revealingTimeWindow
    );
    if (block.timestamp < _revealStartTime) revert PrivateERC20ResolutionModule_OnGoingCommitingPhase();
    if (block.timestamp >= _revealEndTime) revert PrivateERC20ResolutionModule_RevealingPhaseOver();

    if (commitments[_disputeId][msg.sender] != keccak256(abi.encode(msg.sender, _disputeId, _numberOfVotes, _salt))) {
      revert PrivateERC20ResolutionModule_WrongRevealData();
    }
    delete commitments[_disputeId][msg.sender];

    votes[_disputeId].push(VoterData({voter: msg.sender, numOfVotes: _numberOfVotes}));
    escalationData[_disputeId].totalVotes += _numberOfVotes;

    _token.safeTransferFrom(msg.sender, address(this), _numberOfVotes);

    emit VoteRevealed(msg.sender, _disputeId, _numberOfVotes);
  }

  function resolveDispute(bytes32 _disputeId) external onlyOracle {
    // 0. Check that the disputeId actually exists
    IOracle.Dispute memory _dispute = ORACLE.getDispute(_disputeId);
    if (_dispute.createdAt == 0) revert PrivateERC20ResolutionModule_NonExistentDispute();
    if (_dispute.status != IOracle.DisputeStatus.None) revert PrivateERC20ResolutionModule_AlreadyResolved();

    EscalationData memory _escalationData = escalationData[_disputeId];
    // Check that the dispute is actually escalated
    if (_escalationData.startTime == 0) revert PrivateERC20ResolutionModule_DisputeNotEscalated();

    // 2. Check that voting deadline is over
    (, IERC20 _token, uint256 _minVotesForQuorum, uint256 _commitingTimeWindow, uint256 _revealingTimeWindow) =
      decodeRequestData(_dispute.requestId);
    if (block.timestamp < _escalationData.startTime + _commitingTimeWindow) {
      revert PrivateERC20ResolutionModule_OnGoingCommitingPhase();
    }
    if (block.timestamp < _escalationData.startTime + _commitingTimeWindow + _revealingTimeWindow) {
      revert PrivateERC20ResolutionModule_OnGoingRevealingPhase();
    }

    uint256 _quorumReached = _escalationData.totalVotes >= _minVotesForQuorum ? 1 : 0;

    VoterData[] memory _voterData = votes[_disputeId];

    // 5. Update status
    if (_quorumReached == 1) {
      ORACLE.updateDisputeStatus(_disputeId, IOracle.DisputeStatus.Won);
      emit DisputeResolved(_disputeId, IOracle.DisputeStatus.Won);
    } else {
      ORACLE.updateDisputeStatus(_disputeId, IOracle.DisputeStatus.Lost);
      emit DisputeResolved(_disputeId, IOracle.DisputeStatus.Lost);
    }

    // 6. Return tokens
    for (uint256 _i; _i < _voterData.length;) {
      _token.safeTransfer(_voterData[_i].voter, _voterData[_i].numOfVotes);
      unchecked {
        ++_i;
      }
    }
  }

  function computeCommitment(
    bytes32 _disputeId,
    uint256 _numberOfVotes,
    bytes32 _salt
  ) external view returns (bytes32 _commitment) {
    _commitment = keccak256(abi.encode(msg.sender, _disputeId, _numberOfVotes, _salt));
  }
}
