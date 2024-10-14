// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.24;

// Import Interfaces
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Vaultable} from "../Vaultable.sol";
import {IMasterPool} from "../interfaces/IMasterPool.sol";
import {IFeederPool} from "../interfaces/IFeederPool.sol";
import {IDataVault} from "../interfaces/IDataVault.sol";
import {BaseFeederPool} from "./BaseFeederPool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFundingContract} from "../interfaces/IFundingContract.sol";
import {Validators} from "../utils/Validators.sol";

/// @title FeederPool - Maintains all accounting and functionality related to FeederPools.
contract FeederPoolFund is BaseFeederPool {
    using SafeERC20 for IERC20;

    // Funding contract
    address private _fundingContract;

    // Events
    event FundingContractChanged(address indexed fundingContract);
    event Funded(address fundingContract, uint256 amount);

    // Errors
    error NotFundingContract();

    // Modifiers
    modifier allowDeposit() override {
        if (_fundingContract != msg.sender) revert NotFundingContract();
        _;
    }

    modifier allowWithdraw() override {
        if (_fundingContract != msg.sender) revert NotFundingContract();
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
    )
        BaseFeederPool(
            dataVault_,
            impairmentRank_,
            tokensPerSecond_,
            masterPool_
        )
    {}

    /************************/
    /*** Governance Functions ***/
    /************************/

    /**
        @dev    Change state of funding contract in white list.
        @param  fundingContract_ Address of funding contract.
    */
    function setFundingContract(
        address fundingContract_
    ) external onlyAllOperator {
        _fundingContract = fundingContract_;

        emit FundingContractChanged(_fundingContract);
    }

    /**
        @dev    Request funding from external funding contract.
        @param  amount_ Amount to request for funding.
    */
    function requestFunding(uint256 amount_) external onlyAllOperator {
        IFundingContract(_fundingContract).fundPool(amount_);

        emit Funded(_fundingContract, amount_);
    }

    /**
        @dev    Getter returns funding contract.
    */
    function fundingContract() external view returns (address) {
        return _fundingContract;
    }
}
