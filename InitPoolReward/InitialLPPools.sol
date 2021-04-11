// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
import '../Library/SafeMath.sol';
import '../Interface/IERC20.sol';
import '../Interface/IDistributor.sol';
import '../Interface/IRewardDistributionRecipient.sol';

contract InitialLPPools is IDistributor {
    using SafeMath for uint256;

    event Distributed(address pool, uint256 libraShareAmount);

    bool public once = true;

    IERC20 public libraShare;
    IRewardDistributionRecipient public libraUsdtLPPool;
    uint256 public libraUsdtInitialBalance;
    IRewardDistributionRecipient public libraShareUsdtLPPool;
    uint256 public libraShareUsdtInitialBalance;

    constructor(
        IERC20 _libraShare,
        IRewardDistributionRecipient _libraUsdtLPPool,
        uint256 _libraUsdtInitialBalance,
        IRewardDistributionRecipient _libraShareUsdtLPPool,
        uint256 _libraShareUsdtInitialBalance
    ) public {
        libraShare = _libraShare;
        libraUsdtLPPool = _libraUsdtLPPool;
        libraUsdtInitialBalance = _libraUsdtInitialBalance;
        libraShareUsdtLPPool = _libraShareUsdtLPPool;
        libraShareUsdtInitialBalance = _libraShareUsdtInitialBalance;
    }

    function distribute() public override {
        require(
            once,
            'InitialLibraShareDistributor: you cannot run this function twice'
        );

        libraShare.transfer(address(libraUsdtLPPool), libraUsdtInitialBalance);
        libraUsdtLPPool.notifyRewardAmount(libraUsdtInitialBalance);
        emit Distributed(address(libraUsdtLPPool), libraUsdtInitialBalance);

        libraShare.transfer(address(libraShareUsdtLPPool), libraShareUsdtInitialBalance);
        libraShareUsdtLPPool.notifyRewardAmount(libraShareUsdtInitialBalance);
        emit Distributed(address(libraShareUsdtLPPool), libraShareUsdtInitialBalance);

        once = false;
    }
}