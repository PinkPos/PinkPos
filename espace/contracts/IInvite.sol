// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
 
interface IInvite {
    function addRecord(address) external returns(bool);
    function getParents(address) external view returns(address);
    function getChilds(address) external view returns(address[] memory);
    function getInviteNum(address) external view returns(uint256);
}