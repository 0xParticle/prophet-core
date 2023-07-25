// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

// solhint-disable-next-line
import 'forge-std/Test.sol';

import {
  PrivateERC20ResolutionModule,
  IPrivateERC20ResolutionModule
} from '../../contracts/modules/PrivateERC20ResolutionModule.sol';
import {IOracle} from '../../interfaces/IOracle.sol';
import {IAccountingExtension} from '../../interfaces/extensions/IAccountingExtension.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IModule} from '../../interfaces/IModule.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

contract ForTest_PrivateERC20ResolutionModule is PrivateERC20ResolutionModule {
  constructor(IOracle _oracle) PrivateERC20ResolutionModule(_oracle) {}

  function forTest_setRequestData(bytes32 _requestId, bytes memory _data) public {
    requestData[_requestId] = _data;
  }

  function forTest_setEscalationData(
    bytes32 _disputeId,
    PrivateERC20ResolutionModule.EscalationData calldata __escalationData
  ) public {
    escalationData[_disputeId] = __escalationData;
  }

  function forTest_setVoterData(
    bytes32 _disputeId,
    address _voter,
    IPrivateERC20ResolutionModule.VoterData memory _data
  ) public {
    _votersData[_disputeId][_voter] = _data;
  }

  function forTest_getVoterData(
    bytes32 _disputeId,
    address _voter
  ) public view returns (IPrivateERC20ResolutionModule.VoterData memory _data) {
    _data = _votersData[_disputeId][_voter];
  }
}

contract PrivateERC20ResolutionModule_UnitTest is Test {
  // The target contract
  ForTest_PrivateERC20ResolutionModule public module;

  // A mock oracle
  IOracle public oracle;

  // A mock accounting extension
  IAccountingExtension public accounting;

  // A mock token
  IERC20 public token;

  // Mock EOA proposer
  address public proposer;

  // Mock EOA disputer
  address public disputer;

  event CommitingPhaseStarted(uint256 _startTime, bytes32 _disputeId);
  event VoteCommited(address _voter, bytes32 _disputeId, bytes32 _commitment);
  event VoteRevealed(address _voter, bytes32 _disputeId, uint256 _numberOfVotes);
  event DisputeResolved(bytes32 _disputeId, IOracle.DisputeStatus _status);

  /**
   * @notice Deploy the target and mock oracle+accounting extension
   */
  function setUp() public {
    oracle = IOracle(makeAddr('Oracle'));
    vm.etch(address(oracle), hex'069420');

    accounting = IAccountingExtension(makeAddr('AccountingExtension'));
    vm.etch(address(accounting), hex'069420');

    token = IERC20(makeAddr('ERC20'));
    vm.etch(address(token), hex'069420');

    proposer = makeAddr('proposer');
    disputer = makeAddr('disputer');

    // Avoid starting at 0 for time sensitive tests
    vm.warp(123_456);

    module = new ForTest_PrivateERC20ResolutionModule(oracle);
  }

  /**
   * @notice Test that the moduleName function returns the correct name
   */
  function test_moduleName() public {
    assertEq(module.moduleName(), 'PrivateERC20ResolutionModule');
  }

  /**
   * @notice Test that the startResolution is correctly called and the commiting phase is started
   */
  function test_startResolution(bytes32 _disputeId) public {
    module.forTest_setEscalationData(
      _disputeId, IPrivateERC20ResolutionModule.EscalationData({startTime: 0, totalVotes: 0})
    );

    // Check: does revert if called by address != oracle?
    vm.expectRevert(IModule.Module_OnlyOracle.selector);
    module.startResolution(_disputeId);

    // Check: emits CommitingPhaseStarted event?
    vm.expectEmit(true, true, true, true);
    emit CommitingPhaseStarted(block.timestamp, _disputeId);

    vm.prank(address(oracle));
    module.startResolution(_disputeId);

    (uint256 _startTime,) = module.escalationData(_disputeId);

    // Check: startTime is set to block.timestamp?
    assertEq(_startTime, block.timestamp);
  }

  /**
   * @notice Test that a user can store a vote commitment for a dispute
   */
  function test_commitVote(
    bytes32 _requestId,
    bytes32 _disputeId,
    uint256 _amountOfVotes,
    bytes32 _salt,
    address _voter
  ) public {
    // Mock the dispute
    IOracle.Dispute memory _mockDispute = _getMockDispute(_requestId);

    // Store mock escalation data with startTime 100_000
    module.forTest_setEscalationData(
      _disputeId,
      IPrivateERC20ResolutionModule.EscalationData({
        startTime: 100_000,
        totalVotes: 0 // Initial amount of votes
      })
    );

    // Store mock request data with 40_000 commiting time window
    module.forTest_setRequestData(
      _requestId, abi.encode(address(accounting), token, uint256(1), uint256(40_000), uint256(40_000))
    );

    // Mock the oracle response for looking up a dispute
    vm.mockCall(address(oracle), abi.encodeCall(IOracle.getDispute, (_disputeId)), abi.encode(_mockDispute));
    vm.expectCall(address(oracle), abi.encodeCall(IOracle.getDispute, (_disputeId)));

    // Set timestamp for valid commitingTimeWindow
    vm.warp(123_456);

    // Compute commitment
    vm.startPrank(_voter);
    bytes32 _commitment = module.computeCommitment(_disputeId, _amountOfVotes, _salt);

    // Check: is event emitted?
    vm.expectEmit(true, true, true, true);
    emit VoteCommited(_voter, _disputeId, _commitment);

    // Revert if no commitment is given
    vm.expectRevert(IPrivateERC20ResolutionModule.PrivateERC20ResolutionModule_EmptyCommitment.selector);
    module.commitVote(_requestId, _disputeId, bytes32(''));

    // Compute and store commitment
    module.commitVote(_requestId, _disputeId, _commitment);

    // Check: commitment is stored?
    IPrivateERC20ResolutionModule.VoterData memory _voterData = module.forTest_getVoterData(_disputeId, _voter);
    assertEq(_voterData.commitment, _commitment);

    bytes32 _newComitment = module.computeCommitment(_disputeId, uint256(_salt), bytes32(_amountOfVotes));
    module.commitVote(_requestId, _disputeId, _newComitment);
    vm.stopPrank();
  }

  function test_revealVote(
    bytes32 _requestId,
    bytes32 _disputeId,
    uint256 _amountOfVotes,
    bytes32 _salt,
    address _voter
  ) public {
    // Store mock escalation data with startTime 100_000
    module.forTest_setEscalationData(
      _disputeId,
      IPrivateERC20ResolutionModule.EscalationData({
        startTime: 100_000,
        totalVotes: 0 // Initial amount of votes
      })
    );

    // Store mock request data with 40_000 commiting time window
    module.forTest_setRequestData(
      _requestId, abi.encode(address(accounting), token, uint256(1), uint256(40_000), uint256(40_000))
    );

    // Store commitment
    vm.prank(_voter);
    bytes32 _commitment = module.computeCommitment(_disputeId, _amountOfVotes, _salt);
    module.forTest_setVoterData(
      _disputeId, _voter, IPrivateERC20ResolutionModule.VoterData({numOfVotes: 0, commitment: _commitment})
    );

    // Mock token transfer (user must have approved token spending)
    vm.mockCall(
      address(token), abi.encodeCall(IERC20.transferFrom, (_voter, address(module), _amountOfVotes)), abi.encode()
    );
    vm.expectCall(address(token), abi.encodeCall(IERC20.transferFrom, (_voter, address(module), _amountOfVotes)));

    // Warp to revealing phase
    vm.warp(150_000);

    // Check: is event emmited?
    vm.expectEmit(true, true, true, true);
    emit VoteRevealed(_voter, _disputeId, _amountOfVotes);

    vm.prank(_voter);
    module.revealVote(_requestId, _disputeId, _amountOfVotes, _salt);

    (, uint256 _totalVotes) = module.escalationData(_disputeId);
    // Check: totalVotes is updated?
    assertEq(_totalVotes, _amountOfVotes);

    // Check: voter data is updated?
    IPrivateERC20ResolutionModule.VoterData memory _voterData = module.forTest_getVoterData(_disputeId, _voter);
    assertEq(_voterData.numOfVotes, _amountOfVotes);
  }

  /**
   * @notice Test that a dispute is resolved and the tokens are transferred back
   */
  function test_resolveDispute(bytes32 _requestId, bytes32 _disputeId, uint16 _minVotesForQuorum) public {
    // Store mock dispute and mock calls
    IOracle.Dispute memory _mockDispute = _getMockDispute(_requestId);

    vm.mockCall(address(oracle), abi.encodeCall(IOracle.getDispute, (_disputeId)), abi.encode(_mockDispute));
    vm.expectCall(address(oracle), abi.encodeCall(IOracle.getDispute, (_disputeId)));

    // Store request data
    module.forTest_setRequestData(
      _requestId, abi.encode(address(accounting), token, _minVotesForQuorum, uint256(40_000), uint256(40_000))
    );

    // Store escalation data with starttime 100_000 and votes 0
    module.forTest_setEscalationData(
      _disputeId, IPrivateERC20ResolutionModule.EscalationData({startTime: 100_000, totalVotes: 0})
    );

    // Make 100 addresses cast 20 votes each
    uint256 _totalVotesCast = _populateVoters(_requestId, _disputeId, 20, 100);

    // Warp to resolving phase
    vm.warp(190_000);

    // Mock and expect token transfers (should happen always)
    for (uint256 i = 1; i < 20;) {
      vm.mockCall(address(token), abi.encodeCall(IERC20.transfer, (vm.addr(i), 100)), abi.encode());
      vm.expectCall(address(token), abi.encodeCall(IERC20.transfer, (vm.addr(i), 100)));
      unchecked {
        ++i;
      }
    }

    // If quorum reached, check for dispute status update and event emission
    if (_totalVotesCast >= _minVotesForQuorum) {
      vm.mockCall(
        address(oracle),
        abi.encodeCall(IOracle.updateDisputeStatus, (_disputeId, IOracle.DisputeStatus.Won)),
        abi.encode()
      );
      vm.expectCall(
        address(oracle), abi.encodeCall(IOracle.updateDisputeStatus, (_disputeId, IOracle.DisputeStatus.Won))
      );
      vm.expectEmit(true, true, true, true);
      emit DisputeResolved(_disputeId, IOracle.DisputeStatus.Won);
    } else {
      vm.mockCall(
        address(oracle),
        abi.encodeCall(IOracle.updateDisputeStatus, (_disputeId, IOracle.DisputeStatus.Lost)),
        abi.encode()
      );
      vm.expectCall(
        address(oracle), abi.encodeCall(IOracle.updateDisputeStatus, (_disputeId, IOracle.DisputeStatus.Lost))
      );
      vm.expectEmit(true, true, true, true);
      emit DisputeResolved(_disputeId, IOracle.DisputeStatus.Lost);
    }

    // Check: does revert if called by address != oracle?
    vm.expectRevert(IModule.Module_OnlyOracle.selector);
    module.resolveDispute(_disputeId);

    vm.prank(address(oracle));
    module.resolveDispute(_disputeId);
  }

  function _populateVoters(
    bytes32 _requestId,
    bytes32 _disputeId,
    uint8 _size,
    uint8 _votes
  ) internal returns (uint256 _totalVotesCast) {
    for (uint256 i = 1; i < _size;) {
      vm.warp(120_000);
      vm.startPrank(vm.addr(i));
      bytes32 _commitment = module.computeCommitment(_disputeId, _votes, bytes32(i)); // index as salt
      module.commitVote(_requestId, _disputeId, _commitment);
      vm.warp(140_000);
      vm.mockCall(
        address(token), abi.encodeCall(IERC20.transferFrom, (vm.addr(i), address(module), _votes)), abi.encode()
      );
      module.revealVote(_requestId, _disputeId, _votes, bytes32(i));
      vm.stopPrank();
      _totalVotesCast += _votes;
      unchecked {
        ++i;
      }
    }
  }

  function _getMockDispute(bytes32 _requestId) internal view returns (IOracle.Dispute memory _dispute) {
    _dispute = IOracle.Dispute({
      disputer: disputer,
      responseId: bytes32('response'),
      proposer: proposer,
      requestId: _requestId,
      status: IOracle.DisputeStatus.None,
      createdAt: block.timestamp
    });
  }
}
