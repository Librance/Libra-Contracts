// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '../Library/Math.sol';
import '../Interface/IERC20.sol';
import '../Library/SafeERC20.sol';
import '../Utils/ReentrancyGuard.sol';

import '../Interface/IOracle.sol';
import '../Interface/IBoardroom.sol';
import '../Interface/ILibraAsset.sol';
import '../Interface/ISimpleERCFund.sol';
import '../Library/Babylonian.sol';
import '../Library/FixedPoint.sol';
import '../Library/Safe112.sol';
import '../Context/Operator.sol';
import '../Utils/Epoch.sol';
import '../Utils/ContractGuard.sol';

/**
 * @title Treasury  contract
 * @notice Monetary policy logic to adjust supplies of Libra assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== STATE VARIABLES ========== */

    // ========== FLAGS
    bool public migrated = false;
    bool public initialized = false;

    // ========== CORE
    address public fund;
    address public libra;
    address public libraBond;
    address public libraShare;
    address public boardroom;

    address public bondOracle;
    address public seigniorageOracle;

    // ========== PARAMS
    uint256 public libraPriceOne;
    uint256 public libraPriceCeiling;
    uint256 public bondDepletionFloor;
    uint256 private accumulatedSeigniorage = 0;
    uint256 public fundAllocationRate = 2; // %

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _libra,
        address _libraBond,
        address _libraShare,
        address _bondOracle,
        address _seigniorageOracle,
        address _boardroom,
        address _fund,
        uint256 _startTime
    ) public Epoch(1 days, _startTime, 0) {
        libra = _libra;
        libraBond = _libraBond;
        libraShare = _libraShare;
        bondOracle = _bondOracle;
        seigniorageOracle = _seigniorageOracle;

        boardroom = _boardroom;
        fund = _fund;

        libraPriceOne = 10**18;
        libraPriceCeiling = uint256(105).mul(libraPriceOne).div(10**2);

        bondDepletionFloor = uint256(1000).mul(libraPriceOne);
    }

    /* =================== Modifier =================== */

    modifier checkMigration {
        require(!migrated, 'LibraCore: migrated');

        _;
    }

    modifier checkOperator {
        require(
            ILibraAsset(libra).operator() == address(this) &&
                ILibraAsset(libraBond).operator() == address(this) &&
                ILibraAsset(libraShare).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            'LibraCore: need more permission'
        );

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // budget
    function getReserve() public view returns (uint256) {
        return accumulatedSeigniorage;
    }

    // oracle
    function getBondOraclePrice() public view returns (uint256) {
        return _getCashPrice(bondOracle);
    }

    function getSeigniorageOraclePrice() public view returns (uint256) {
        return _getCashPrice(seigniorageOracle);
    }

    function _getCashPrice(address oracle) internal view returns (uint256) {
        try IOracle(oracle).consult(libra, 1e18) returns (uint256 price) {
            return price;
        } catch {
            revert('LibraCore: failed to consult libra price from the oracle');
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize() public checkOperator {
        require(!initialized, 'LibraCore: initialized');

        // set accumulatedSeigniorage to it's balance
        accumulatedSeigniorage = IERC20(libra).balanceOf(address(this));

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function migrate(address target) public onlyOperator checkOperator {
        require(!migrated, 'LibraCore: migrated');

        // libra
        Operator(libra).transferOperator(target);
        Operator(libra).transferOwnership(target);
        IERC20(libra).transfer(target, IERC20(libra).balanceOf(address(this)));

        // libraBond
        Operator(libraBond).transferOperator(target);
        Operator(libraBond).transferOwnership(target);
        IERC20(libraBond).transfer(target, IERC20(libraBond).balanceOf(address(this)));

        // libraShare
        Operator(libraShare).transferOperator(target);
        Operator(libraShare).transferOwnership(target);
        IERC20(libraShare).transfer(target, IERC20(libraShare).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    function setFund(address newFund) public onlyOperator {
        fund = newFund;
        emit ContributionPoolChanged(msg.sender, newFund);
    }

    function setFundAllocationRate(uint256 rate) public onlyOperator {
        fundAllocationRate = rate;
        emit ContributionPoolRateChanged(msg.sender, rate);
    }

        // ORACLE
    function setBondOracle(address newOracle) public onlyOperator {
        address oldOracle = bondOracle;
        bondOracle = newOracle;
        emit BondOracleChanged(_msgSender(), oldOracle, newOracle);
    }

    function setSeigniorageOracle(address newOracle) public onlyOperator {
        address oldOracle = seigniorageOracle;
        seigniorageOracle = newOracle;
        emit SeigniorageOracleChanged(_msgSender(), oldOracle, newOracle);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateCashPrice() internal {
        try IOracle(bondOracle).update()  {} catch {}
        try IOracle(seigniorageOracle).update()  {} catch {}
    }

    function buyBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        require(amount > 0, 'LibraCore: cannot purchase bonds with zero amount');

        uint256 libraPrice = _getCashPrice(bondOracle);
        require(libraPrice == targetPrice, 'LibraCore: libra price moved');
        require(
            libraPrice < libraPriceOne, 
            'Treasury: LibraCore not eligible for libraBond purchase'
        );

        uint256 libraBondPrice = libraPrice;

        ILibraAsset(libra).burnFrom(msg.sender, amount);
        ILibraAsset(libraBond).mint(msg.sender, amount.mul(1e18).div(libraBondPrice));
        _updateCashPrice();

        emit BoughtBonds(msg.sender, amount);
    }

    function redeemBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        require(amount > 0, 'LibraCore: cannot redeem bonds with zero amount');

        uint256 libraPrice = _getCashPrice(bondOracle);
        require(libraPrice == targetPrice, 'Treasury: libra price moved');
        require(
            libraPrice > libraPriceCeiling, 
            'LibraCore: libraPrice not eligible for libraBond purchase'
        );
        require(
            IERC20(libra).balanceOf(address(this)) >= amount,
            'Treasury: treasury has no more budget'
        );

        accumulatedSeigniorage = accumulatedSeigniorage.sub(
            Math.min(accumulatedSeigniorage, amount)
        );

        ILibraAsset(libraBond).burnFrom(msg.sender, amount);
        IERC20(libra).safeTransfer(msg.sender, amount);
        _updateCashPrice();

        emit RedeemedBonds(msg.sender, amount);
    }

    function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkOperator
    {
        _updateCashPrice();
        uint256 libraPrice = _getCashPrice(seigniorageOracle);
        if (libraPrice <= libraPriceCeiling) {
            return; // just advance epoch instead revert
        }

        // circulating supply
        uint256 cashSupply = IERC20(libra).totalSupply().sub(
            accumulatedSeigniorage
        );
        uint256 percentage = libraPrice.sub(libraPriceOne);
        uint256 seigniorage = cashSupply.mul(percentage).div(1e18);
        ILibraAsset(libra).mint(address(this), seigniorage);

        // ======================== BIP-3
        uint256 fundReserve = seigniorage.mul(fundAllocationRate).div(100);
        if (fundReserve > 0) {
            IERC20(libra).safeApprove(fund, fundReserve);
            ISimpleERCFund(fund).deposit(
                libra,
                fundReserve,
                'LibraCore: Seigniorage Allocation'
            );
            emit ContributionPoolFunded(now, fundReserve);
        }

        seigniorage = seigniorage.sub(fundReserve);

        // ======================== BIP-4
        uint256 treasuryReserve = Math.min(
            seigniorage,
            IERC20(libraBond).totalSupply().sub(accumulatedSeigniorage)
        );
        if (treasuryReserve > 0) {
            accumulatedSeigniorage = accumulatedSeigniorage.add(
                treasuryReserve
            );
            emit TreasuryFunded(now, treasuryReserve);
        }

        // boardroom
        uint256 boardroomReserve = seigniorage.sub(treasuryReserve);
        if (boardroomReserve > 0) {
            IERC20(libra).safeApprove(boardroom, boardroomReserve);
            IBoardroom(boardroom).allocateSeigniorage(boardroomReserve);
            emit BoardroomFunded(now, boardroomReserve);
        }
    }

    // GOV
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event ContributionPoolChanged(address indexed operator, address newFund);
    event ContributionPoolRateChanged(
        address indexed operator,
        uint256 newRate
    );
    event BondOracleChanged(
        address indexed operator,
        address oldOracle,
        address newOracle
    );
    event SeigniorageOracleChanged(
        address indexed operator,
        address oldOracle,
        address newOracle
    );
    // CORE
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event ContributionPoolFunded(uint256 timestamp, uint256 seigniorage);
}