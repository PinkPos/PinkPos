//SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.2;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../ICrossSpaceCall.sol";
import "../IPoSPool.sol";

///  @title CoreBridge is a bridge to connect Conflux POS pools and Exchange rooms 
///  @dev Contract should be deployed in conflux core space;
///  @dev compound the interests
///  @notice Users cann't direct use this contract to participate Conflux PoS stake.
contract CoreBridge is Ownable, Initializable, ReentrancyGuard {
  using SafeMath for uint256;
  CrossSpaceCall internal crossSpaceCall;

  uint256 private CFX_COUNT_OF_ONE_VOTE;
  uint256 private CFX_VALUE_OF_ONE_VOTE;

  address public poolAddress;               //pos pool

  //eSpace address
  address   public posStakeAddress;       //PosStake Address in espace
  address   public bridgeeSpaceAddress;

  uint256 private Unstakebalanceinbridge;             //Unstaked balance

  mapping(address=>bool) private trusted_node_triggers;//     
  // ======================== Struct definitions =========================
  struct PoolSummary {
    uint256 totalInterest;       // PoS pool interests 
    uint256 CFXbalances;         // CFX balances in bridge
    uint256 historical_Interest ;// total historical interest of whole pools
  }

  // ============================ Modifiers ===============================

  modifier Only_trusted_triggers() {
    require(trusted_node_triggers[msg.sender],"triggers must be trusted");
    _;
  }
    // ======================== Events ==============================

  event SetPoolAddress(address indexed user, address poolAddress);
  event SetPosStakeAddress(address indexed user, address posStakeAddr);
  event Settrustedtriggers(address indexed user, address triggersAddress,bool state);
  event SetCfxCountOfOneVote(address indexed user, uint256 count);


  // ================== Methods for core pos pools settings ===============
  /// @notice Call this method when deploy the 1967 proxy contract
  function initialize() public initializer{
    crossSpaceCall = CrossSpaceCall(0x0888000000000000000000000000000000000006);
    CFX_COUNT_OF_ONE_VOTE = 1000;
    CFX_VALUE_OF_ONE_VOTE = 1000 ether;
  }


  /// @notice set POS Pool Address
  /// @notice Only used by Owner
  /// @param poolAddr The address of POS Pool to be set
  function setPoolAddress(address poolAddr) public onlyOwner {
    require(poolAddr!=address(0x0000000000000000000000000000000000000000),"Can not be Zero adress");
    poolAddress = poolAddr;
    emit SetPoolAddress(msg.sender, poolAddr);
  }
  
  
  /// @notice Set eSpace contract Address
  /// @notice Only used by Owner
  /// @param posStakeAddr The address of contract, espace address 
  function setPosStakeAddress(address posStakeAddr) public onlyOwner {
    require(posStakeAddr!=address(0x0000000000000000000000000000000000000000),"Can not be Zero adress");
    posStakeAddress = posStakeAddr;
    emit SetPosStakeAddress(msg.sender, posStakeAddr);
  }

  function setBridgeeSpaceAddress(address addr) public onlyOwner {
    require(addr!=address(0x0000000000000000000000000000000000000000),"Can not be Zero adress");
    bridgeeSpaceAddress = addr;
  }
  
  /// @notice Set trustedtriggers Address
  /// @notice Only used by Owner
  /// @param triggersAddress The address of Service treasury contract, nomal address 
  /// @param state True or False
  function setTrustedTriggers(address triggersAddress,bool state) public onlyOwner {
    require(triggersAddress!=address(0x0000000000000000000000000000000000000000),"Can not be Zero adress");
    trusted_node_triggers[triggersAddress] = state;
    emit Settrustedtriggers(msg.sender, triggersAddress, state);
  }
  /// @notice Set Cfx Count Of One Vote
  /// @notice Only used by Owner
  /// @param count Vote cfx count, unit is cfx
  function setCfxCountOfOneVote(uint256 count) public onlyOwner {
    CFX_COUNT_OF_ONE_VOTE = count;
    CFX_VALUE_OF_ONE_VOTE = count * 1 ether;
    emit SetCfxCountOfOneVote(msg.sender, CFX_COUNT_OF_ONE_VOTE);
  }
  
  /// @notice Get trigger state
  /// @param _Address the trigger address to be query
  function getTriggerState(address _Address) public view returns(bool){
    return trusted_node_triggers[_Address];
  }
  /// @notice Get Pool Address array
  function getPoolAddress() public view returns (address) {
    return poolAddress;
  }

  //---------------------bridge method-------------------------------------
  /// @notice sync is triggered regularly by trigger
  /// @notice Only used by trusted trigger
  /// @return infos all needed infos, uint256[7]
  function syncJobs() public Only_trusted_triggers returns(uint256[7] memory infos){
    syncAPY();
    infos[0] = claimInterests();
    (infos[1]) = crossStake();
    (infos[2],infos[3]) = handleUnstake();
    infos[4] = handleLockedvotes();
    (infos[5],infos[6]) = withdrawVotes();
    return infos;
  }

  function syncAPY() public {
    IPoSPool posPool = IPoSPool(poolAddress);
    uint256 apy = posPool.poolAPY();
    crossSpaceCall.callEVM(bytes20(posStakeAddress), abi.encodeWithSignature("setPoolAPY(uint256)", apy));
  }

  /// @notice Used to claim POS pool interests
  /// @notice Only used by trusted trigger
  /// @return systemCFXInterestsTemp The interests need be distribute to system now
  function claimInterests() internal Only_trusted_triggers returns(uint256){
    IPoSPool posPool = IPoSPool(poolAddress);
    uint256 interest =  posPool.temp_Interest();
    if(interest > 0) {
      posPool.claimAllInterest();
      crossSpaceCall.callEVM{value: interest}(bytes20(posStakeAddress), abi.encodeWithSignature("receiveInterest()"));
    }
    return interest;
  }
  /// @notice crossStake
  /// @notice Only used by trusted trigger
  /// @return votePower all of the votePower added this time
  function crossStake() internal Only_trusted_triggers  returns(uint256){
    
    uint256 mappedBalance = crossSpaceCall.mappedBalance(address(this));

    if(mappedBalance > 0){
      crossSpaceCall.withdrawFromMapped(mappedBalance);
    }
    uint64 votePower = uint64(address(this).balance.div(CFX_VALUE_OF_ONE_VOTE));
    if (votePower > 0){
      IPoSPool(poolAddress).increaseStake{value: votePower*CFX_VALUE_OF_ONE_VOTE}(votePower);
    }
    return (votePower);
  }
  /// @notice Used to handle Unstake CFXs
  /// @notice Only used by trusted trigger
  /// @return available poolSummary.totalvotes
  /// @return Unstakebalanceinbridge a para to balance unstake votes and CFXs
  function handleUnstake() internal Only_trusted_triggers nonReentrant returns(uint256,uint256){
    IPoSPool posPool = IPoSPool(poolAddress);
    IPoSPool.PoolSummary memory poolSummary = posPool.poolSummary();
    uint256 available = poolSummary.totalvotes;
    if (available == 0) return (0,Unstakebalanceinbridge);

    bytes memory rawUnstakeCFXs ;
    uint256 receivedUnstakeCFXs;
    rawUnstakeCFXs = crossSpaceCall.callEVM(bytes20(posStakeAddress), abi.encodeWithSignature("handleUnstake()"));
    receivedUnstakeCFXs = abi.decode(rawUnstakeCFXs, (uint256));
    if (receivedUnstakeCFXs == 0) return (0,0);
    require(receivedUnstakeCFXs <= available.mul(CFX_VALUE_OF_ONE_VOTE),"handleUnstake error, receivedUnstakeCFXs > availableCFX in POS");
    Unstakebalanceinbridge += receivedUnstakeCFXs;
    uint256 unstakeSubVotes;
    if(Unstakebalanceinbridge > CFX_VALUE_OF_ONE_VOTE){
      available -= Unstakebalanceinbridge.div(CFX_VALUE_OF_ONE_VOTE);
      unstakeSubVotes = Unstakebalanceinbridge.div(CFX_VALUE_OF_ONE_VOTE);
      Unstakebalanceinbridge -= unstakeSubVotes.mul(CFX_VALUE_OF_ONE_VOTE);
      posPool.decreaseStake(uint64(unstakeSubVotes));
    }

    return (available,Unstakebalanceinbridge);
  }
  /// @notice Used to handle Locked votes
  /// @notice Only used by trusted trigger
  /// @return poolLockedvotes current POS pool locked votes
  function handleLockedvotes() internal Only_trusted_triggers  returns(uint256){
    uint256 poolLockedvotes = IPoSPool(poolAddress).poolSummary().locked;
    
    crossSpaceCall.callEVM(bytes20(posStakeAddress), abi.encodeWithSignature("setlockedvotes(uint256)", poolLockedvotes));
    return poolLockedvotes;
  }
  
  /// @notice Used to withdraw Votes to eSpace stake, Convenient for users to extract
  /// @notice Only used by trusted trigger
  /// @return temp_unlocked temp_unlocked in POS pool
  /// @return transferValue Values transfer to stake
  function withdrawVotes() internal Only_trusted_triggers returns(uint256,uint256){
    IPoSPool posPool = IPoSPool(poolAddress);
    uint256 temp_unlocked;
    uint256 transferValue;

    posPool.collectStateFinishedVotes();
    IPoSPool.PoolSummary memory poolSummary = posPool.poolSummary();
    temp_unlocked = poolSummary.unlocked;
    if (temp_unlocked > 0) 
    {
      posPool.withdrawStake();
      // transfer to eSpacePool and call method
      transferValue = temp_unlocked * 1000 ether;
      //crossSpaceCall.transferEVM{value: transferValue}(bytes20(posStakeAddress));
      crossSpaceCall.callEVM{value: transferValue}(bytes20(posStakeAddress), abi.encodeWithSignature("handleUnlockedIncrease()"));
    }
    
    return (temp_unlocked,transferValue);
  }


  fallback() external payable {}
  receive() external payable {}
  
}