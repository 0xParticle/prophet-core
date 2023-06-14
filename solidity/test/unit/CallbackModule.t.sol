// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

// solhint-disable-next-line
import 'forge-std/Test.sol';

import {
  CallbackModule, ICallback, ICallbackModule, IModule, IOracle
} from '../../contracts/modules/CallbackModule.sol';

/**
 * @dev Harness to set an entry in the requestData mapping, without triggering setup request hooks
 */
contract ForTest_CallbackModule is CallbackModule {
  constructor(IOracle _oracle) CallbackModule(_oracle) {}

  function forTest_setRequestData(bytes32 _requestId, bytes memory _data) public {
    requestData[_requestId] = _data;
  }
}

/**
 * @title Callback Module Unit tests
 */
contract CallbackModule_UnitTest is Test {
  event Callback(address indexed _target, bytes32 indexed _request, bytes _data);

  // The target contract
  ForTest_CallbackModule public callbackModule;

  // A mock oracle
  IOracle public oracle;

  /**
   * @notice Deploy the target and mock oracle+accounting extension
   */
  function setUp() public {
    oracle = IOracle(makeAddr('Oracle'));
    vm.etch(address(oracle), hex'069420');

    callbackModule = new ForTest_CallbackModule(oracle);
  }

  /**
   * @notice Test that the decodeRequestData function returns the correct values
   */
  function test_decodeRequestData(bytes32 _requestId, address _target, bytes calldata _data) public {
    // Create and set some mock request data
    bytes memory _requestData = abi.encode(_target, _data);
    callbackModule.forTest_setRequestData(_requestId, _requestData);

    // Decode the given request data
    (address _decodedTarget, bytes memory _decodedData) = callbackModule.decodeRequestData(_requestId);

    // Check: decoded values match original values?
    assertEq(_decodedTarget, _target);
    assertEq(_decodedData, _data);
  }

  /**
   * @notice Test that finalizeRequest calls the _target.callback with the correct data
   */
  function test_finalizeRequestTriggersCallback(bytes32 _requestId, address _target, bytes calldata _data) public {
    assumeNoPrecompiles(_target);

    // Create and set some mock request data
    bytes memory _requestData = abi.encode(_target, _data);
    callbackModule.forTest_setRequestData(_requestId, _requestData);

    vm.mockCall(_target, abi.encodeCall(ICallback.callback, (_requestId, _data)), abi.encode());
    vm.expectCall(_target, abi.encodeCall(ICallback.callback, (_requestId, _data)));

    // Check: correct event emitted?
    vm.expectEmit(true, true, true, true, address(callbackModule));
    emit Callback(_target, _requestId, _data);

    vm.prank(address(oracle));
    callbackModule.finalizeRequest(_requestId);
  }

  /**
   * @notice Test that the finalizeRequest reverts if caller is not the oracle
   */
  function test_finalizeOnlyCalledByOracle(bytes32 _requestId, address _caller) public {
    vm.assume(_caller != address(oracle));

    vm.expectRevert(abi.encodeWithSelector(IModule.Module_OnlyOracle.selector));
    callbackModule.finalizeRequest(_requestId);
  }

  /**
   * @notice Test that the moduleName function returns the correct name
   */
  function test_moduleNameReturnsName() public {
    assertEq(callbackModule.moduleName(), 'CallbackModule');
  }
}
