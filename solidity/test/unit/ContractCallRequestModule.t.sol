// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

// solhint-disable-next-line
import 'forge-std/Test.sol';

import {
  ContractCallRequestModule,
  IOracle,
  IAccountingExtension,
  IERC20
} from '../../contracts/modules/ContractCallRequestModule.sol';

import {IModule} from '../../interfaces/IModule.sol';
/**
 * @dev Harness to set an entry in the requestData mapping, without triggering setup request hooks
 */

contract ForTest_ContractCallRequestModule is ContractCallRequestModule {
  constructor(IOracle _oracle) ContractCallRequestModule(_oracle) {}

  function forTest_setRequestData(bytes32 _requestId, bytes memory _data) public {
    requestData[_requestId] = _data;
  }
}

/**
 * @title HTTP Request Module Unit tests
 */
contract ContractCallRequestModule_UnitTest is Test {
  // The target contract
  ForTest_ContractCallRequestModule public contractCallRequestModule;

  // A mock oracle
  IOracle public oracle;

  // A mock accounting extension
  IAccountingExtension public accounting;

  // A mock user for testing
  address _user = makeAddr('user');

  // A second mock user for testing
  address _user2 = makeAddr('user2');

  // A mock ERC20 token
  IERC20 _token = IERC20(makeAddr('ERC20'));

  // Mock data
  address _targetContract = address(_token);
  bytes4 _functionSelector = bytes4(abi.encodeWithSignature('allowance(address,address)'));
  bytes _dataParams = abi.encode(_user, _user2);

  /**
   * @notice Deploy the target and mock oracle+accounting extension
   */
  function setUp() public {
    oracle = IOracle(makeAddr('Oracle'));
    vm.etch(address(oracle), hex'069420');

    accounting = IAccountingExtension(makeAddr('AccountingExtension'));
    vm.etch(address(accounting), hex'069420');

    contractCallRequestModule = new ForTest_ContractCallRequestModule(oracle);
  }

  /**
   * @notice Test that the decodeRequestData function returns the correct values
   */
  function test_decodeRequestData(bytes32 _requestId, IERC20 _paymentToken, uint256 _paymentAmount) public {
    vm.assume(_requestId != bytes32(0));
    vm.assume(address(_paymentToken) != address(0));
    vm.assume(_paymentAmount > 0);

    bytes memory _requestData =
      abi.encode(_targetContract, _functionSelector, _dataParams, accounting, _paymentToken, _paymentAmount);

    // Set the request data
    contractCallRequestModule.forTest_setRequestData(_requestId, _requestData);

    // Decode the given request data
    (
      address _decodedTarget,
      bytes4 _decodedFunctionSelector,
      bytes memory _decodedData,
      IAccountingExtension _decodedAccountingExtension,
      IERC20 _decodedPaymentToken,
      uint256 _decodedPaymentAmount
    ) = contractCallRequestModule.decodeRequestData(_requestId);

    // Check: decoded values match original values?
    assertEq(_decodedTarget, _targetContract, 'Mismatch: decoded target');
    assertEq(_decodedFunctionSelector, _functionSelector, 'Mismatch: decoded function selector');
    assertEq(_decodedData, _dataParams, 'Mismatch: decoded data');
    assertEq(address(_decodedAccountingExtension), address(accounting), 'Mismatch: decoded accounting extension');
    assertEq(address(_decodedPaymentToken), address(_paymentToken), 'Mismatch: decoded payment token');
    assertEq(_decodedPaymentAmount, _paymentAmount, 'Mismatch: decoded payment amount');
  }

  /**
   * @notice Test that the afterSetupRequest hook:
   *          - decodes the request data
   *          - gets the request from the oracle
   *          - calls the bond function on the accounting extension
   */
  function test_afterSetupRequestTriggered(
    bytes32 _requestId,
    address _requester,
    IERC20 _paymentToken,
    uint256 _paymentAmount
  ) public {
    vm.assume(_requestId != bytes32(0));
    vm.assume(_requester != address(0));
    vm.assume(address(_paymentToken) != address(0));
    vm.assume(_paymentAmount > 0);

    bytes memory _requestData =
      abi.encode(_targetContract, _functionSelector, _dataParams, accounting, _paymentToken, _paymentAmount);

    IOracle.Request memory _fullRequest;
    _fullRequest.requester = _requester;

    // Mock and assert ext calls
    vm.mockCall(address(oracle), abi.encodeCall(IOracle.getRequest, (_requestId)), abi.encode(_fullRequest));
    vm.expectCall(address(oracle), abi.encodeCall(IOracle.getRequest, (_requestId)));

    vm.mockCall(
      address(accounting),
      abi.encodeCall(IAccountingExtension.bond, (_requester, _requestId, _paymentToken, _paymentAmount)),
      abi.encode(true)
    );
    vm.expectCall(
      address(accounting),
      abi.encodeCall(IAccountingExtension.bond, (_requester, _requestId, _paymentToken, _paymentAmount))
    );

    vm.prank(address(oracle));
    contractCallRequestModule.setupRequest(_requestId, _requestData);

    // Check: request data was set?
    assertEq(contractCallRequestModule.requestData(_requestId), _requestData, 'Mismatch: Request data');
  }

  /**
   * @notice Test that the moduleName function returns the correct name
   */
  function test_moduleNameReturnsName() public {
    assertEq(contractCallRequestModule.moduleName(), 'ContractCallRequestModule', 'Wrong module name');
  }

  /**
   * @notice Test that finalizeRequest calls:
   *          - oracle get request
   *          - oracle get response
   *          - accounting extension pay
   *          - accounting extension release
   */
  function test_finalizeRequestMakesCalls(
    bytes32 _requestId,
    address _requester,
    address _proposer,
    IERC20 _paymentToken,
    uint256 _paymentAmount
  ) public {
    vm.assume(_requestId != bytes32(0));
    vm.assume(_requester != address(0));
    vm.assume(_proposer != address(0));
    vm.assume(address(_paymentToken) != address(0));
    vm.assume(_paymentAmount > 0);

    // Use the correct accounting parameters
    bytes memory _requestData =
      abi.encode(_targetContract, _functionSelector, _dataParams, accounting, _paymentToken, _paymentAmount);

    IOracle.Request memory _fullRequest;
    _fullRequest.requester = _requester;

    IOracle.Response memory _fullResponse;
    _fullResponse.proposer = _proposer;
    _fullResponse.createdAt = block.timestamp;

    // Set the request data
    contractCallRequestModule.forTest_setRequestData(_requestId, _requestData);

    // Mock and assert the calls
    vm.mockCall(address(oracle), abi.encodeCall(IOracle.getRequest, (_requestId)), abi.encode(_fullRequest));
    vm.expectCall(address(oracle), abi.encodeCall(IOracle.getRequest, (_requestId)));

    vm.mockCall(address(oracle), abi.encodeCall(IOracle.getFinalizedResponse, (_requestId)), abi.encode(_fullResponse));
    vm.expectCall(address(oracle), abi.encodeCall(IOracle.getFinalizedResponse, (_requestId)));

    vm.mockCall(
      address(accounting),
      abi.encodeCall(IAccountingExtension.pay, (_requestId, _requester, _proposer, _paymentToken, _paymentAmount)),
      abi.encode()
    );
    vm.expectCall(
      address(accounting),
      abi.encodeCall(IAccountingExtension.pay, (_requestId, _requester, _proposer, _paymentToken, _paymentAmount))
    );

    vm.startPrank(address(oracle));
    contractCallRequestModule.finalizeRequest(_requestId, address(oracle));

    // Test the release flow
    _fullResponse.createdAt = 0;

    // Update mock call to return the response with createdAt = 0
    vm.mockCall(address(oracle), abi.encodeCall(IOracle.getFinalizedResponse, (_requestId)), abi.encode(_fullResponse));
    vm.expectCall(address(oracle), abi.encodeCall(IOracle.getFinalizedResponse, (_requestId)));

    vm.mockCall(
      address(accounting),
      abi.encodeCall(IAccountingExtension.release, (_requester, _requestId, _paymentToken, _paymentAmount)),
      abi.encode(true)
    );

    vm.expectCall(
      address(accounting),
      abi.encodeCall(IAccountingExtension.release, (_requester, _requestId, _paymentToken, _paymentAmount))
    );

    contractCallRequestModule.finalizeRequest(_requestId, address(this));
  }

  /**
   * @notice Test that the finalizeRequest reverts if caller is not the oracle
   */
  function test_finalizeOnlyCalledByOracle(bytes32 _requestId, address _caller) public {
    vm.assume(_caller != address(oracle));

    vm.expectRevert(abi.encodeWithSelector(IModule.Module_OnlyOracle.selector));
    vm.prank(_caller);
    contractCallRequestModule.finalizeRequest(_requestId, address(_caller));
  }
}
