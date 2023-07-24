//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./VotePowerQueue.sol";

interface IInvite {
    function addRecord(address) external returns(bool);
    function getParents(address) external view returns(address);
    function getChilds(address) external view returns(address[] memory);
    function getInviteNum(address) external view returns(uint256);
}

interface IPINK{
    function mint() external;
    function balanceOf(address _account) external view returns(uint256);
    function totalSupply() external view returns(uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

///
///  @title eSpace PoSPool
///
contract PosStake is Ownable, Initializable {
  using SafeMath for uint256;
  using Address for address;
  using EnumerableSet for EnumerableSet.AddressSet;
  using VotePowerQueue for VotePowerQueue.InOutQueue;

  uint256 private constant RATIO_BASE = 10000;
  uint256 private constant ONE_DAY_BLOCK_COUNT = 3600 * 24;
  
  
  // ======================== Pool config =========================
  // wheter this poolContract registed in PoS
  bool public birdgeAddrSetted;
  address private _bridgeAddress;
  // fee manager
  address private _devAddress;
  address private _communityAddress;
  uint256 public devRatio = 500;
  uint256 public communityRatio = 200;
  // address Invite 
  address public inviteAddress;
  // address PINK 
  address public pinkAddress;
  // ratio shared by user: 1-10000
  uint256 public poolUserShareRatio = 9700;
  string public poolName; 
  uint256 private _poolAPY = 0;

  uint256 private _minStakeLimit;
  uint256 private _unstakeCFXs;

  // lock period: 15 days or 2 days
  uint256 private _poolLockPeriod_slow ; //= ONE_DAY_BLOCK_COUNT * 15; 1296000
  uint256 private _poolLockPeriod_fast;  // = ONE_DAY_BLOCK_COUNT * 2; 172800

  // ======================== Contract states =========================
  // global pool accumulative reward for each cfx
  uint256 public accRewardPerCfx;  // start from 0
  uint256 public accPinkRewardPerCfx;

  uint256 public airdrop;

  PoolSummary private _poolSummary;
  mapping(address => UserSummary) private userSummaries;
  mapping(address => RebateSummary) private rebateSummaries;
  mapping(address => VotePowerQueue.InOutQueue) private userInqueues;
  mapping(address => VotePowerQueue.InOutQueue) private userOutqueues;

  PoolShot public lastPoolShot;
  mapping(address => UserShot) public lastUserShots;
  
  EnumerableSet.AddressSet private stakers;


  // ======================== Struct definitions =========================
  struct PoolSummary {
    uint256 votes;
    uint256 available;
    uint256 unlockingCFX;
    uint256 interest; // PoS pool current interest
    uint256 totalInterest; // total historical interest of whole pools
    uint256 totalPink;
  }

  /// @title UserSummary
  /// @custom:field votes User's total votes
  /// @custom:field available User's avaliable votes
  /// @custom:field locked
  /// @custom:field unlocked
  /// @custom:field claimedInterest
  /// @custom:field currentInterest
  struct UserSummary {
    uint256 available; // locking + locked
    uint256 locked;
    uint256 unlocking;
    uint256 unlocked;
    uint256 claimedInterest; // total historical claimed interest
    uint256 currentInterest; // current claimable interest
    uint256 claimedPink;
    uint256 currentPink;
  }

  struct RebateSummary {
    uint256 claimed; // claimed 
    uint256 current; // current claimable
  }

  struct PoolShot {
    uint256 available;
    uint256 balance;
    uint256 balancePink;
    uint256 blockNumber;
  } 

  struct UserShot {
    uint256 available;
    uint256 accRewardPerCfx;
    uint256 accPinkRewardPerCfx;
    uint256 blockNumber;
  }

  // ======================== Modifiers =========================
  modifier onlyRegisted() {
    require(birdgeAddrSetted, "Pool is not setted");
    _;
  }

  modifier onlyBridge() {
    require(msg.sender == _bridgeAddress, "Only bridge is allowed");
    _;
  }

  // ======================== Helpers =========================
  function _selfBalance() internal view virtual returns (uint256) {
    return address(this).balance;
  }
  
  function _selfBalancePink() internal view virtual returns (uint256) {
    return IPINK(pinkAddress).balanceOf(address(this));
  }

  function _blockNumber() internal view virtual returns (uint256) {
    return block.number;
  }

  function _userShareRatio() public view returns (uint256) {
    return poolUserShareRatio;
  }

  function _calUserShare(uint256 reward, address _stakerAddress) private view returns (uint256) {
    return reward.mul(_userShareRatio()).div(RATIO_BASE);
  }

  // used to update lastPoolShot after _poolSummary.available changed 
  function _updatePoolShot() private {
    lastPoolShot.available = _poolSummary.available;
    lastPoolShot.balance = _selfBalance();
    lastPoolShot.balancePink = _selfBalancePink();
    lastPoolShot.blockNumber = _blockNumber();
  }

  // used to update lastUserShot after userSummary.available and accRewardPerCfx changed
  function _updateUserShot(address _user) private {
    lastUserShots[_user].available = userSummaries[_user].available;
    lastUserShots[_user].accRewardPerCfx = accRewardPerCfx;
    lastUserShots[_user].accPinkRewardPerCfx = accPinkRewardPerCfx;
    lastUserShots[_user].blockNumber = _blockNumber();
  }

  // used to update accRewardPerCfx after _poolSummary.available changed or user claimed interest
  // depend on: lastPoolShot.available and lastPoolShot.balance
  function _updateAccRewardPerCfx() private {
    uint256 reward = _selfBalance() - lastPoolShot.balance;
    if (reward == 0 || lastPoolShot.available == 0) return;

    // update global accRewardPerCfx
    uint256 cfxCount = lastPoolShot.available.div(1 ether);
    accRewardPerCfx = accRewardPerCfx.add(reward.div(cfxCount));

    // update pool interest info
    _poolSummary.totalInterest = _poolSummary.totalInterest.add(reward);

    //accPinkRewardPerCfx
    uint256 rewardPink = _selfBalancePink() - lastPoolShot.balancePink;
    if (rewardPink == 0) return;

    accPinkRewardPerCfx = accPinkRewardPerCfx.add(rewardPink.div(cfxCount));   
    _poolSummary.totalPink = _poolSummary.totalPink.add(rewardPink);  
  }

  // depend on: accRewardPerCfx and lastUserShot
  function _updateUserInterest(address _user) private {
    UserShot memory uShot = lastUserShots[_user];
    if (uShot.available == 0) return;
    uint256 latestInterest = accRewardPerCfx.sub(uShot.accRewardPerCfx).mul(uShot.available.div(1 ether));
    uint256 _userInterest = _calUserShare(latestInterest, _user);
    userSummaries[_user].currentInterest = userSummaries[_user].currentInterest.add(_userInterest);
    _poolSummary.interest = _poolSummary.interest.add(latestInterest.sub(_userInterest));

    //pink
    uint256 latestPink = accPinkRewardPerCfx.sub(uShot.accPinkRewardPerCfx).mul(uShot.available.div(1 ether));
    userSummaries[_user].currentPink = userSummaries[_user].currentPink.add(latestPink);
    
    //rebateSummaries
    IInvite invite = IInvite(inviteAddress);
    address parent = invite.getParents(_user);
    uint256 rebate = latestInterest.sub(_userInterest);
    rebateSummaries[parent].current = rebateSummaries[parent].current.add(rebate);

  }

  // ======================== Events =========================

  event IncreasePoSStake(address indexed user, uint256 votePower);

  event DecreasePoSStake(address indexed user, uint256 votePower);

  event WithdrawStake(address indexed user, uint256 votePower);

  event ClaimInterest(address indexed user, uint256 amount);

  event RatioChanged(uint256 ratio);

  // ======================== Init methods =========================
  // call this method when depoly the 1967 proxy contract
  function initialize() public initializer {
    devRatio = 500;
    communityRatio = 200;
    poolUserShareRatio = 9700;
    poolName = "Pink Pool";
    _minStakeLimit = 1 ether;
    _poolLockPeriod_slow = ONE_DAY_BLOCK_COUNT * 16;
    _poolLockPeriod_fast = ONE_DAY_BLOCK_COUNT * 2;
    airdrop = 100000000 * 10**18;

    //register pool 1000cfx
    userSummaries[msg.sender].locked = 1000 ether;
    userSummaries[msg.sender].available = 1000 ether;
    lastUserShots[msg.sender].available = userSummaries[msg.sender].available;
    _poolSummary.available = 1000 ether;
    lastPoolShot.available = _poolSummary.available;
    stakers.add(msg.sender);
  }

  // ======================== Contract methods =========================

  ///
  /// @notice Increase CFX Stake
  ///
  function increaseStake() public virtual payable onlyRegisted {
    require(msg.value > 0, "Minimal stake amount is 1");

    // transfer to bridge address
    address payable receiver = payable(_bridgeAddress);
    receiver.transfer(msg.value);
    emit IncreasePoSStake(msg.sender,  msg.value);

    _updateAccRewardPerCfx();
    
    // update user interest
    _updateUserInterest(msg.sender);

    userSummaries[msg.sender].locked += msg.value;
    userSummaries[msg.sender].available += msg.value;
    _updateUserShot(msg.sender);

    //pool
    _poolSummary.available += msg.value;
    _updatePoolShot();

    stakers.add(msg.sender);
  }

  function mode_estim(uint256 _amount) public view returns(uint256){
    uint256 cfx_back = _amount;
    uint256 mode = 0;  //default slow mode
    if(cfx_back<=_poolSummary.votes.mul(1000 ether)){
      mode = 1;  //set fast mode
    }
    return (mode);
  }

  ///
  /// @notice Decrease PoS Stake
  /// @param amount The number of CFX to decrease
  ///
  function decreaseStake(uint256 amount) public virtual onlyRegisted {
    require(amount > 0, "amount mush > 0");
    require(userSummaries[msg.sender].locked >= amount, "Locked is not enough");

    userSummaries[msg.sender].locked -= amount;
    
    uint256 _mode = 0;
    (_mode) = mode_estim(amount);

    if(_mode == 1){
      userOutqueues[msg.sender].enqueue(VotePowerQueue.QueueNode(amount, block.number + _poolLockPeriod_fast));
      }
    else{
      userOutqueues[msg.sender].enqueue(VotePowerQueue.QueueNode(amount, block.number + _poolLockPeriod_slow));
    }

    _updateAccRewardPerCfx();

    // update user interest
    _updateUserInterest(msg.sender);
    
    userSummaries[msg.sender].available -= amount;
    userSummaries[msg.sender].unlocking += amount;

    collectOutqueuesFinishedVotes();

    _updateUserShot(msg.sender);

     _unstakeCFXs += amount;

    emit DecreasePoSStake(msg.sender, amount); 

    _poolSummary.unlockingCFX += amount;
    _poolSummary.available -= amount;
    _updatePoolShot();
  }

  ///
  /// @notice Withdraw PoS amount
  /// @param amount The number of vote power to withdraw
  ///
  function withdrawStake(uint256 amount) public onlyRegisted {
    collectOutqueuesFinishedVotes();
    require(userSummaries[msg.sender].unlocked >= amount, "Unlocked is not enough");
    uint256 _withdrawAmount = amount;
    require(address(this).balance >= _withdrawAmount,"pool Unlocked CFX is not enough");
    //    
    _poolSummary.unlockingCFX -= _withdrawAmount;
    userSummaries[msg.sender].unlocked -= _withdrawAmount;
    
    address payable receiver = payable(msg.sender);
    receiver.transfer(_withdrawAmount);
    emit WithdrawStake(msg.sender, _withdrawAmount);

    _updatePoolShot();

    if (userSummaries[msg.sender].available == 0) {
      stakers.remove(msg.sender);
    }

  }

  function collectOutqueuesFinishedVotes() private {
    uint256 temp_amount = userOutqueues[msg.sender].collectEndedVotes();
    userSummaries[msg.sender].unlocked += temp_amount;
    userSummaries[msg.sender].unlocking -= temp_amount;
  }

  ///
  /// @notice User's interest from participate PoS
  /// @param _address The address of user to query
  /// @return CFX interest in Drip
  ///
  function userInterest(address _address) public view returns (uint256) {
    uint256 _interest = userSummaries[_address].currentInterest;

    uint256 _latestAccRewardPerCfx = accRewardPerCfx;
    // add latest profit
    uint256 _latestReward = _selfBalance() - lastPoolShot.balance;
    UserShot memory uShot = lastUserShots[_address];
    if (_latestReward > 0) {
      uint256 _deltaAcc = _latestReward.div(lastPoolShot.available.div(1 ether));
      _latestAccRewardPerCfx = _latestAccRewardPerCfx.add(_deltaAcc);
    }

    if (uShot.available > 0) {
      uint256 _latestInterest = _latestAccRewardPerCfx.sub(uShot.accRewardPerCfx).mul(uShot.available.div(1 ether));
      _interest = _interest.add(_calUserShare(_latestInterest, _address));
    }

    return _interest;
  }

  ///
  /// @notice Claim specific amount user interest
  /// @param amount The amount of interest to claim
  ///
  function claimInterest(uint256 amount) public onlyRegisted {
    uint256 claimableInterest = userInterest(msg.sender);
    require(claimableInterest >= amount, "Interest not enough");

    _updateAccRewardPerCfx();

    _updateUserInterest(msg.sender);
    //
    userSummaries[msg.sender].claimedInterest = userSummaries[msg.sender].claimedInterest.add(amount);
    userSummaries[msg.sender].currentInterest = userSummaries[msg.sender].currentInterest.sub(amount);
    // update userShot's accRewardPerCfx
    _updateUserShot(msg.sender);

    // send interest to user
    address payable receiver = payable(msg.sender);
    receiver.transfer(amount);
    emit ClaimInterest(msg.sender, amount);

    // update blockNumber and balance
    _updatePoolShot();
  }

  ///
  /// @notice Claim one user's all interest
  ///
  function claimAllInterest() public onlyRegisted {
    uint256 claimableInterest = userInterest(msg.sender);
    require(claimableInterest > 0, "No claimable interest");
    claimInterest(claimableInterest);
  }

  //pink claim
  function userPink(address _address) public view returns (uint256) {
    uint256 _pink = userSummaries[_address].currentPink;

    uint256 _latestAccRewardPerCfx = accPinkRewardPerCfx;
    // add latest profit
    uint256 _latestReward = _selfBalancePink() - lastPoolShot.balancePink;
    UserShot memory uShot = lastUserShots[_address];
    if (_latestReward > 0) {
      uint256 _deltaAcc = _latestReward.div(lastPoolShot.available.div(1 ether));
      _latestAccRewardPerCfx = _latestAccRewardPerCfx.add(_deltaAcc);
    }

    if (uShot.available > 0) {
      uint256 _latestInterest = _latestAccRewardPerCfx.sub(uShot.accPinkRewardPerCfx).mul(uShot.available.div(1 ether));
      _pink = _pink.add(_latestInterest);
    }

    return _pink;
  }

  function claimPink(uint256 amount) public onlyRegisted {
    uint256 claimablePink = userPink(msg.sender);
    require(claimablePink >= amount, "Interest not enough");

    _updateAccRewardPerCfx();

    _updateUserInterest(msg.sender);
    //
    userSummaries[msg.sender].claimedPink = userSummaries[msg.sender].claimedPink.add(amount);
    userSummaries[msg.sender].currentPink = userSummaries[msg.sender].currentPink.sub(amount);
    // update userShot's accRewardPerCfx
    _updateUserShot(msg.sender);

    // send interest to user
    IPINK(pinkAddress).transfer(msg.sender, amount);


    // update blockNumber and balance
    _updatePoolShot();
  }

  function claimAllPink() public onlyRegisted {
    uint256 claimablePink = userPink(msg.sender);
    require(claimablePink > 0, "No claimable Pink");
    claimPink(claimablePink);
  }

  //claim all
  function claimAll() public onlyRegisted {
    uint256 claimableInterest = userInterest(msg.sender);
    if (claimableInterest > 0) {
        claimAllInterest();
    }
    
    uint256 claimablePink = userPink(msg.sender);
    if (claimablePink > 0) {
        claimAllPink();
    }
    
  }

  //rebate claim
  function userRebate(address _address) public view returns (uint256) {
    uint256 _rebate = rebateSummaries[_address].current;

    uint256 _latestAccRewardPerCfx = accRewardPerCfx;
    // add latest profit
    uint256 _latestReward = _selfBalance() - lastPoolShot.balance;
    if (_latestReward > 0) {
      uint256 _deltaAcc = _latestReward.div(lastPoolShot.available.div(1 ether));
      _latestAccRewardPerCfx = _latestAccRewardPerCfx.add(_deltaAcc);
    }

    //rebateSummaries
    IInvite invite = IInvite(inviteAddress);
    address[] memory childs = invite.getChilds(_address);
    uint256 len = childs.length;

    for (uint256 i = 0; i < len; i++) {
      UserShot memory uShot = lastUserShots[childs[i]];
      if (uShot.available > 0) {
        uint256 _latestInterest = _latestAccRewardPerCfx.sub(uShot.accRewardPerCfx).mul(uShot.available.div(1 ether));
        uint256 _userInterest = _calUserShare(_latestInterest, childs[i]);
        uint256 rebate = _latestInterest.sub(_userInterest);

        _rebate += rebate;
      }
    }
    
    return _rebate;
  }

  function claimRebate(uint256 amount) public onlyRegisted {
    uint256 claimableRebate = userRebate(msg.sender);
    require(claimableRebate >= amount, "Rebate not enough");

    _updateAccRewardPerCfx();

    //rebateSummaries
    IInvite invite = IInvite(inviteAddress);
    address[] memory childs = invite.getChilds(msg.sender);
    uint256 len = childs.length;

    for (uint256 i = 0; i < len; i++) {
      _updateUserInterest(childs[i]);
      _updateUserShot(childs[i]);
    }

    rebateSummaries[msg.sender].claimed = rebateSummaries[msg.sender].claimed.add(amount);
    rebateSummaries[msg.sender].current = rebateSummaries[msg.sender].current.sub(amount);
    
    // send to user
    address payable receiver = payable(msg.sender);
    receiver.transfer(amount);

    // update blockNumber and balance
    _updatePoolShot();
  }

  function claimAllRebate() public onlyRegisted {
    uint256 claimableRebate = userRebate(msg.sender);
    require(claimableRebate > 0, "No claimable rebate");
    claimRebate(claimableRebate);
  }

  /// 
  /// @notice Get user's pool summary
  /// @param _user The address of user to query
  /// @return User's summary
  ///
  function userSummary(address _user) public view returns (UserSummary memory) {
    UserSummary memory summary = userSummaries[_user];
    uint256 temp_amount =userOutqueues[_user].sumEndedVotes();
    summary.unlocked += temp_amount;
    summary.unlocking -= temp_amount;
    return summary;
  }

  function poolSummary() public view returns (PoolSummary memory) {
    PoolSummary memory summary = _poolSummary;
    uint256 _latestReward = _selfBalance().sub(lastPoolShot.balance);
    summary.totalInterest = summary.totalInterest.add(_latestReward);
    return summary;
  }

  function poolAPY() public view returns (uint256) {
    return _poolAPY;
  }

  function userInQueue(address account) public view returns (VotePowerQueue.QueueNode[] memory) {
    return userInqueues[account].queueItems();
  }

  function userOutQueue(address account) public view returns (VotePowerQueue.QueueNode[] memory) {
    return userOutqueues[account].queueItems();
  }

  function stakerNumber() public view returns (uint) {
    return stakers.length();
  }

  function stakerAddress(uint256 i) public view returns (address) {
    return stakers.at(i);
  }

  function userAirdrop(address account) public view returns (uint256) {
    uint256 available = _poolSummary.available;
    uint256 votePower = userSummaries[account].available;
    return airdrop.mul(votePower).div(available);
  }


  // ======================== admin methods =====================

  ///
  /// @notice Enable admin to set the user share ratio
  /// @dev The ratio base is 10000, only admin can do this
  /// @param ratio The interest user share ratio (1-10000), default is 9000
  ///
  function setPoolUserShareRatio(uint64 ratio) public onlyOwner {
    require(ratio > 0 && ratio <= RATIO_BASE, "ratio should be 1-10000");
    poolUserShareRatio = ratio;
    emit RatioChanged(ratio);
  }
  
  function setDevRatio(uint64 ratio) public onlyOwner {
    require(ratio > 0 && ratio <= RATIO_BASE, "ratio should be 1-10000");
    devRatio = ratio;
  }
  
  function setCommunityRatio(uint64 ratio) public onlyOwner {
    require(ratio > 0 && ratio <= RATIO_BASE, "ratio should be 1-10000");
    communityRatio = ratio;
  }

  /// @notice Enable Owner to set the unlocking period
  /// @notice  fast < slow
  /// @param slow The unlock period in in block number
  /// @param fast The unlock period out in block number
  function _setLockPeriod(uint256 slow,uint256 fast) public onlyOwner {
    require(fast<slow);
    _poolLockPeriod_slow = slow;
    _poolLockPeriod_fast = fast;
  }


  function setBridge(address bridgeAddress) public onlyOwner {
    _bridgeAddress = bridgeAddress;
    birdgeAddrSetted = true;
  }

  function setPoolName(string memory name) public onlyOwner {
    poolName = name;
  }

  function setDevAddress(address devAddress) public onlyOwner {
    _devAddress = devAddress;
  }

  function setCommunityAddress(address communityAddress) public onlyOwner {
    _communityAddress = communityAddress;
  }

  function setInviteAddress(address inviteAddr) public onlyOwner {
    inviteAddress = inviteAddr;
  }

  function setPinkAddress(address addr) public onlyOwner {
    pinkAddress = addr;
  }

  function setAirdrop(uint256 amount) public onlyOwner {
    airdrop = amount;
  }

  function _retireUserStake(address _addr, uint64 endBlockNumber) public onlyOwner {
    uint256 votePower = userSummaries[_addr].available;
    if (votePower == 0) return;

    _updateUserInterest(_addr);
    userSummaries[_addr].available = 0;
    userSummaries[_addr].locked = 0;
    // clear user inqueue
    userInqueues[_addr].clear();
    userOutqueues[_addr].enqueue(VotePowerQueue.QueueNode(votePower, endBlockNumber));
    _updateUserShot(_addr);

    _poolSummary.available -= votePower;
  }

  // When pool node is force retired, use this method to make all user's available stake to unlocking
  function _retireUserStakes(uint256 offset, uint256 limit, uint64 endBlockNumber) public onlyOwner {
    uint256 len = stakers.length();
    if (len == 0) return;

    _updateAccRewardPerCfx();

    uint256 end = offset + limit;
    if (end > len) {
      end = len;
    }
    for (uint256 i = offset; i < end; i++) {
      _retireUserStake(stakers.at(i), endBlockNumber);
    }

    _updatePoolShot();
  }

  // ======================== bridge methods =====================

  function setPoolAPY(uint256 apy) public onlyBridge {
    _poolAPY = apy;
  }

  function handleUnstake() public onlyBridge returns (uint256) {
    uint256 temp_unstake = _unstakeCFXs;
    _unstakeCFXs = 0;
    return temp_unstake;
  }

  function setlockedvotes(uint256 lockedvotes) public onlyBridge returns (uint256){
    _poolSummary.votes = lockedvotes;
    return  _poolSummary.votes;
  }

  function handleUnlockedIncrease() public payable onlyBridge {
    _updatePoolShot();
  }


  // receive interest
  function receiveInterest() public payable onlyBridge {
    uint256 interest = msg.value;
    uint256 devFee = interest.mul(devRatio).div(RATIO_BASE);
    uint256 communityFee = interest.mul(communityRatio).div(RATIO_BASE);

    //dev fee
    address payable receiver = payable(_devAddress);
    receiver.transfer(devFee);
    //community fee
    address payable receiver2 = payable(_communityAddress);
    receiver2.transfer(communityFee);

    //add pink 
    IPINK(pinkAddress).mint();

    _updateAccRewardPerCfx();
    _updatePoolShot();
  }

  function espacebalanceof(address _addr) public view returns(uint256) {
    return _addr.balance;
  }

  fallback() external payable {}
  receive() external payable {}

}