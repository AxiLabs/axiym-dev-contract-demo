// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFundingContract} from "../interfaces/IFundingContract.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IFeederPool} from "../interfaces/IFeederPool.sol";

// title - Demo funding contract.
contract FundingContract is IFundingContract {
    // State variables
    address private _pool; // address of pool to fund
    IERC20 private _liquidityAsset; // address of funding asset

    // Errors
    error Unauthorized();
    error InsufficientFunds();

    constructor(address pool_, IERC20 liquidityAsset_) {
        _pool = pool_;
        _liquidityAsset = liquidityAsset_;
    }

    /**
        @dev    This function is called by pool contract. It should implement custom logic
        @dev    and call deposit function back in pool contract.
        @param  amount_ Amount requested to fund.
    */
    function fundPool(uint256 amount_) external {
        // checks and balances
        if (msg.sender != _pool) revert Unauthorized();
        if (_liquidityAsset.balanceOf(address(this)) < amount_)
            revert InsufficientFunds();
        // custom logic
        // - insert here

        // Approve transfer and call deposit in pool
        _liquidityAsset.approve(_pool, amount_);
        IFeederPool(_pool).deposit(amount_);
    }

    /**
        @dev    Demonstration function of how to withdraw partial amount.
        @param  amount_ Amount requested to withdraw.
    */
    function withdrawInterestPrincipal(uint256 amount_) external {
        IFeederPool(_pool).withdrawInterestPrincipal(amount_);
    }

    /**
        @dev    Demonstration function of how to withdraw all.
    */
    function withdrawAll() external {
        IFeederPool(_pool).withdrawAll();
    }

    function pool() external view returns (address) {
        return _pool;
    }

    function liquidityAsset() external view returns (IERC20) {
        return _liquidityAsset;
    }
}
