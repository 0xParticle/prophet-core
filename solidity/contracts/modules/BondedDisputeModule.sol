// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IBondedDisputeModule} from '../../interfaces/modules/IBondedDisputeModule.sol';
import {IOracle} from '../../interfaces/IOracle.sol';
import {IAccountingExtension} from '../../interfaces/extensions/IAccountingExtension.sol';

import {Module} from '../Module.sol';

contract BondedDisputeModule is Module, IBondedDisputeModule {
  constructor(IOracle _oracle) Module(_oracle) {}

  function moduleName() external pure returns (string memory _moduleName) {
    return 'BondedDisputeModule';
  }

  function decodeRequestData(bytes32 _requestId)
    public
    view
    returns (IAccountingExtension _accountingExtension, IERC20 _bondToken, uint256 _bondSize)
  {
    (_accountingExtension, _bondToken, _bondSize) =
      abi.decode(requestData[_requestId], (IAccountingExtension, IERC20, uint256));
  }

  function disputeEscalated(bytes32 _disputeId) external onlyOracle {}

  function disputeResponse(
    bytes32 _requestId,
    bytes32 _responseId,
    address _disputer,
    address _proposer
  ) external onlyOracle returns (IOracle.Dispute memory _dispute) {
    _dispute = IOracle.Dispute({
      disputer: _disputer,
      responseId: _responseId,
      proposer: _proposer,
      requestId: _requestId,
      status: IOracle.DisputeStatus.Active,
      createdAt: block.timestamp
    });

    (IAccountingExtension _accountingExtension, IERC20 _bondToken, uint256 _bondSize) = decodeRequestData(_requestId);
    _accountingExtension.bond(_disputer, _requestId, _bondToken, _bondSize);
  }

  // TODO: This doesn't handle the cases of unconclusive statuses
  function updateDisputeStatus(bytes32, /* _disputeId */ IOracle.Dispute memory _dispute) external onlyOracle {
    (IAccountingExtension _accountingExtension, IERC20 _bondToken, uint256 _bondSize) =
      decodeRequestData(_dispute.requestId);
    bool _won = _dispute.status == IOracle.DisputeStatus.Won;

    _accountingExtension.pay(
      _dispute.requestId,
      _won ? _dispute.proposer : _dispute.disputer,
      _won ? _dispute.disputer : _dispute.proposer,
      _bondToken,
      _bondSize
    );

    _accountingExtension.release(
      _won ? _dispute.disputer : _dispute.proposer, _dispute.requestId, _bondToken, _bondSize
    );
  }
}
