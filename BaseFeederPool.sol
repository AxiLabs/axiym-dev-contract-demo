// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.24;

// Import Interfaces
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IMasterPool} from "../interfaces/IMasterPool.sol";
import {IFeederPool} from "../interfaces/IFeederPool.sol";
import {IDataVault} from "../interfaces/IDataVault.sol";
import {ContractType} from "../enums/ContractType.sol";
import {RewardLocker} from "../rewards/RewardLocker.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Errors} from "../utils/Errors.sol";
import {Validators} from "../utils/Validators.sol";

/// @title BaseFeederPool - Base Feeder Pool contract
abstract contract BaseFeederPool is RewardLocker, IFeederPool {
    using SafeERC20 for IERC20;

    IERC20 private immutable _liquidityAsset;

    IMasterPool private immutable _masterPool;
    uint256 private _impairmentRank; // 0 = lowest rank.

    // Default share split (balance goes to devS)
    uint256 private _depositorShare = 60;

    // Boolean set to false when pool is fully impaired (can't be reversed)
    bool private _active;

    // Governance booleans to control deposits and withdraws of interest and rewards
    bool private _interestDepositsStatus = true; // allow deposits of interest
    bool private _interestWithdrawStatus = true; // allow withdraws of interest

    // Registered InternalBridges
    mapping(address => bool) private _internalBridges;

    // Variables related to interest
    mapping(address => uint256) private _depositorInterestUnits; // amount of units owed in interest pool
    uint256 private _feederPoolValue; // the feeder pool value (updated by checking masterPool)
    uint256 private _interestUnitTotal; // amount of units in interest pool

    // Operation Events
    event Deposited(
        address indexed lenderAddress,
        uint256 amount,
        uint256 principalDeposit,
        uint256 principalDepositTotal,
        uint256 mintInterestUnits,
        uint256 interestUnits,
        uint256 interestUnitTotal
    );
    event Withdrawn(
        address indexed lenderAddress,
        uint256 amount,
        uint256 principalDeposit,
        uint256 principalDepositTotal,
        int256 interest,
        uint256 burnInterestUnits,
        uint256 interestUnits,
        uint256 interestUnitTotal
    );
    event ValueChanged(uint256 value);
    event ImpairmentRankChanged(uint256 impairmentRank);

    event InterestDepositStatusChanged(bool status);
    event InterestWithdrawStatusChanged(bool status);
    event InternalBridgeStatusChanged(address internalBridge, bool status);

    event DepositorShareChanged(uint256 depositorShare);

    // Governance Events
    event Disabled();

    // errors
    error InactiveDeposits();
    error DeactivatePool();
    error InactiveWithdraw();
    error InsufficientFunds();
    error InvalidIMPRank();

    // Modifiers
    modifier allowDeposit() virtual {
        _;
    }

    modifier allowWithdraw() virtual {
        _;
    }

    /**
        @dev    Constructor.
        @param  dataVault_ DataVault used for storage.
        @param  masterPool_ Address of master Pool related to this Feeder pool.
    */
    constructor(
        IDataVault dataVault_,
        uint256 impairmentRank_, // 0 = lowest rank
        uint256 tokensPerSecond_,
        IMasterPool masterPool_
    ) RewardLocker(dataVault_, tokensPerSecond_) {
        _impairmentRank = impairmentRank_;
        _liquidityAsset = masterPool_.liquidityAsset();
        _masterPool = masterPool_;
        _liquidityAsset.approve(address(_masterPool), type(uint256).max);
        _active = true;
    }

    /************************/
    /*** Transactional Functions for Lenders ***/
    /************************/

    /**
        @dev    Lender depositing into the Feeder Pool.
        @param  amount_ Amount a lender wishes to deposit into the Feeder Pool.
    */
    function deposit(uint256 amount_) external allowDeposit nonReentrant {
        if (!_interestDepositsStatus) revert InactiveDeposits(); // check pool open to deposits
        if (!_active) revert DeactivatePool(); // check pool not deactivated.
        Validators.isNonZero(amount_);

        _updateRewardFactorLocal(); // update the token factor for time since last transaction
        // Adjust the depositors reward Factor for new deposit
        _updateDepositorRewardFactor(amount_);

        uint256 unitsMined = _mintInterestUnits(msg.sender, amount_);

        _principalDeposits[msg.sender] += amount_; // update the principal deposited by this depositor
        _principalDepositTotal += amount_; // update total amount of principal in interest pool

        // Transfer funds, and make feeder deposit into masterPool
        _liquidityAsset.safeTransferFrom(msg.sender, address(this), amount_);

        _masterPool.depositFeeder(amount_);

        _updateFeederPoolValue();

        emit Deposited(
            msg.sender,
            amount_,
            _principalDeposits[msg.sender],
            _principalDepositTotal,
            unitsMined,
            _depositorInterestUnits[msg.sender],
            _interestUnitTotal
        );
    }

    /**
        @dev    Depositor requests to withdraw total amount.
        @param  amount_ Total amount a lender wishes to withdraw from the Pool.
    */
    function withdrawInterestPrincipal(
        uint256 amount_
    ) external allowWithdraw nonReentrant {
        if (!_interestWithdrawStatus) revert InactiveWithdraw(); // check pool open to withdraw
        if (!_active) revert DeactivatePool(); // check pool not deactivated.
        Validators.isNonZero(amount_);

        _updateRewardFactorLocal(); // update the token factor for time since last transaction

        // Calculate total balance (units in feeder pool vs. total) of depositor and check they have enough funds
        uint256 totalBalance = getTotalBalance(msg.sender);
        if (amount_ >= totalBalance) revert InsufficientFunds();

        // Calculate amount of interest units to sell for depositor to generate amount
        uint256 unitsBurn = ((amount_ * _depositorInterestUnits[msg.sender]) /
            totalBalance);

        // Calculate scaled amount (which will include dev share of interest)
        uint256 scaledAmount = _scaledAmount(unitsBurn);

        // Calculate associated amount of principal being sold from interest and reward pool (proportional)
        uint256 principalWithdraw = (unitsBurn *
            _principalDeposits[msg.sender]) /
            _depositorInterestUnits[msg.sender];

        _withdraw(principalWithdraw, scaledAmount, unitsBurn);
    }

    /**
        @dev    Depositor wishes to withdraw everything.
    */
    function withdrawAll() external allowWithdraw nonReentrant {
        if (!_interestWithdrawStatus) revert InactiveWithdraw(); // check pool open to withdraw
        if (!_active) revert DeactivatePool(); // check pool not deactivated.
        Validators.isNonZero(_depositorInterestUnits[msg.sender]);

        _updateRewardFactorLocal(); // update the token factor for time since last transaction

        // Calculate depositor share based on their units (includes dev interest)
        uint256 scaledAmount = _scaledAmount(
            _depositorInterestUnits[msg.sender]
        );

        uint256 unitsBurn = _depositorInterestUnits[msg.sender];

        _withdraw(_principalDeposits[msg.sender], scaledAmount, unitsBurn);
    }

    /**
        @dev    Updates state variables when withdrawal made.
        @param  principalWithdraw_ Amount of interest principal being sold.
        @param  scaledAmount_ The total amount of funds owed to the depositor.
    */
    function _withdraw(
        uint256 principalWithdraw_,
        uint256 scaledAmount_,
        uint256 unitsBurn_
    ) internal {
        lockTokens(principalWithdraw_);
        // scaled amount rounded down, we add back for calculations here to stop underflow
        // if withdrawal coming from internal bridge devShare is 0.
        uint256 devShare = 0;
        if (
            scaledAmount_ + 1 > principalWithdraw_ &&
            !_internalBridges[msg.sender]
        ) {
            devShare =
                ((scaledAmount_ + 1 - principalWithdraw_) *
                    (100 - _depositorShare)) /
                100;
        }

        // reduce the depositor interest principal by the amount sold and reduce total principal in interest pool
        _principalDeposits[msg.sender] -= principalWithdraw_;
        _principalDepositTotal -= principalWithdraw_;

        // burn interest units
        uint256 unitsBurned = _burnInterestUnits(msg.sender, unitsBurn_);

        // Make feeder pool deposit into masterPool and transfer funds
        _masterPool.withdrawFeeder(scaledAmount_);

        _updateFeederPoolValue(); // get latest value of feeder pool from master pool

        // Make transfers
        _liquidityAsset.safeTransfer(msg.sender, scaledAmount_ - devShare);

        if (devShare > 0) {
            _liquidityAsset.safeTransfer(
                dataVault.governance().safeVault(),
                devShare
            );
        }
        // Add back rounding to amount.
        emit Withdrawn(
            msg.sender,
            principalWithdraw_,
            _principalDeposits[msg.sender],
            _principalDepositTotal,
            int256(scaledAmount_) -
                int256(devShare) -
                int256(principalWithdraw_),
            unitsBurned,
            _depositorInterestUnits[msg.sender],
            _interestUnitTotal
        );
    }

    /************************/
    /*** Minting and Burning Functions for Interest Units ***/
    /************************/

    /**
        @dev    Control minting process for units in interest pool as result of deposit into feeder pool.
        @param  lenderAddress_ Address of lender.
        @param  amount_ Amount a lender wishes to deposit into the feeder pool.
    */
    function _mintInterestUnits(
        address lenderAddress_,
        uint256 amount_
    ) private returns (uint256) {
        uint256 unitsMined = 0;
        // First depositor into feeder pool distributed same units as their principal
        if (_interestUnitTotal == 0) {
            unitsMined = amount_;
        } else {
            unitsMined =
                (amount_ * _interestUnitTotal) /
                (_masterPool.getFeederPoolValueLatest(address(this))); // calculate new interest units to mint
        }

        // no rounding adjustment needs to occur here as everything has already been rounded down
        _depositorInterestUnits[lenderAddress_] += unitsMined;
        _interestUnitTotal += unitsMined;

        return unitsMined;
    }

    /**
        @dev    Control burning process for units in interest pool as result of deposit into feeder pool.
        @param  lenderAddress_ Address of lender.
        @param  amount_ Amount a lender wishes to deposit into the feeder pool.
    */
    function _burnInterestUnits(
        address lenderAddress_,
        uint256 amount_
    ) private returns (uint256) {
        // Check we can apply rounding adjustment
        uint256 unitsBurned = amount_;

        if (
            amount_ != _interestUnitTotal &&
            amount_ != _depositorInterestUnits[lenderAddress_]
        ) {
            // Burn an extra unit to avoid people gaining monies
            unitsBurned += 1;
        }

        _depositorInterestUnits[lenderAddress_] -= unitsBurned;
        _interestUnitTotal -= unitsBurned;

        return unitsBurned;
    }

    /************************/
    /*** Helper Functions for Calculations ***/
    /************************/

    /**
        @dev    Get the latest value of the feeder pool from the master pool.
    */
    function _updateFeederPoolValue() internal {
        _feederPoolValue = _masterPool.getFeederPoolValue();

        emit ValueChanged(_feederPoolValue);
    }

    /**
        @dev    Calculated scaled amount (principal + total interest) from burnUnits.
        @param  unitsBurn Units being burned.
    */
    function _scaledAmount(uint256 unitsBurn) public view returns (uint256) {
        return
            (unitsBurn * _masterPool.getFeederPoolValueLatest(address(this))) /
            _interestUnitTotal;
    }

    /************************/
    /*** Governance Functions ***/
    /************************/

    /**
        @dev    Set depositor as InternalBridge.
        @param  status_ new status.
    */
    function setInternalBridge(
        address internalBridge_,
        bool status_
    ) external onlyAllGovernance {
        _internalBridges[internalBridge_] = status_;

        emit InternalBridgeStatusChanged(internalBridge_, status_);
    }

    /**
        @dev    Set status of activity for deposits into interest pool.
        @param  status_ new status.
    */
    function setInterestDepositStatus(bool status_) external onlyAllOperator {
        if (_interestDepositsStatus == status_) revert Errors.InvalidStatus();
        _interestDepositsStatus = status_;

        emit InterestDepositStatusChanged(status_);
    }

    /**
        @dev    Get status of activity for deposits into interest pool.
    */
    function interestDepositStatus() external view returns (bool) {
        return _interestDepositsStatus;
    }

    /**
        @dev    Set status of activity for withdraws out of interest pool.
        @param  status_ new status.
    */
    function setInterestWithdrawStatus(bool status_) external onlyAllOperator {
        if (_interestWithdrawStatus == status_) revert Errors.InvalidStatus();
        _interestWithdrawStatus = status_;

        emit InterestWithdrawStatusChanged(status_);
    }

    /**
        @dev    Get status of activity for withdraws out of interest pool.
    */
    function interestWithdrawStatus() external view returns (bool) {
        return _interestWithdrawStatus;
    }

    /**
        @dev    Set impairment rank of feeder pool.
        @param  impairmentRank_ new impairment rank.
    */
    function setImpairmentRank(
        uint256 impairmentRank_
    ) external onlyAllOperator {
        if (_impairmentRank == impairmentRank_) revert InvalidIMPRank();
        _impairmentRank = impairmentRank_;

        emit ImpairmentRankChanged(_impairmentRank);
    }

    /**
        @dev    Set depositor share.
        @param  depositorShare_ new depositor share.
    */
    function setDepositorShare(
        uint256 depositorShare_
    ) external onlyAllGovernance {
        _depositorShare = depositorShare_;

        emit DepositorShareChanged(_depositorShare);
    }

    /**
        @dev Disable pool - called when pool fully impaired, effectively makes it inaccessible to access interest units.
    */
    function disable() external {
        if (msg.sender != dataVault.getContract(ContractType.MasterLiquidator))
            revert Errors.Unauthorized();

        _active = false;
        emit Disabled();
    }

    /************************/
    /*** Getter / Setter Functions ***/
    /************************/

    /**
        @dev    Gets earned interest for depositor up until latest block.
        @param  lenderAddress_ Lender address.
    */
    function getEarnedInterest(
        address lenderAddress_
    ) public view returns (uint256) {
        // get the total balance of the lender
        uint256 totalBalance_ = getTotalBalance(lenderAddress_);

        if (_active && totalBalance_ >= _principalDeposits[lenderAddress_]) {
            return totalBalance_ - _principalDeposits[lenderAddress_];
        }
        return 0;
    }

    /**
        @dev    Gets balance for depositor up until latest block (excludes dev interest)
        @param  lenderAddress_ Lender address.
    */
    function getTotalBalance(
        address lenderAddress_
    ) public view returns (uint256) {
        if (_active && _interestUnitTotal > 0) {
            // Get principal + total interest
            uint256 scaledAmount = _scaledAmount(
                _depositorInterestUnits[lenderAddress_]
            );

            // if no interest, just return scaled amount, otherwise deduct dev share
            // internal bridges do not pay dev share.
            if (
                scaledAmount <= _principalDeposits[lenderAddress_] ||
                _internalBridges[lenderAddress_]
            ) {
                return scaledAmount;
            } else {
                uint256 totalInterest = scaledAmount -
                    _principalDeposits[lenderAddress_];

                return
                    _principalDeposits[lenderAddress_] +
                    ((totalInterest * _depositorShare) / 100);
            }
        }
        return 0;
    }

    /**
        @dev    Gets maximum amount a depositor can successfully withdraw.
        @dev    This is only up to latest block, so will be inaccurate when new block mined.
        @param  lenderAddress_ Lender address.
    */
    function getMaxWithdrawal(
        address lenderAddress_
    ) public view returns (uint256) {
        if (
            _depositorInterestUnits[lenderAddress_] == 0 ||
            _interestUnitTotal == 0
        ) {
            return 0;
        }

        uint256 availableLiquidity = _liquidityAsset.balanceOf(
            address(_masterPool)
        );

        uint256 scaledAmount = _scaledAmount(
            _depositorInterestUnits[lenderAddress_]
        );

        uint256 totalBalance = getTotalBalance(lenderAddress_);

        // Enough funds to pay out lender and developer interest
        if (scaledAmount <= availableLiquidity) {
            return totalBalance;
        } else {
            // No interest earned, so max payout will equal available liquidity
            if (scaledAmount <= _principalDeposits[lenderAddress_]) {
                return availableLiquidity;
            } else {
                return
                    uint256(
                        availableLiquidity * _interestUnitTotal * totalBalance
                    ) /
                    (_principalDeposits[lenderAddress_] *
                        _masterPool.getFeederPoolValueLatest(address(this)));
            }
        }
    }

    /**
        @dev    Returns the master pool.
    */
    function masterPool() external view returns (IMasterPool) {
        return _masterPool;
    }

    /**
        @dev    Returns true.
    */
    function isFeederPool() external pure returns (bool) {
        return true;
    }

    /**
        @dev    Get Liquidity Asset.
    */
    function liquidityAsset() external view returns (IERC20) {
        return _liquidityAsset;
    }

    /**
        @dev    Get Total Interest Units
    */
    function interestUnitTotal() external view returns (uint256) {
        return _interestUnitTotal;
    }

    /**
        @dev    Get Last Feeder Pool Value
    */
    function value() external view returns (uint256) {
        return _feederPoolValue;
    }

    /**
        @dev    Get activity status
    */
    function activeStatus() external view returns (bool) {
        return _active;
    }

    /**
        @dev    Get impairment rank
    */
    function impairmentRank() external view returns (uint256) {
        return _impairmentRank;
    }

    /**
        @dev    Get depositor share
    */
    function depositorShare() external view returns (uint256) {
        return _depositorShare;
    }

    /**
        @dev    True if internal bridge.
        @param  internalBridge_ address of internal bridge.
    */
    function internalBridge(
        address internalBridge_
    ) external view returns (bool) {
        return _internalBridges[internalBridge_];
    }

    /**
        @dev    Get Depositor Interest Principal
        @param  lenderAddress_ Address of lender.
    */
    function principalDeposits(
        address lenderAddress_
    ) external view returns (uint256) {
        return _principalDeposits[lenderAddress_];
    }

    /**
        @dev    Get Depositor Interest Units
        @param  lenderAddress_ Address of lender.
    */
    function depositorInterestUnits(
        address lenderAddress_
    ) external view returns (uint256) {
        return _depositorInterestUnits[lenderAddress_];
    }
}
