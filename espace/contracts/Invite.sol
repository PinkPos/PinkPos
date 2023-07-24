// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
 
import "./IInvite.sol"; // 注意路径，我把所有的接口合约都放在了interfaces目录下
 
contract Invite is IInvite {
    address public factory; // 记录合约发布者地址
    mapping(address => address[]) public inviteRecords; // 邀请记录  邀请人地址 => 被邀请人地址数组
    mapping(address => address) public parents; // 记录上级  我的地址 => 我的上级地址
    mapping(address => uint256) public inviteNumRecords; // 记录邀请数量  我的地址 => [邀请的一级用户数量]
    address public firstAddress; // 合约发布时需要初始化第一个用户地址，否则无法往下绑定用户
    uint256 public totalPeople;
 
    constructor() {
        factory = msg.sender; // 记录合约发布人地址
        firstAddress = msg.sender;
    }
 
    // 绑定上级。在Dapp中的合适位置，让用户点击按钮或者自动弹出授权，要求绑定一个上级（绑定前要做是否已经绑定上级的验证）
    function addRecord(address parentAddress) external override returns(bool){
        require(parentAddress != address(0), "Invite: 0001"); // 不允许上级地址为0地址
        address myAddress = msg.sender; // 重新赋个值，没什么实际意义，单纯为了看着舒服
        require(parentAddress != myAddress, "Invite: 0002");// 不允许自己的上级是自己
        // 验证要绑定的上级是否有上级，只有有上级的用户，才能被绑定为上级（firstAddress除外）。如果没有此验证，那么就可以随意拿一个地址绑定成上级了
        //require(parents[parentAddress] != address(0) || parentAddress == firstAddress, "Invite: 0003");
        // 判断是否已经绑定过上级
        if(parents[myAddress] != address(0)){
            // 已有上级，返回一个true
            return true;
        }
        // 记录邀请关系，parentAddress邀请了myAddress，给parentAddress对应的数组增加一个记录
        inviteRecords[parentAddress].push(myAddress);
        // 记录我的上级
        parents[myAddress] = parentAddress;
        // 统计数量
        inviteNumRecords[parentAddress]++;// parentAddress的一级邀请数+1
        totalPeople++; // 总用户数+1
        return true;
    }

    function isBind(address myAddress) external view override returns(bool){
        if(parents[myAddress] != address(0)){
            // 已有上级，返回一个true
            return true;
        }
        return false;
    }    
 
    // 获取指定用户的两个上级地址，其他合约可以调用此接口，进行分佣等操作
    function getParents(address myAddress) external view override returns(address){
        // 获取直接上级
        address firstParent = parents[myAddress];
        if (firstParent != address(0)) {
            return firstParent;
        } else {
            return firstAddress;
        }
    }
 
    // 获取我的全部一级下级。如果想获取多层，遍历就可以（考虑过预排序遍历树快速获取全部下级，发现难度比较大，如果有更好的方法，欢迎指点）
    function getChilds(address myAddress) external view override returns(address[] memory childs){
        childs = inviteRecords[myAddress];
    }
 
    // 我的邀请数量。其他合约可以调用此接口，进行统计分佣等其他操作
    function getInviteNum(address myAddress) external view override returns(uint256){
        // 返回我的直接邀请数量和二级邀请数量
        return inviteNumRecords[myAddress];
    }
 
    // 修改第一个用户地址，这个接口可有可无，不重要，看自己的需求
    function setFirstAddress(address _firstAddress) external virtual returns(bool){
        require(msg.sender == factory, "Invite: 0009"); // 只有合约发布者能修改
        firstAddress = _firstAddress;
        return true;
    }
}