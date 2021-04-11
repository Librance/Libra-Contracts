// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
import '../Library/SafeMath.sol';
import '../Interface/IERC20.sol';
import '../Interface/IDistributor.sol';
import '../Interface/IRewardDistributionRecipient.sol';

contract InitialPools is IDistributor {
    using SafeMath for uint256;

    event Distributed(address pool, uint256 libraAmount);

    bool public once = true;

    IERC20 public libra;
    IRewardDistributionRecipient[] public pools;
    uint256 public totalInitialBalance;

    constructor(
        IERC20 _libra,
        IRewardDistributionRecipient[] memory _pools,
        uint256 _totalInitialBalance
    ) public {
        require(_pools.length != 0, 'a list of Libra pools are required');

        libra = _libra;
        pools = _pools;
        totalInitialBalance = _totalInitialBalance;
    }

    function distribute() public override {
        require(
            once,
            'InitialCashDistributor: you cannot run this function twice'
        );

        for (uint256 i = 0; i < pools.length; i++) {
            uint256 amount = totalInitialBalance.div(pools.length);

            libra.transfer(address(pools[i]), amount);
            pools[i].notifyRewardAmount(amount);

            emit Distributed(address(pools[i]), amount);
        }

        once = false;
    }
}
