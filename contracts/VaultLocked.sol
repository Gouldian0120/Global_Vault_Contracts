// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../Libraries/SafeBEP20.sol";
import "../Libraries/Math.sol";
import '../Modifiers/Ownable.sol';
import '../Modifiers/ReentrancyGuard.sol';
import "../Modifiers/DepositoryRestriction.sol";
import "../Modifiers/RewarderRestriction.sol";
import "../IGlobalMasterChef.sol";
import "./Interfaces/IDistributable.sol";

contract VaultLocked is IDistributable, Ownable, ReentrancyGuard, DepositoryRestriction, RewarderRestriction {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint;
    using SafeMath for uint16;

    struct DepositInfo {
        uint pid;
        uint amount;
        uint256 nextWithdraw;
    }

    mapping (address=> mapping(uint=>DepositInfo[]) public depositInfo;
    mapping(uiint=>address[]) public users;

    IBEP20 private global;
    IBEP20 private bnb;
    IGlobalMasterChef private globalMasterChef;

    uint public constant DUST = 1000;
    uint256 public constant LOCKUPX = 2592000; //default lockup of 30 days
    uint256 public constant LOCKUPY = 2592000 * 2; //default lockup of 60 days
    uint256 public constant LOCKUPZ = 2592000 * 3; //default lockup of 90 days

    uint256 public pid;
    uint public minTokenAmountToDistribute;
    uint public minGlobalAmountToDistribute;
    mapping (address => mapping(uint =>uint)) private bnbEarned;
    mapping (address => mapping(uint =>uint)) private globalEarned;
    uint public totalSupply;
    uint256 public lastRewardEvent;
    uint256 public rewardInterval;
    uint private bnbBalance;
    uint private globalBalance;

    event RewardsDeposited(address indexed _account, uint _amount);
    event Deposited(address indexed _user, uint _amount);
    event Withdrawn(address indexed _user, uint _amount);
    event RewardPaid(address indexed _user, uint _amount, uint _amount2);
    event DistributedGLOBAL(uint GLOBALAmount);

    constructor(
        address _global,
        address _bnb,
        address _globalMasterChef,
        uint256 _rewardInterval
    ) public {
        // Pid del vault.
        pid = 0;

        // Li passem el address de global
        // We pass the global address to him
        global = IBEP20(_global);

        // Li passem el address de bnb
        // We pass the bnb address to him
        bnb = IBEP20(_bnb);

        // Li passem el address del masterchef a on es depositaràn els GLOBALs
        // We pass the address of the masterchef to where the GLOBALs will be deposited
        globalMasterChef = IGlobalMasterChef(_globalMasterChef);

        // Es repartirà 1bnb com a mínim. En cas contrari, no repartirem.
        // At least 1bnb will be distributed. Otherwise, we will not deliver.
        minTokenAmountToDistribute = 1e18; // 1 BEP20 Token
        minGlobalAmountToDistribute = 100e18; // 1 BEP20 Token

        bnbBalance = 0;
        globalBalance = 0;

        // ????????? Cal?????
        _allowance(global, _globalMasterChef);

        rewardInterval = _rewardInterval;

        lastRewardEvent = block.timestamp;
    }

    function setRewardInterval(uint256 _rewardInterval) external onlyOwner {
        rewardInterval = _rewardInterval;
    }

    function setMinTokenAmountToDistribute(uint _newAmount) external onlyOwner {
        require(_newAmount >= 0, "Min token amount to distribute must be greater than 0");
        minTokenAmountToDistribute = _newAmount;
    }

    function setMinGlobalAmountToDistribute(uint _minGlobalAmountToDistribute) external onlyOwner {
        minGlobalAmountToDistribute = _minGlobalAmountToDistribute;
    }

    function triggerDistribute(uint _amount) external nonReentrant onlyRewarders override {
        bnbBalance = bnbBalance.add(_amount);

        _distributeBNB();
    }

    function balance() public view returns (uint amount) {
        (amount,) = globalMasterChef.userInfo(pid, address(this));
    }

    function balanceOf(address _account) public view returns(uint) {
        if (totalSupply == 0) return 0;
        return amountOfUser(_account);
    }

    function bnbToEarn(address _account, uint _pid) public view returns (uint) {
        if (amountOfUser(_account, _pid) > 0) {
            return bnbEarned[_account][_pid];
        } else {
            return 0;
        }
    }

    function globalToEarn(address _account, uint _pid) public view returns (uint) {
        if (amountOfUser(_account, _pid) > 0) {
            return globalEarned[_account][_pid];
        } else {
            return 0;
        }
    }

    function stakingToken() external view returns (address) {
        return address(global);
    }

    function rewardsToken() external view returns (address) {
        return address(bnb);
    }

    // Deposit globals as user.
    function deposit(uint256 _pid, uint _amount, uint lockupPeriod) public nonReentrant {
        require(lockupPeriod == LOCKUPX || lockupPeriod == LOCKUPY || lockupPeriod == LOCKUPZ, 'LockUp time is wrong');

        bool userExists = false;

//      global.safeTransferFrom(msg.sender, address(this), _amount);

        if (depositInfo[msg.sender].length == 0)
            userExists = false;

        depositInfo[msg.sender].push(DepositInfo({
            pid: _pid,
            amount: _amount,
            nextWithdraw: block.timestamp.add(LOCKUP)
        }));

        globalMasterChef.enterStaking(_pid, _amount, msg.sender);

/*
        for (uint j = 0; j < users[_pid].length; j++) {
            if (users[_pid][j] == msg.sender)
            {
                userExists = true;
                break;
            }
        }
*/
        if (!userExists){
            users[_pid].push(msg.sender);
        }

        totalSupply = totalSupply.add(_amount);

        if (bnbToEarn(msg.sender, _pid) == 0) {
            bnbEarned[msg.sender][_pid] = 0;
        }

        if (globalToEarn(msg.sender, _pid) == 0) {
            globalEarned[msg.sender][_pid] = 0;
        }

        emit Deposited(msg.sender, _amount);
    }

    // Globals coming from vault vested (as depository)
    function depositRewards(uint _amount) public onlyDepositories {
        global.safeTransferFrom(msg.sender, address(this), _amount);
        globalBalance = globalBalance.add(_amount);

        _distributeGLOBAL();

        emit RewardsDeposited(msg.sender, _amount);
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

    function availableForWithdraw(uint256 _time, address _user, uint _pid) public view returns (uint totalAmount)
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

    function removeAmountFromDeposits(address _user, uint _pid, uint256 _amount, uint256 _time) private
    {
        totalAmount = 0;

        DepositInfo[] memory myDeposits =  depositInfo[_user][_pid];
        for(uint i=0; i< myDeposits.length; i++)
        {
            if(myDeposits[i].nextWithdraw < _time)
            {
                if (myDeposits[i].amount <= _amount)
                {
                    myDeposits[i].amount = 0;
                    _amount -= myDeposits[i].amount;
                }
                else
                {
                    myDeposits[i].amount -= _amount;
                    _amount = 0;
                }
            }

            if (_amount == 0)
                break;
        }
    }

    function removeAvailableDeposits(address user, uint _pid) private
    {
        uint256 now = block.timestamp;

        while(depositInfo[user][_pid].length > 0 && depositInfo[user][_pid][0].nextWithdraw<now)
        {
            for (uint i = 0; i<depositInfo[user][_pid].length-1; i++)
            {
                depositInfo[user][_pid][i] = depositInfo[user][[_pid]i+1];
            }
            depositInfo[user][_pid].pop();
        }
    }

    // Withdraw all only
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant{

        uint totalAmount = availableForWithdraw(block.timestamp, msg.sender, _pid);

        require(_amount <= totalAmount, "VaultLocked: you have no enough token to withdraw!");

        uint earnedBNB = bnbToEarn(msg.sender, _pid);
        uint earnedGLOBAL = globalToEarn(msg.sender, _pid);

        globalMasterChef.withdraw(_pid, _amount);
        removeAmountFromDeposits(msg.sender, _pid, _amount, block.timestamp);

        global.safeTransfer(msg.sender, amount);

        handleRewards(earnedBNB, earnedGLOBAL);
        totalSupply = totalSupply.sub(amount);

        if (_amount == totalAmount)
        {
            removeAvailableDeposits(msg.sender, _pid);

            _deleteUser(msg.sender);

            delete bnbEarned[msg.sender][_pid];
            delete globalEarned[msg.sender][_pid];
        }

        emit Withdrawn(msg.sender, amount);
    }

    function getReward(uint _pid) external nonReentrant {
        uint earnedBNB = bnbToEarn(msg.sender, _pid);
        uint earnedGLOBAL = globalToEarn(msg.sender, _pid);
        handleRewards(earnedBNB, earnedGLOBAL);
        delete bnbEarned[msg.sender][_pid];
        delete globalEarned[msg.sender][_pid];
    }

    function handleRewards(uint _earnedBNB, uint _earnedGLOBAL) private {
        if (_earnedBNB > DUST) {
            bnb.safeTransfer(msg.sender, _earnedBNB);
        } else {
            _earnedBNB = 0;
        }

        if (_earnedGLOBAL > DUST) {
            global.safeTransfer(msg.sender, _earnedGLOBAL);
        } else {
            _earnedGLOBAL = 0;
        }

        emit RewardPaid(msg.sender, _earnedBNB, _earnedGLOBAL);
    }

    function _allowance(IBEP20 _token, address _account) private {
        _token.safeApprove(_account, uint(0));
        _token.safeApprove(_account, uint(~0));
    }

    function _deleteUser(address _account, uint _pid) private {
        for (uint8 i = 0; i < users[_pid].length; i++) {
            if (users[_pid][i] == _account) {
                delete users[_pid][i];
            }
        }
    }

    function _distributeBNB(uint _pid) private {
        uint bnbAmountToDistribute = bnbBalance;

        if (bnbAmountToDistribute < minTokenAmountToDistribute) {
            // Nothing to distribute.
            return;
        }

        for (uint i=0; i < users[_pid].length; i++) {
            uint userPercentage = amountOfUser(users[_pid][i]).mul(100).div(totalSupply);
            uint bnbToUser = bnbAmountToDistribute.mul(userPercentage).div(100);
            bnbBalance = bnbBalance.sub(bnbToUser);

            bnbEarned[users[_pid][i]] = bnbEarned[users[_pid][i]].add(bnbToUser);
        }

        emit Distributed(bnbAmountToDistribute.sub(bnbBalance));
    }

    function _distributeGLOBAL(uint _pid) private {
        uint globalAmountToDistribute = globalBalance;
        if(lastRewardEvent.add(rewardInterval)<=block.timestamp && globalAmountToDistribute >= minGlobalAmountToDistribute)
        {
            lastRewardEvent = block.timestamp;
            for (uint i=0; i < users[_pid].length; i++) {
                uint userPercentage = amountOfUser(users[_pid][i]).mul(100).div(totalSupply);
                uint globalToUser = globalAmountToDistribute.mul(userPercentage).div(100).div(20);
                globalBalance = globalBalance.sub(globalToUser);

                globalEarned[users[_pid][i]] = globalEarned[users[_pid][i]].add(globalToUser);
            }
            emit DistributedGLOBAL(globalAmountToDistribute.sub(globalBalance));
        }
    }
}