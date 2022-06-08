// SPDX-License-Identifier: MIT
// solhint-disable not-rely-on-time
pragma solidity ^0.8.3;

import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "hardhat/console.sol";

contract StakingReward is  ReentrancyGuardUpgradeable,OwnableUpgradeable,AccessControlUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    struct Withdrawalfee{
        uint256 holdingTime;
        uint256 totalFees;
    }

    /* ========== STATE VARIABLES ========== */
    IERC20Upgradeable public stakingToken;
    uint256 public _totalSupply;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public lockedTime;
    address public community;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userLastStackedTime;
    mapping(address => bool) public isBlackListed;
    mapping(address => uint256) public _balances;

    Withdrawalfee[] public fees;


    /* ========== Initialize ========== */

    function initialize(address _stakingToken) public initializer{
         stakingToken = IERC20Upgradeable(_stakingToken);
         __Ownable_init();
         __ReentrancyGuard_init();
         __AccessControl_init();
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
    function stake(uint256 amount) external  nonReentrant updateReward(_msgSender()) {
        require(amount > 0, "Cannot stake 0");
        require(!isBlackListed[_msgSender()],"User Blacklisted");

        _totalSupply = _totalSupply.add(amount);
        _balances[_msgSender()] = _balances[_msgSender()].add(amount);
        userLastStackedTime[_msgSender()] = block.timestamp;
        stakingToken.safeTransferFrom(_msgSender(), address(this), amount);
        emit Staked(_msgSender(), amount);
    }

    function withdraw(uint256 amount) public  nonReentrant updateReward(_msgSender()) {
        uint256 stakedTime = block.timestamp.sub(userLastStackedTime[_msgSender()]);

        require(amount > 0, "Cannot withdraw 0");
        require(stakedTime > lockedTime, "Withdraw locked");
        
        _totalSupply = _totalSupply.sub(amount);
        _balances[_msgSender()] = _balances[_msgSender()].sub(amount);
        stakingToken.safeTransfer(_msgSender(), _partialFee(amount));
        emit Withdrawn(_msgSender(), amount);
    }


    function stakeRewards() external nonReentrant updateReward(_msgSender()) {
        uint256 reward = earned(_msgSender());
        require(reward > 0, "Cannot stake 0");

        rewards[_msgSender()] = 0;   
        _totalSupply = _totalSupply.add(reward);
        _balances[_msgSender()] = _balances[_msgSender()].add(reward);
        emit Staked(_msgSender(), reward);
    }

    function _partialFee(uint256 amount) internal returns (uint256) {
        return amount.sub(_calculateFeeAmount(amount));
    }

    function _calculateFeeAmount(uint256 amount) internal returns (uint256) {
        // send Tax Funds to the smart contract
        uint256 totalFeeAmount = 0;
        uint256 stakedTime = block.timestamp.sub(userLastStackedTime[_msgSender()]);
        for(uint256 i = 0; i < fees.length; i++) {
             Withdrawalfee memory fee = fees[i];
             if(stakedTime < fee.holdingTime)
             {
                    totalFeeAmount = (amount.mul(fee.totalFees)).div(100);
                    break;
             }
         }

         if(totalFeeAmount != 0 && community != address(0))
         {
             stakingToken.safeTransfer(community,totalFeeAmount);
         }

        return totalFeeAmount;
    }

    function getReward() public  nonReentrant updateReward(_msgSender()) {
        uint256 reward = rewards[_msgSender()];
        if (reward > 0) {
            rewards[_msgSender()] = 0;
            stakingToken.safeTransfer(_msgSender(), reward);
            emit RewardPaid(_msgSender(), reward);
        }
    }

    function exit() external  {
        withdraw(_balances[_msgSender()]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function notifyRewardAmount(uint256 reward) external onlyAdmins updateReward(address(0)) {

        stakingToken.safeTransferFrom(_msgSender(), address(this), reward);

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
        uint balance = stakingToken.balanceOf(address(this)).sub(_totalSupply);
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    // End rewards emission earlier
    function updatePeriodFinish(uint timestamp) external onlyAdmins {
        periodFinish = timestamp;
    }

    function transferFeesWallets(address newOwnerCom) public onlyAdmins {
        community = newOwnerCom;
    }

    function updateFees(Withdrawalfee[] calldata _fees) external onlyAdmins{
        delete fees;

        uint256 len = _fees.length;
        for (uint256 i = 0; i < len; i++) {
           Withdrawalfee memory _fee = _fees[i];
           fees.push(_fee);
        }

    }

    function updateBlackList(address account, bool excluded) external onlyAdmins{
        isBlackListed[account] = excluded;
    }

    function updateLockedTime(uint256 _lockedTime) external onlyAdmins{
        lockedTime = _lockedTime;
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyAdmins {
        IERC20Upgradeable(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyAdmins {
        require(
            block.timestamp > periodFinish,
            "Rewards must be complete"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function addAdminRole(address admin) public onlyOwner {
        _setupRole(ADMIN_ROLE, admin);
    }

    function revokeAdminRole(address admin) public onlyAdmins {
        revokeRole(ADMIN_ROLE, admin);
    }

    function adminRole(address admin) public view returns (bool) {
        return hasRole(ADMIN_ROLE, admin);
    }

    modifier onlyAdmins() {
        require(
            hasRole(ADMIN_ROLE, _msgSender()) || owner() == _msgSender(),
            "You don't have permission"
        );
        _;
    }


    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        console.log(lastUpdateTime);
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
