// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../Libraries/SafeBEP20.sol";
import "../Libraries/Math.sol";
import '../Modifiers/Ownable.sol';
import '../Modifiers/ReentrancyGuard.sol';
import "../IGlobalMasterChef.sol";

contract VaultLocked is Ownable, ReentrancyGuard{
    using SafeBEP20 for IBEP20;
    using SafeMath for uint;
    using SafeMath for uint16;

    struct DepositInfo {
        uint pid;
        uint amount;
        uint lockupPeriod;
        uint nextWithdraw;
        uint[] extraRewardsPercents;
    }

    mapping (address=> mapping(uint=>DepositInfo[])) public depositInfo;
    mapping (uint => mapping (address => uint)) public userInfo;

    uint[] public extraRewardsPercents;

    IBEP20 public global;                      // Public vars
    IGlobalMasterChef public globalMasterChef;
    address public vestedVault;                // Public vars

    uint private constant LOCKUPX = 6480000;      //default lockup of 2.5 months
    uint private constant LOCKUPY = 6480000 * 2;  //default lockup of 5 months
    uint private constant LOCKUPZ = 6480000 * 3;  //default lockup of 7.5 months

    mapping(uint=>uint) public totalSupply;

    // Fee to withdraw the locked Lp tokens
    uint private rateOfWithdrawFee = 3000;        // 30%
    
    uint public totalShares;
    mapping (address => uint) public _shares;

    event Deposited(address indexed _user, uint _amount);
    event Withdrawn(address indexed _user, uint _amount);

    // OK
    constructor(
        address _global,
        address _globalMasterChef,
        address _vestedVault
    ) public {
        global = IBEP20(_global);
        globalMasterChef = IGlobalMasterChef(_globalMasterChef);

        vestedVault = _vestedVault;

        extraRewardsPercents.push(1800);   // 18%
        extraRewardsPercents.push(3500);   // 35%
        extraRewardsPercents.push(6700);   // 67%
    }

    // OK
    function balance(uint _pid) public view returns (uint amount) {
        (amount,) = globalMasterChef.userInfo(_pid, address(this));
    }

    // OK
    function balanceOf(address _account, uint _pid) public view returns(uint) {
        if (totalSupply[_pid] == 0) return 0;
        return amountOfUser(_account, _pid);
    }

    // MEMORY REMOVED FROM PARAMETER + onlyowner added + extraRewardsPercents always have values, length > 0 by definition. We remove the 'if' checking this condition
    function setExtraRewardsPercent(uint[] memory values) public onlyOwner{
        require(extraRewardsPercents.length == values.length, 'values are wrong');
        extraRewardsPercents[0] = values[0];
        extraRewardsPercents[1] = values[1];
        extraRewardsPercents[2] = values[2];
    }

    // Deposit LP tokens as user.
    function deposit(uint _pid, uint _amount, uint _lockupPeriod) public nonReentrant {
        require(_lockupPeriod == LOCKUPX || _lockupPeriod == LOCKUPY || _lockupPeriod == LOCKUPZ, 'LockUp period  is wrong');

        uint beforeBalance;
        uint rewards;

        (IBEP20 lpToken, , , , , , , , , ) = globalMasterChef.poolInfo(_pid);    // Simplified

        if (_amount > 0)
        {
            depositInfo[msg.sender][_pid].push(DepositInfo({
            pid: _pid,
            amount: _amount,
            lockupPeriod:_lockupPeriod,
            nextWithdraw: block.timestamp.add(_lockupPeriod),
            extraRewardsPercents: extraRewardsPercents
            }));

            lpToken.safeTransferFrom(msg.sender, address(this), _amount);

            // We check == 0 and do the statement straight away instead of doing it in another 'if'
            // users is not used, we delete it
            totalSupply[_pid] = totalSupply[_pid].add(_amount);
        }

        // Get rewards, recalculate the extra rewards for the user and transfer.
        beforeBalance = global.balanceOf(address(this));
        globalMasterChef.deposit(_pid, _amount);
        rewards = ((global.balanceOf(address(this)).sub(beforeBalance))).mul(_shares[msg.sender]).div(totalShares);

        calculateTotalRewards(_pid, rewards);
        claimRewards(_pid);
        
        // recalculate the user's share and total share.
        if (_amount > 0)
        {
            uint shares = totalShares == 0 ? _amount : (_amount.mul(totalShares)).div(balance(_pid));
            totalShares = totalShares.add(shares);
            _shares[msg.sender] = _shares[msg.sender].add(shares);
        }

        emit Deposited(msg.sender, _amount);
    }

    // Calculate the average weight from the LP token amount deposited and lockup period.
    function calculateAverageWeight(address _user, uint _pid) public view returns (uint)
    {
        DepositInfo[] memory myDeposits =  depositInfo[_user][_pid];

        if (myDeposits.length == 0)
            return 0;

        uint totalValue;
        uint totalCountOfTokens;
        uint percent;

        for(uint i=0; i< myDeposits.length; i++)
        {
            if(myDeposits[i].lockupPeriod  == LOCKUPX)
                percent = myDeposits[i].extraRewardsPercents[0];
            else if (myDeposits[i].lockupPeriod  == LOCKUPY)
                percent = myDeposits[i].extraRewardsPercents[1];
            else
                percent = myDeposits[i].extraRewardsPercents[2];

            totalCountOfTokens = totalCountOfTokens.add(myDeposits[i].amount);
            totalValue = totalValue.add(percent.mul(myDeposits[i].amount));
        }

        return totalValue.div(totalCountOfTokens);
    }

    // Calculate the extra rewards and total rewards.
    function calculateTotalRewards(uint _pid, uint rewards) public {

        uint averageWeight = calculateAverageWeight(msg.sender, _pid);

        uint extraRewards = rewards.mul(averageWeight).div(10000);

        if (extraRewards > 0)
        {
            globalMasterChef.mintNativeTokens(extraRewards, address(this));

            uint totalRewards = rewards.add(extraRewards);

            userInfo[_pid][msg.sender] = userInfo[_pid][msg.sender].add(totalRewards);
        }
    }

    function claimRewards(uint _pid) internal {
        uint totalRewards = userInfo[_pid][msg.sender];

        SafeNativeTokenTransfer(msg.sender, totalRewards);

        userInfo[_pid][msg.sender] = 0;
    }

    // Safe native token transfer function, just in case if rounding error causes pool to not have enough native tokens.
    function SafeNativeTokenTransfer(address _to, uint _amount) internal {
        uint nativeTokenBal = global.balanceOf(address(this));
        if (_amount > nativeTokenBal) {
            global.transfer(_to, nativeTokenBal);
        } else {
            global.transfer(_to, _amount);
        }
    }

    function amountOfUser(address _user, uint _pid) public view returns (uint totalAmount)
    {
        totalAmount = 0;
        DepositInfo[] memory myDeposits =  depositInfo[_user][_pid];
        for(uint i=0; i< myDeposits.length; i++)
        {
            totalAmount=totalAmount.add(myDeposits[i].amount);
        }
    }

    function availableForWithdraw(uint _time, address _user, uint _pid) public view returns (uint totalAmount)
    {
        totalAmount = 0;
        DepositInfo[] memory myDeposits =  depositInfo[_user][_pid];
        for(uint i=0; i< myDeposits.length; i++)
        {
            if(myDeposits[i].nextWithdraw < _time)
            {
                totalAmount=totalAmount.add(myDeposits[i].amount);
            }
        }
    }
    
    function withdraw(uint _pid, uint _amount, bool unlocked) external nonReentrant{

        (IBEP20 lpToken, , , , , , , , , ) = globalMasterChef.poolInfo(_pid);

        uint totalAmount;
        uint beforeBalance;
        uint rewards;

        if (!unlocked)
        {
            totalAmount = availableForWithdraw(block.timestamp, msg.sender, _pid);
            require(_amount <= totalAmount, "Withdraw: you have no enough token to withdraw!");
        }
        else{
            totalAmount = amountOfUser(msg.sender, _pid);

            uint feeAmount = _amount.mul(rateOfWithdrawFee).div(10000);
            _amount = _amount.sub(feeAmount);

            require(_amount <= totalAmount, "Withdraw: you have no enough token to withdraw!");
        }

        // Get rewards, recalculate the extra rewards for the user and transfer.
        beforeBalance = global.balanceOf(address(this));
        globalMasterChef.withdraw(_pid, _amount);
        rewards = ((global.balanceOf(address(this)).sub(beforeBalance))).mul(_shares[msg.sender]).div(totalShares);

        calculateTotalRewards(_pid, rewards);
        claimRewards(_pid);
        
        // Transfer the LP token to the user
        lpToken.safeTransfer(msg.sender, _amount);

        // Remove desosit info in the array
        removeAmountFromDeposits(msg.sender, _pid, _amount, block.timestamp, unlocked);
        removeEmptyDeposits(msg.sender, _pid);

        totalSupply[_pid] = totalSupply[_pid].sub(_amount);
        
        // recalculate the user's share and total share.
        uint shares = Math.min(_amount.mul(totalShares).div(balance(_pid)), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        
        emit Withdrawn(msg.sender, _amount);
    }

    function setWithdrawPayFee(uint _rateFee) public onlyOwner
    {
        require(_rateFee <= 10000, "Withdraw Fee: Fee is too high");

        rateOfWithdrawFee = _rateFee;
    }

    function removeAmountFromDeposits(address _user, uint _pid, uint _amount, uint _time, bool bAll) private
    {
        uint length =  depositInfo[_user][_pid].length;

        for(uint i=0; i< length; i++)
        {
            if (!bAll)
            {
                if(depositInfo[_user][_pid][i].nextWithdraw < _time)
                {
                    if (depositInfo[_user][_pid][i].amount <= _amount)
                    {
                        _amount = _amount.sub(depositInfo[_user][_pid][i].amount);
                        depositInfo[_user][_pid][i].amount = 0;
                    }
                    else
                    {
                        depositInfo[_user][_pid][i].amount = depositInfo[_user][_pid][i].amount.sub(_amount);
                        _amount = 0;
                    }
                }
            }
            else{
                if (depositInfo[_user][_pid][i].amount <= _amount)
                {
                    _amount = _amount.sub(depositInfo[_user][_pid][i].amount);
                    depositInfo[_user][_pid][i].amount = 0;
                }
                else
                {
                    depositInfo[_user][_pid][i].amount = depositInfo[_user][_pid][i].amount.sub(_amount);
                    _amount = 0;
                }
            }

            if (_amount == 0)
                break;
        }
    }

    function removeAvailableDeposits(address user, uint _pid) private
    {
        for (uint i=0; i<depositInfo[user][_pid].length; i++)
        {
            while(depositInfo[user][_pid].length > 0 && depositInfo[user][_pid][i].nextWithdraw < block.timestamp)
            {
                for (uint j = i; j<depositInfo[user][_pid].length-1; j++)
                {
                    depositInfo[user][_pid][j] = depositInfo[user][_pid][j+1];
                }
                depositInfo[user][_pid].pop();
            }
        }
    }

    function removeEmptyDeposits(address user, uint _pid) private
    {
        for (uint i=0; i<depositInfo[user][_pid].length; i++)
        {
            while(depositInfo[user][_pid].length > 0 && depositInfo[user][_pid][i].amount  == 0)
            {
                for (uint j = i; j<depositInfo[user][_pid].length-1; j++)
                {
                    depositInfo[user][_pid][j] = depositInfo[user][_pid][j+1];
                }
                depositInfo[user][_pid].pop();
            }
        }
    }

    function removeAllDeposits(address user, uint _pid) private
    {
        for (uint i=0; i<depositInfo[user][_pid].length; i++)
        {
            depositInfo[user][_pid].pop();
        }
    }

    function _allowance(IBEP20 _token, address _account) private {
        _token.safeApprove(_account, uint(0));
        _token.safeApprove(_account, uint(~0));
    }
}