// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../Libraries/SafeBEP20.sol";
import "../Libraries/Math.sol";
import '../Modifiers/Ownable.sol';
import '../Modifiers/ReentrancyGuard.sol';
import "../IMasterChef.sol";

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
        uint averageWeightTimes;
    }

    struct UserInfo {
        uint accRewards;
        uint nextHarvestUntil;
        bool whitelisted;
        uint withdrawalOrPerformanceFees;
    }

    mapping (address=> mapping(uint=>DepositInfo[])) public depositInfo;
    mapping(uint=>address[]) public users;
    mapping (uint => mapping (address => UserInfo)) public userInfo;
    
    uint[] public extraRewardsPercents;
    uint[] public initialExtraRewardsPercents;
    uint public averageWeightTimes = 15000;     // 150%

    IBEP20 private global;
    IMasterChef private globalMasterChef;
    address private vestedVault;

    uint private constant LOCKUPX = 6480000;      //default lockup of 2.5 months
    uint private constant LOCKUPY = 6480000 * 2;  //default lockup of 5 months
    uint private constant LOCKUPZ = 6480000 * 3;  //default lockup of 7.5 months
    
    mapping(uint=>uint) public totalSupply;
    
    // Fee to withdraw the locked Lp tokens
    uint private rateOfWithdrawFee = 5000;        // 50%

    event Deposited(address indexed _user, uint _amount);
    event Withdrawn(address indexed _user, uint _amount);

    constructor(
        address _global,
        address _globalMasterChef,
        address _vestedVault
    ) public {

        // Li passem el address del masterchef a on es depositaràn els GLOBALs
        // We pass the address of the masterchef to where the GLOBALs will be deposited
        global = IBEP20(_global);
        globalMasterChef = IMasterChef(_globalMasterChef);
        
        vestedVault = _vestedVault;
        
        initialExtraRewardsPercents.push(1800);   // 18%
        initialExtraRewardsPercents.push(3500);   // 35%
        initialExtraRewardsPercents.push(6700);   // 67%
        
        console.log("ddd : ", vestedVault);
        
        // ????????? Cal?????
        _allowance(global, _globalMasterChef);
    }

    function balance(uint _pid) public view returns (uint amount) {
        (amount,) = globalMasterChef.userInfo(_pid, address(this));
    }

    function balanceOf(address _account, uint _pid) public view returns(uint) {
        if (totalSupply[_pid] == 0) return 0;
        return amountOfUser(_account, _pid);
    }
    
    function setExtraRewardsPercent(uint[] memory values) public {
        if (extraRewardsPercents.length == 0)
        {
            for (uint i=0; i<values.length; i++)
            {
                extraRewardsPercents.push(values[i]);
            }
            
            return;
        }
        
        require(extraRewardsPercents.length == values.length, 'values is wrong');
        
        extraRewardsPercents = values;
    }

    // Deposit LP tokens as user.
    function deposit(uint _pid, uint _amount, uint _lockupPeriod, bool sendVestedVault) public nonReentrant {
        require(_lockupPeriod == LOCKUPX || _lockupPeriod == LOCKUPY || _lockupPeriod == LOCKUPZ, 'LockUp period  is wrong');

        bool userExists = false;
        uint beforeBalance;
        uint rewards;

        // check the deposit history of user
        if (depositInfo[msg.sender][_pid].length > 0)
            userExists = true;
            
        // set the innitial percent of extra rewards
        if (extraRewardsPercents.length == 0)
        {
            extraRewardsPercents.push(initialExtraRewardsPercents[0]);   // 18%
            extraRewardsPercents.push(initialExtraRewardsPercents[1]);   // 35%
            extraRewardsPercents.push(initialExtraRewardsPercents[2]);   // 67%
        }
        
        (IBEP20 lpToken, , , , uint harvestInterval, uint maxWithdrawalInterval, , , , ) = 
            IMasterChef(address(globalMasterChef)).poolInfo(_pid);
        
        if (_amount > 0)
        {
            depositInfo[msg.sender][_pid].push(DepositInfo({
                pid: _pid,
                amount: _amount,
                lockupPeriod:_lockupPeriod,
                nextWithdraw: block.timestamp.add(_lockupPeriod),
                extraRewardsPercents: extraRewardsPercents,
                averageWeightTimes: averageWeightTimes
            }));

            // You have to approve the address(this) for the msg.sender before calling this function.
            lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            
            if (!userExists){
                users[_pid].push(msg.sender);
            }
    
            totalSupply[_pid] = totalSupply[_pid].add(_amount);
            
            userInfo[_pid][msg.sender].withdrawalOrPerformanceFees = block.timestamp.add(maxWithdrawalInterval);
        }
        
        if (userInfo[_pid][msg.sender].nextHarvestUntil == 0) {
            userInfo[_pid][msg.sender].nextHarvestUntil = block.timestamp.add(harvestInterval);
        }
        
        beforeBalance = global.balanceOf(address(this));
        
        globalMasterChef.deposit(_pid, _amount);
        
        rewards = global.balanceOf(address(this)).sub(beforeBalance);
        
        calculateAndSendTotalRewards(_pid, rewards, sendVestedVault);

        emit Deposited(msg.sender, _amount);
    }
    
    function setAverageWeightTimes(uint amount) public onlyOwner {
        averageWeightTimes = amount;
    }
    
    function calculateAverageWeight(address _user, uint _pid, bool sendVestedVault) public view returns (uint)
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
                
            if (sendVestedVault)
                percent = percent.mul(myDeposits[i].averageWeightTimes).div(10000);
                
            totalCountOfTokens = totalCountOfTokens.add(myDeposits[i].amount);
            totalValue = totalValue.add(percent.mul(myDeposits[i].amount));
        }
        
        return totalValue.div(totalCountOfTokens);
    }
    
    function calculateAndSendTotalRewards(uint _pid, uint rewards, bool sendVestedVault) public {
        // calculate te average weight and extra rewards.
        uint averageWeight = calculateAverageWeight(msg.sender, _pid, sendVestedVault);
        
        uint extraRewards = rewards.mul(averageWeight).div(10000);
        
        if (extraRewards > 0)
        {
            globalMasterChef.mintNativeTokens(extraRewards, address(this));
            
            uint totalRewards = rewards.add(extraRewards);
            
            if (sendVestedVault)
            {
                SafeNativeTokenTransfer(vestedVault, totalRewards);
            }
            else
            {
                userInfo[_pid][msg.sender].accRewards = userInfo[_pid][msg.sender].accRewards.add(totalRewards);
                
                claimRewards(_pid);
            }
        }
    }
    
    // View function to see if user can harvest.
    // Retornem + si el block.timestamp és superior al block límit de harvest.
    function canHarvest(uint _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil || user.whitelisted;
    }
    
    function setWhitelistedUser(uint _pid, address _user, bool isWhitelisted) external onlyOwner {
        userInfo[_pid][_user].whitelisted = isWhitelisted;
    }
    
    function isWhitelistedUser(uint256 _pid, address _user) view external returns (bool) {
        return userInfo[_pid][_user].whitelisted;
    }
    
    // View function to see what kind of fee will be charged
    // Retornem + si cobrarem performance. False si cobrarem dels LPs.
    function withdrawalOrPerformanceFee(uint _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.withdrawalOrPerformanceFees;
    }
    
    function claimRewards(uint _pid) internal {
        if (!canHarvest(_pid, msg.sender))
            return;
            
        (,,,, uint harvestInterval,,,,
            uint16 performanceFeesOfNativeTokensBurn, uint16 performanceFeesOfNativeTokensToLockedVault) = 
                IMasterChef(address(globalMasterChef)).poolInfo(_pid);
        
        uint totalRewards = userInfo[_pid][msg.sender].accRewards;
        bool performanceFee = withdrawalOrPerformanceFee(_pid, msg.sender);
        
        if (performanceFee && !userInfo[_pid][msg.sender].whitelisted){
            // Fees que cremarem i fees que enviarem per fer boost dels locked. Les acumulem a l'espera d'enviarles quan toquin
            uint totalFeesToBurn = (totalRewards.mul(performanceFeesOfNativeTokensBurn)).div(10000);
            uint totalFeesToBoostLocked = (totalRewards.mul(performanceFeesOfNativeTokensToLockedVault)).div(10000);
            
            totalRewards = totalRewards.sub(totalFeesToBurn.add(totalFeesToBoostLocked));
        
            // Cremem els tokens. Dracarys.
            SafeNativeTokenTransfer(globalMasterChef.BURN_ADDRESS(), totalFeesToBurn);
    
            // Enviem les fees acumulades cap al vault de Global locked per fer boost dels rewards allà
            SafeNativeTokenTransfer(globalMasterChef.nativeTokenLockedVaultAddr(), totalFeesToBoostLocked);
        }
        
        SafeNativeTokenTransfer(msg.sender, totalRewards);
            
        userInfo[_pid][msg.sender].nextHarvestUntil = block.timestamp.add(harvestInterval);
        userInfo[_pid][msg.sender].accRewards = 0;
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

    function withdraw(uint _pid, uint _amount, bool unlocked, bool sendVestedVault) external nonReentrant{

        (IBEP20 lpToken, , , , , , , , , ) = IMasterChef(address(globalMasterChef)).poolInfo(_pid);
        
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
        
        beforeBalance = global.balanceOf(address(this));
        
        globalMasterChef.withdraw(_pid, _amount);
        
        rewards = global.balanceOf(address(this)).sub(beforeBalance);
        
        calculateAndSendTotalRewards(_pid, rewards, sendVestedVault);

        lpToken.safeTransfer(msg.sender, _amount);

        removeAmountFromDeposits(msg.sender, _pid, _amount, block.timestamp, unlocked); 
        removeEmptyDeposits(msg.sender, _pid);
        
        _deleteUser(msg.sender, _pid);
        
        totalSupply[_pid] = totalSupply[_pid].sub(_amount);

        emit Withdrawn(msg.sender, _amount);
    }
    
    function setWithdrawPayFee(uint _rateFee) public onlyOwner
    {
        require(_rateFee <= 10000, "Withdraw Fee: Fee is too high");
        
        rateOfWithdrawFee = _rateFee;
    }

    function _allowance(IBEP20 _token, address _account) private {
        _token.safeApprove(_account, uint(0));
        _token.safeApprove(_account, uint(~0));
    }

    function _deleteUser(address _account, uint _pid) private {
        DepositInfo[] memory myDeposits =  depositInfo[_account][_pid];
            
        for(uint i=0; i< myDeposits.length; i++)
        {
            if (myDeposits[i].amount > 0)
                return;
        }
            
        for (uint i = 0; i < users[_pid].length; i++) {
            if (users[_pid][i] == _account) {
                for (uint j = i; j<users[_pid].length-1; j++)
                {
                    users[_pid][j] = users[_pid][j+1];
                }
                users[_pid].pop();
            }
        }
    }
}