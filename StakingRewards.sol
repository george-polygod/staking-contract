// SPDX-License-Identifier: MIT
// solhint-disable not-rely-on-time
pragma solidity ^0.8.3;

import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract StakingRewards is  ReentrancyGuardUpgradeable,OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /* ========== STATE VARIABLES ========== */
    IERC20Upgradeable public rewardsToken;
    IERC20Upgradeable public stakingToken;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalFees;
    uint256 public holdingTime;

    address public community;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userLastStackedTime;
    mapping(address => bool) public isBlackListed;

    uint256 public _totalSupply;
    mapping(address => uint256) public _balances;

    /* ========== Initialize ========== */

    function initialize(address _rewardsToken,address _stakingToken) public initializer{
         rewardsToken = IERC20Upgradeable(_rewardsToken);
         stakingToken = IERC20Upgradeable(_stakingToken);
         __Ownable_init();
         __ReentrancyGuard_init();

    }

    function updateFees(uint256 _totalFees) external onlyOwner{
        totalFees = _totalFees;
    }

    function updateHoldingTime(uint256 _holdingTime) external onlyOwner{
        holdingTime = _holdingTime;
    }

    function updateBlackList(address account, bool excluded) external onlyOwner{
        isBlackListed[account] = excluded;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view  returns (uint256) {
        return _totalSupply;
    }

    function isBlackListedAddress(address account) external view  returns (bool) {
        return isBlackListed[account];
    }

    function balanceOf(address account) external view  returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view  returns (uint256) {
        return MathUpgradeable.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view  returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account) public view  returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view  returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function stake(uint256 amount) external  nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        require(!isBlackListed[msg.sender],"User Blacklisted");

        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        userLastStackedTime[msg.sender] = block.timestamp;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public  nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, _partialFee(msg.sender,amount));
        emit Withdrawn(msg.sender, amount);
    }

    function _partialFee(address from,uint256 amount) internal returns (uint256) {
        return amount.sub(_calculateFeeAmount(from,amount));
    }

    function _calculateFeeAmount(address from,uint256 amount) internal returns (uint256) {
        // send Tax Funds to the smart contract
        uint256 totalFeeAmount = 0;
        if(block.timestamp.sub(userLastStackedTime[from]) < holdingTime)
        {
            totalFeeAmount = (amount.mul(totalFees)).div(100);
            stakingToken.safeTransfer(community,totalFeeAmount);
        }

        return totalFeeAmount;
    }

    function getReward() public  nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external  {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {

        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    // End rewards emission earlier
    function updatePeriodFinish(uint timestamp) external onlyOwner updateReward(address(0)) {
        periodFinish = timestamp;
    }

    function _transferFeesWallets(address newOwnerCom) public onlyOwner {
        community = newOwnerCom;
    }

    function updateTotalFees(uint256 _totalFees) external onlyOwner{
        totalFees = _totalFees;
    }

     function updateCHoldingTime(uint256 _holdingTime) external onlyOwner{
        holdingTime = _holdingTime;
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        IERC20Upgradeable(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(
            block.timestamp > periodFinish,
            "Rewards must be complete"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}
