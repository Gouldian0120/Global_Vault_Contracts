// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import './Tokens/IBEP20.sol';

interface IMasterChef {
    function userInfo(uint _pid, address _account) view external returns(uint amount, uint rewardDebt);

    // Staking into CAKE pools (pid = 0)
    function enterStaking(uint256 _amount) external;
    function leaveStaking(uint256 _amount) external;

    // Staking other tokens or LP (pid != 0)
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function mintNativeTokens(uint _quantityToMint, address userFor) external;
    function poolInfo(uint256) external returns(IBEP20, uint256, uint256, uint256, uint256, uint256, uint16, uint16, uint16, uint16);
    function BURN_ADDRESS() external returns (address);
    function nativeTokenLockedVaultAddr() external returns (address);
}