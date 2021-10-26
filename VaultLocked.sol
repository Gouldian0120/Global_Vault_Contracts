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
    
    mapping(uint=>uint[]) public extraRewardsPercents;

    IBEP20 private global;
    IMasterChef private globalMasterChef;
    address vestedVault;

    uint public constant LOCKUPX = 6480000;      //default lockup of 2.5 months
    uint public constant LOCKUPY = 6480000 * 2;  //default lockup of 5 months
    uint public constant LOCKUPZ = 6480000 * 3;  //default lockup of 7.5 months
    
    uint public totalSupply;
    
    // Total de fees pendents d'enviar a cremar
    uint totalFeesToBurn = 0;
    
    // Total de fees pendens d'enviar al vaul de native token locked.
    uint totalFeesToBoostLocked = 0;
    
    // Fee to withdraw the locked Lp tokens
    uint rateOfWithdrawFee = 5000;        // 50%

    event Deposited(address indexed _user, uint _amount);
    event Withdrawn(address indexed _user, uint _amount);

    constructor(
        address _globalMasterChef,
        address _vestedVault
    ) public {

        // Li passem el address del masterchef a on es depositaràn els GLOBALs
        // We pass the address of the masterchef to where the GLOBALs will be deposited
        globalMasterChef = IMasterChef(_globalMasterChef);
        
        vestedVault = _vestedVault;

        // ????????? Cal?????
        _allowance(global, _globalMasterChef);
    }

    function balance(uint _pid) public view returns (uint amount) {
        (amount,) = globalMasterChef.userInfo(_pid, address(this));
    }

    function balanceOf(address _account, uint _pid) public view returns(uint) {
        if (totalSupply == 0) return 0;
        return amountOfUser(_account, _pid);
    }
    
    function setExtraRewardsPercent(uint _pid, uint[] memory values) external {
        require(extraRewardsPercents[_pid].length == values.length, 'values is wrong');
        extraRewardsPercents[_pid] = values;
    }

    // Deposit LP tokens as user.
    function deposit(uint _pid, uint _amount, uint _lockupPeriod, bool sendVestedVault) public nonReentrant {
        require(_lockupPeriod == LOCKUPX || _lockupPeriod == LOCKUPY || _lockupPeriod == LOCKUPZ, 'LockUp period  is wrong');

        bool userExists = false;
        
        uint beforeBalance;
        uint rewards;

        // check the deposit history of user
        if (depositInfo[msg.sender][_pid].length == 0)
            userExists = false;
            
        // set the innitial percent of extra rewards
        if (extraRewardsPercents[_pid].length == 0)
        {
            extraRewardsPercents[_pid][0] = 1800;   // 18%
            extraRewardsPercents[_pid][1] = 3500;   // 35%
            extraRewardsPercents[_pid][2] = 6700;   // 67%
        }
        
       if (_amount > 0)
        {
            depositInfo[msg.sender][_pid].push(DepositInfo({
                pid: _pid,
                amount: _amount,
                lockupPeriod:_lockupPeriod,
                nextWithdraw: block.timestamp.add(_lockupPeriod)
            }));
        
            (IBEP20 lpToken, , , , , , , , , ) = IMasterChef(address(globalMasterChef)).poolInfo(_pid);

            lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            
            if (!userExists){
                users[_pid].push(msg.sender);
            }
    
            totalSupply = totalSupply.add(_amount);
        }
        
        beforeBalance = global.balanceOf(address(this));
        
        globalMasterChef.deposit(_pid, _amount);
        
        rewards = global.balanceOf(address(this)).sub(beforeBalance);
        
        calculateTotalRewards(_pid, rewards, sendVestedVault);

        emit Deposited(msg.sender, _amount);
    }
    
    function calculateTotalRewards(uint _pid, uint rewards, bool sendVestedVault) private {
        
        // calculate te average weight and extra rewards.
        uint averageWeight = calculateAverageWeight(msg.sender, _pid);
        
        if (sendVestedVault)
            averageWeight = averageWeight.mul(3).div(2);
        
        uint extraRewards = rewards.mul(averageWeight).div(10000);
        
        if (extraRewards > 0)
        {
            globalMasterChef.mintNativeTokens(extraRewards, address(this));
            
            uint totalRewards = rewards.add(extraRewards);
            
            if (sendVestedVault)
                global.safeTransferFrom(address(this), vestedVault, totalRewards);
            else
                userInfo[_pid][msg.sender].accRewards = userInfo[_pid][msg.sender].accRewards.add(totalRewards);
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
    
    // View function to see what kind of fee will be charged
    // Retornem + si cobrarem performance. False si cobrarem dels LPs.
    function withdrawalOrPerformanceFee(uint _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.withdrawalOrPerformanceFees;
    }
    
    function claimRewards(uint _pid, uint _amount) public {
        require(userInfo[_pid][msg.sender].accRewards >=  _amount, 'balance is small');
        
        if (!canHarvest(_pid, msg.sender))
            return;
            
        (,,,, uint harvestInterval,uint maxWithdrawalInterval,,,
        uint16 performanceFeesOfNativeTokensBurn, uint16 performanceFeesOfNativeTokensToLockedVault) = 
        IMasterChef(address(globalMasterChef)).poolInfo(_pid);
        
        uint totalRewards = _amount;
        bool performanceFee = withdrawalOrPerformanceFee(_pid, msg.sender);
        
        if (performanceFee && !userInfo[_pid][msg.sender].whitelisted){
            totalRewards = totalRewards.sub(totalRewards.mul(performanceFeesOfNativeTokensBurn.add(performanceFeesOfNativeTokensToLockedVault)).div(10000));
        
            // Fees que cremarem i fees que enviarem per fer boost dels locked. Les acumulem a l'espera d'enviarles quan toquin
            totalFeesToBurn = totalFeesToBurn.add(totalRewards.mul(performanceFeesOfNativeTokensBurn.div(10000)));
            totalFeesToBoostLocked = totalFeesToBoostLocked.add(totalRewards.mul(performanceFeesOfNativeTokensToLockedVault.div(10000)));
        
            // Cremem els tokens. Dracarys.
            SafeNativeTokenTransfer(globalMasterChef.BURN_ADDRESS(), totalFeesToBurn);
            // Reiniciem el comptador de fees. Ho podem fer així i no cal l'increment de k com al AMM perque tota la info està al contracte
            totalFeesToBurn = 0;
    
            // Enviem les fees acumulades cap al vault de Global locked per fer boost dels rewards allà
            SafeNativeTokenTransfer(globalMasterChef.nativeTokenLockedVaultAddr(), totalFeesToBoostLocked);
    
            // Reiniciem el comptador de fees. Ho podem fer així i no cal l'increment de k com al AMM perque tota la info està al contracte
            totalFeesToBoostLocked = 0;
        }
        
        global.safeTransferFrom(address(this), msg.sender, totalRewards);
            
        userInfo[_pid][msg.sender].nextHarvestUntil = block.timestamp.add(harvestInterval);
        userInfo[_pid][msg.sender].withdrawalOrPerformanceFees = block.timestamp.add(maxWithdrawalInterval);
        userInfo[_pid][msg.sender].accRewards = userInfo[_pid][msg.sender].accRewards.sub(totalRewards);
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

    function removeAmountFromDeposits(address _user, uint _pid, uint _amount, uint _time, bool bAll) private view
    {
        DepositInfo[] memory myDeposits =  depositInfo[_user][_pid];
        for(uint i=0; i< myDeposits.length; i++)
        {
            if (!bAll)
            {
                if(myDeposits[i].nextWithdraw < _time)
                {
                    if (myDeposits[i].amount <= _amount)
                    {
                        myDeposits[i].amount = 0;
                        _amount = _amount.sub(myDeposits[i].amount);
                    }
                    else
                    {
                        myDeposits[i].amount = myDeposits[i].amount.sub(_amount);
                        _amount = 0;
                    }
                }
            }
            else{
                if (myDeposits[i].amount <= _amount)
                {
                    myDeposits[i].amount = 0;
                    _amount = _amount.sub(myDeposits[i].amount);
                }
                else
                {
                   myDeposits[i].amount = myDeposits[i].amount.sub(_amount);
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
    
    function calculateAverageWeight(address _user, uint _pid) public view returns (uint)
    {
        DepositInfo[] memory myDeposits =  depositInfo[_user][_pid];
            
        uint totalValue;
        uint totalCountOfTokens;
        uint percent;
        for(uint i=0; i< myDeposits.length; i++)
        {
            if(myDeposits[i].lockupPeriod  == LOCKUPX)
                percent = extraRewardsPercents[_pid][0];
            else if (myDeposits[i].lockupPeriod  == LOCKUPY)
                percent = extraRewardsPercents[_pid][1];
            else
                percent = extraRewardsPercents[_pid][2];
                
            totalCountOfTokens = totalCountOfTokens.add(myDeposits[i].amount);
            totalValue = totalValue.add(percent.mul(myDeposits[i].amount));
        }
        
        return totalValue.div(totalCountOfTokens);
    }

    function withdraw(uint _pid, uint _amount, bool unlocked) external nonReentrant{

        (IBEP20 lpToken, , , , , , , , , ) = IMasterChef(address(globalMasterChef)).poolInfo(_pid);
        uint totalAmount;
        
        if (!unlocked)
        {
            totalAmount = availableForWithdraw(block.timestamp, msg.sender, _pid);
    
            require(_amount <= totalAmount, "VaultLocked: you have no enough token to withdraw!");
    
            globalMasterChef.withdraw(_pid, _amount);
            
            lpToken.safeTransferFrom(address(this), msg.sender, _amount);
    
            removeAmountFromDeposits(msg.sender, _pid, _amount, block.timestamp, false);
            
            if (_amount == totalAmount)
            {
                removeAvailableDeposits(msg.sender, _pid);
    
                _deleteUser(msg.sender, _pid);
            }
        }
        else{
            totalAmount = amountOfUser(msg.sender, _pid);
            require(_amount <= totalAmount, "Withdraw: Amount is too high");
            
            uint feeAmount = _amount.mul(rateOfWithdrawFee).div(10000);
            _amount = _amount.sub(feeAmount);
            
            globalMasterChef.withdraw(_pid, _amount);
    
            lpToken.safeTransferFrom(address(this), msg.sender, _amount);
    
            removeAmountFromDeposits(msg.sender, _pid, _amount, block.timestamp, true);  
            
            if (_amount == totalAmount)
            {
                removeEmptyDeposits(msg.sender, _pid);
    
                _deleteUser(msg.sender, _pid);
            }
        }
        
        totalSupply = totalSupply.sub(_amount);

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