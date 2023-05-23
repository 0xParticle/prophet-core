// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IResponseModule} from './IResponseModule.sol';
import {IAccountingExtension} from '../extensions/IAccountingExtension.sol';

interface IBondedResponseModule is IResponseModule {
  error BondedResponseModule_TooEarlyToFinalize();

  function decodeRequestData(bytes32 _requestId)
    external
    view
    returns (IAccountingExtension _accounting, IERC20 _bondToken, uint256 _bondSize, uint256 _deadline);
}
