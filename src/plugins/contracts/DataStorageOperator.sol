// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import '@cryptoalgebra/core/contracts/base/common/Timestamp.sol';

import './libraries/DataStorage.sol';
import './libraries/AdaptiveFee.sol';

import '@cryptoalgebra/core/contracts/interfaces/IAlgebraFactory.sol';
import '@cryptoalgebra/core/contracts/interfaces/IAlgebraPlugin.sol';
import '@cryptoalgebra/core/contracts/interfaces/pool/IAlgebraPoolState.sol';
import '@cryptoalgebra/core/contracts/interfaces/IAlgebraPool.sol';

import './interfaces/IDataStorageOperator.sol';
import './interfaces/IDataStorageFactory.sol';
import './interfaces/IAlgebraVirtualPool.sol';

/// @title Algebra default plugin
/// @notice This contract stores timepoints and calculates adaptive fee and statistical averages
contract DataStorageOperator is IDataStorageOperator, Timestamp, IAlgebraPlugin {
  uint256 internal constant UINT16_MODULO = 65536;

  using DataStorage for DataStorage.Timepoint[UINT16_MODULO];

  DataStorage.Timepoint[UINT16_MODULO] public override timepoints;
  // TODO
  uint16 public override timepointIndex;
  uint32 public lastTimepointTimestamp;

  AlgebraFeeConfiguration public feeConfig;

  /// @dev The role can be granted in AlgebraFactory
  bytes32 public constant FEE_CONFIG_MANAGER = keccak256('FEE_CONFIG_MANAGER');

  address private immutable pool;
  address private immutable factory;
  address private immutable pluginFactory;

  address public override incentive;

  uint8 public constant override defaultPluginConfig =
    uint8(Constants.AFTER_INIT_HOOK_FLAG | Constants.BEFORE_SWAP_HOOK_FLAG | Constants.AFTER_POSITION_MODIFY_HOOK_FLAG);

  modifier onlyPool() {
    require(msg.sender == pool, 'only pool can call this');
    _;
  }

  constructor(address _pool, address _factory, address _pluginFactory) {
    (factory, pool, pluginFactory) = (_factory, _pool, _pluginFactory);
  }

  function _getPoolState() internal view returns (int24 tick, uint16 fee, uint8 pluginConfig) {
    (, tick, , fee, pluginConfig, , ) = IAlgebraPoolState(pool).globalState();
  }

  // ###### Volatility and TWAP oracle ######

  /// @inheritdoc IVolatilityOracle
  function initialize(uint32 time, int24 tick) external override onlyPool {
    lastTimepointTimestamp = time;
    return timepoints.initialize(time, tick); // TODO "late" init?
  }

  /// @inheritdoc IVolatilityOracle
  function getSingleTimepoint(uint32 secondsAgo) external view override returns (int56 tickCumulative, uint112 volatilityCumulative) {
    (int24 tick, , ) = _getPoolState();
    uint16 lastTimepointIndex = timepointIndex;
    uint16 oldestIndex = timepoints.getOldestIndex(lastTimepointIndex);
    DataStorage.Timepoint memory result = timepoints.getSingleTimepoint(_blockTimestamp(), secondsAgo, tick, lastTimepointIndex, oldestIndex);
    (tickCumulative, volatilityCumulative) = (result.tickCumulative, result.volatilityCumulative);
  }

  /// @inheritdoc IVolatilityOracle
  function getTimepoints(
    uint32[] memory secondsAgos
  ) external view override returns (int56[] memory tickCumulatives, uint112[] memory volatilityCumulatives) {
    (int24 tick, , ) = _getPoolState();
    return timepoints.getTimepoints(_blockTimestamp(), secondsAgos, tick, timepointIndex);
  }

  /// @inheritdoc IVolatilityOracle
  function prepayTimepointsStorageSlots(uint16 startIndex, uint16 amount) external {
    require(!timepoints[startIndex].initialized); // if not initialized, then all subsequent ones too
    require(amount > 0 && type(uint16).max - startIndex >= amount);

    unchecked {
      for (uint256 i = startIndex; i < startIndex + amount; ++i) {
        timepoints[i].blockTimestamp = 1; // will be overwritten
      }
    }
  }

  function _writeTimepoint(
    uint32 blockTimestamp,
    int24 tick,
    uint16 lastIndex
  ) internal returns (bool updated, uint16 newLastIndex, uint16 oldestIndex) {
    (newLastIndex, oldestIndex) = timepoints.write(lastIndex, blockTimestamp, tick);

    if (lastIndex != newLastIndex) {
      timepointIndex = newLastIndex;
      lastTimepointTimestamp = blockTimestamp;
      updated = true;
    }
  }

  // ###### Fee manager ######

  /// @inheritdoc IDynamicFeeManager
  function changeFeeConfiguration(AlgebraFeeConfiguration calldata _config) external override {
    require(msg.sender == pluginFactory || IAlgebraFactory(factory).hasRoleOrOwner(FEE_CONFIG_MANAGER, msg.sender));
    AdaptiveFee.validateFeeConfiguration(_config);

    feeConfig = _config;
    emit FeeConfiguration(_config);
  }

  /// @inheritdoc IDynamicFeeManager
  function getCurrentFee() external view override returns (uint16 fee) {
    AlgebraFeeConfiguration memory _feeConfig = feeConfig;
    if (_feeConfig.alpha1 | _feeConfig.alpha2 == 0) {
      return _feeConfig.baseFee;
    } else {
      uint16 lastIndex = timepointIndex;
      uint16 oldestIndex = timepoints.getOldestIndex(lastIndex);
      (int24 tick, , ) = _getPoolState();

      uint88 lastVolatilityCumulative = timepoints._getVolatilityCumulativeAt(_blockTimestamp(), 0, tick, lastIndex, oldestIndex);
      uint88 volatilityAverage = timepoints.getAverageVolatility(_blockTimestamp(), tick, lastIndex, oldestIndex, lastVolatilityCumulative);

      return AdaptiveFee.getFee(volatilityAverage, feeConfig);
    }
  }

  function _getFeeAtLastTimepoint(uint16 lastTimepointIndex) internal view returns (uint16 fee) {
    AlgebraFeeConfiguration memory _feeConfig = feeConfig;
    if (_feeConfig.alpha1 | _feeConfig.alpha2 == 0) {
      return _feeConfig.baseFee;
    } else {
      uint88 volatilityAverage = timepoints.getAverageVolatilityAtTimepoint(lastTimepointIndex);
      return AdaptiveFee.getFee(volatilityAverage, _feeConfig);
    }
  }

  // ###### Farming plugin ######

  /// @inheritdoc IFarmingPlugin
  function setIncentive(address newIncentive) external override {
    require(msg.sender == IDataStorageFactory(pluginFactory).farmingAddress());

    bool turnOn = newIncentive != address(0);
    address currentIncentive = incentive;

    require(currentIncentive != newIncentive, 'already active');
    if (currentIncentive != address(0)) require(!turnOn, 'has active incentive');

    incentive = newIncentive;
    emit Incentive(newIncentive);

    (, , uint8 pluginConfig) = _getPoolState();
    bool isHookActive = pluginConfig & uint8(Constants.AFTER_SWAP_HOOK_FLAG) != 0;
    if (turnOn != isHookActive) {
      pluginConfig = pluginConfig ^ uint8(Constants.AFTER_SWAP_HOOK_FLAG);
      IAlgebraPool(pool).setPluginConfig(pluginConfig);
    }
  }

  /// @inheritdoc IFarmingPlugin
  function isIncentiveActive(address targetIncentive) external view returns (bool) {
    if (incentive != targetIncentive) return false;
    if (IAlgebraPool(pool).plugin() != address(this)) return false;
    (, , uint8 pluginConfig) = _getPoolState();
    if (pluginConfig & uint8(Constants.AFTER_SWAP_HOOK_FLAG) == 0) return false;

    return true;
  }

  // ###### HOOKS ######

  function beforeInitialize(address, uint160) external override onlyPool returns (bytes4) {
    IAlgebraPool(msg.sender).setPluginConfig(defaultPluginConfig);
    return IAlgebraPlugin.beforeInitialize.selector;
  }

  function afterInitialize(address, uint160, int24 tick) external onlyPool returns (bytes4) {
    lastTimepointTimestamp = _blockTimestamp();
    timepoints.initialize(_blockTimestamp(), tick);
    return IAlgebraPlugin.afterInitialize.selector;
  }

  function beforeModifyPosition(address) external view onlyPool returns (bytes4) {
    revert('Not implemented');
  }

  function afterModifyPosition(address) external onlyPool returns (bytes4) {
    _writeTimepointAndUpdateFee();
    return IAlgebraPlugin.afterModifyPosition.selector;
  }

  function beforeSwap(address) external onlyPool returns (bytes4) {
    _writeTimepointAndUpdateFee();
    return IAlgebraPlugin.beforeSwap.selector;
  }

  function afterSwap(address) external onlyPool returns (bytes4) {
    (int24 tick, , ) = _getPoolState();
    IAlgebraVirtualPool(incentive).crossTo(tick);
    return IAlgebraPlugin.afterSwap.selector;
  }

  function beforeFlash(address, uint256, uint256) external view onlyPool returns (bytes4) {
    revert('Not implemented');
  }

  function afterFlash(address, uint256, uint256) external view onlyPool returns (bytes4) {
    revert('Not implemented');
  }

  function _writeTimepointAndUpdateFee() internal {
    (uint16 _lastIndex, uint32 _lastTimepointTimestamp) = (timepointIndex, lastTimepointTimestamp);

    if (_lastTimepointTimestamp == _blockTimestamp()) return;

    (int24 tick, uint16 fee, ) = _getPoolState();
    (bool updated, uint16 newLastIndex, ) = _writeTimepoint(_blockTimestamp(), tick, _lastIndex);
    if (updated) {
      uint16 newFee = _getFeeAtLastTimepoint(newLastIndex);

      if (newFee != fee) {
        IAlgebraPool(pool).setFee(newFee);
      }
    }
  }
}
