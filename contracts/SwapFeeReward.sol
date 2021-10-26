pragma solidity >= 0.6.12;

import './Modifiers/Ownable.sol';
import './Helpers/IOracle.sol';
import './Libraries/SafeMath.sol';
import './Libraries/EnumerableSet.sol';
import './Tokens/IPair.sol';
import "./IFactory.sol";
import "./Helpers/IMinter.sol";

contract SwapFeeReward is Ownable{
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _whitelist;

    address public factory;
    address public router;
    bytes32 public INIT_CODE_HASH;
    uint256 public maxMiningAmount  = 100000000 * 1e18;
    uint256 public maxMiningInPhase = 5000 * 1e18;
    uint public currentPhase = 1;
    uint256 public totalMined = 0;
    IOracle public oracle;
    address public targetToken;
    IMinter private minter;

    mapping(address => uint) public nonces;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) public pairOfPid;

    struct PairsList {
        address pair;
        uint256 percentReward;
        bool enabled;
    }
    PairsList[] public pairsList;

    event Withdraw(address userAddress, uint256 amount);
    event Rewarded(address account, address input, address output, uint256 amount, uint256 quantity);

    modifier onlyRouter() {
        require(msg.sender == router, "SwapFeeReward: caller is not the router");
        _;
    }

    constructor(
        address _factory,
        address _router,
        bytes32 _INIT_CODE_HASH,
        IOracle _Oracle,
        address _targetToken
    ) public {
        factory = _factory;
        router = _router;
        INIT_CODE_HASH = _INIT_CODE_HASH;
        oracle = _Oracle;
        targetToken = _targetToken;
    }

    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'BSWSwapFactory: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'BSWSwapFactory: ZERO_ADDRESS');
    }

    function pairFor(address tokenA, address tokenB) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                INIT_CODE_HASH
            ))));
    }

    function getSwapFee(address tokenA, address tokenB) internal view returns (uint swapFee) {
        swapFee = uint(1000).sub(IPair(pairFor(tokenA, tokenB)).swapFee());
    }

    function setPhase(uint _newPhase) public onlyOwner returns(bool){
        currentPhase = _newPhase;
        return true;
    }

    function checkPairExist(address tokenA, address tokenB) public view returns (bool) {
        address pair = pairFor(tokenA, tokenB);
        PairsList storage pool = pairsList[pairOfPid[pair]];
        if (pool.pair != pair) {
            return false;
        }
        return true;
    }

    function swap(address account, address input, address output, uint256 amount) public onlyRouter returns (bool) {
        if (!isWhitelist(input) || !isWhitelist(output)) {
            return false;
        }
        if (maxMiningAmount <= totalMined){
            return false;
        }
        address pair = pairFor(input, output);
        PairsList storage pool = pairsList[pairOfPid[pair]];
        if (pool.pair != pair || pool.enabled == false) {
            return false;
        }
        uint256 pairFee = getSwapFee(input, output);
        uint256 fee = amount.div(pairFee);
        uint256 quantity = getQuantity(output, fee, targetToken);
        quantity = quantity.mul(pool.percentReward).div(100);
        if (totalMined.add(quantity) > currentPhase.mul(maxMiningInPhase)){
            return false;
        }
        _balances[account] = _balances[account].add(quantity);
        emit Rewarded(account, input, output, amount, quantity);
        return true;
    }

    function rewardBalance(address account) public view returns(uint256){
        return _balances[account];
    }

    function permit(address spender, uint value, uint8 v, bytes32 r, bytes32 s) private {
        bytes32 message = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(abi.encodePacked(spender, value, nonces[spender]++))));
        address recoveredAddress = ecrecover(message, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == spender, 'SwapFeeReward: INVALID_SIGNATURE');
    }

    function withdraw(uint8 v, bytes32 r, bytes32 s) public returns(bool){
        require(maxMiningAmount > totalMined, 'SwapFeeReward: Mined all tokens');
        uint256 balance = _balances[msg.sender];
        require(totalMined.add(balance) <= currentPhase.mul(maxMiningInPhase), 'SwapFeeReward: Mined all tokens in this phase');
        permit(msg.sender, balance, v, r, s);
        if (balance > 0){
            //bswToken.mint(msg.sender, balance); //mintejar amb el masterchef
            minter.mintNativeTokens(balance, msg.sender);
            _balances[msg.sender] = _balances[msg.sender].sub(balance);
            emit Withdraw(msg.sender, balance);
            totalMined = totalMined.add(balance);
            return true;
        }
        return false;
    }

    function getQuantity(address outputToken, uint256 outputAmount, address anchorToken) public view returns (uint256) {
        uint256 quantity = 0;
        if (outputToken == anchorToken) {
            quantity = outputAmount;
        } else if (IFactory(factory).getPair(outputToken, anchorToken) != address(0) && checkPairExist(outputToken, anchorToken)) {
            quantity = IOracle(oracle).consult(outputToken, outputAmount, anchorToken);
        } else {
            uint256 length = getWhitelistLength();
            for (uint256 index = 0; index < length; index++) {
                address intermediate = getWhitelist(index);
                if (IFactory(factory).getPair(outputToken, intermediate) != address(0) && IFactory(factory).getPair(intermediate, anchorToken) != address(0) && checkPairExist(intermediate, anchorToken)) {
                    uint256 interQuantity = IOracle(oracle).consult(outputToken, outputAmount, intermediate);
                    quantity = IOracle(oracle).consult(intermediate, interQuantity, anchorToken);
                    break;
                }
            }
        }
        return quantity;
    }

    function addWhitelist(address _addToken) public onlyOwner returns (bool) {
        require(_addToken != address(0), "SwapMining: token is the zero address");
        return EnumerableSet.add(_whitelist, _addToken);
    }

    function delWhitelist(address _delToken) public onlyOwner returns (bool) {
        require(_delToken != address(0), "SwapMining: token is the zero address");
        return EnumerableSet.remove(_whitelist, _delToken);
    }

    function getWhitelistLength() public view returns (uint256) {
        return EnumerableSet.length(_whitelist);
    }

    function isWhitelist(address _token) public view returns (bool) {
        return EnumerableSet.contains(_whitelist, _token);
    }

    function getWhitelist(uint256 _index) public view returns (address){
        require(_index <= getWhitelistLength() - 1, "SwapMining: index out of bounds");
        return EnumerableSet.at(_whitelist, _index);
    }

    function setFactory(address _factory) public onlyOwner {
        require(_factory != address(0), "SwapMining: new factory is the zero address");
        factory = _factory;
    }

    function setRouter(address newRouter) public onlyOwner {
        require(newRouter != address(0), "SwapMining: new router is the zero address");
        router = newRouter;
    }

    function setMinter(IMinter iminter) external {
        require(iminter.isMinter(address(this)) == true, "This vault must be a minter in minter's contract");
        minter = iminter;
        //_allowance(cake, _minter); //TODO repassar
    }

    function canMint() internal view returns (bool) {
        return address(minter) != address(0) && minter.isMinter(address(this));
    }

    function setOracle(IOracle _oracle) public onlyOwner {
        require(address(_oracle) != address(0), "SwapMining: new oracle is the zero address");
        oracle = _oracle;
    }

    function setInitCodeHash(bytes32 _INIT_CODE_HASH) public onlyOwner {
        INIT_CODE_HASH = _INIT_CODE_HASH;
    }

    function pairsListLength() public view returns (uint256) {
        return pairsList.length;
    }

    function addPair(uint256 _percentReward, address _pair) public onlyOwner {
        require(_pair != address(0), "_pair is the zero address");
        pairsList.push(
            PairsList({
        pair: _pair,
        percentReward: _percentReward,
        enabled: true
        })
        );
        pairOfPid[_pair] = pairsListLength() - 1;

    }

    function setPair(uint256 _pid, uint256 _percentReward) public onlyOwner {
        pairsList[_pid].percentReward = _percentReward;
    }

    function setPairEnabled(uint256 _pid, bool _enabled) public onlyOwner {
        pairsList[_pid].enabled = _enabled;
    }
}