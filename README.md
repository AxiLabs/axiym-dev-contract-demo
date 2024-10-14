# axiym-dev-contract-demo
FeederPool Contracts

## Contracts
### FundingContract.sol
This is a demonstation contract. It should have three functions fundPool(), withdrawInterestPrincipal() and withdrawAll(). These functions allow it to interact with a Axiym FeederPool contract. Custom logic can be inserted as needed.

## Steps:
1) FundingContract.sol & FeederPool.sol deployed.
2) FeederPool.sol requests funding using requestFunding().
3) FundingContract receives request, processes request, and transfers funds to FeederPool.sol.
4) FundingContract can see balance at all times using FeederPool.getTotalBalance() function, and maxWithdrawal using FeederPool.getMaxWithdrawal() function.
5) FundingContract can request withdrawal using withdrawAll(), and withdrawInterestPrincipal().
