pragma solidity ^0.6.0;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

interface TwapOracle {
    function update() external;
    function consult(address token, uint amountIn) external view returns (uint amountOut);
    function changePeriod(uint256 seconds_) external;
}

interface IGaia {
    function burn(address from, uint256 amount) external;
    function mint(address to, uint256 amount) external;
}

contract USDf is ERC20UpgradeSafe, OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe {
    using SafeMath for uint256;

    uint256 constant public MAX_RESERVE_RATIO = 100 * 10 ** 9;
    uint256 private constant DECIMALS = 9;
    uint256 private _lastRefreshReserve;
    uint256 private _minimumRefreshTime;
    uint256 public gaiaDecimals;
    uint256 private constant MAX_SUPPLY = ~uint128(0);
    uint256 private extraVar;
    uint256 private _totalSupply;
    uint256 private _mintFee;
    uint256 private _withdrawFee;
    uint256 private _minimumDelay;                        // how long a user must wait between actions
    uint256 public MIN_RESERVE_RATIO;
    uint256 private _reserveRatio;
    uint256 private _stepSize;

    address public gaia;            
    address public synthOracle;
    address public gaiaOracle;
    address public usdcAddress;
    
    address[] private collateralArray;

    AggregatorV3Interface internal usdcPrice;

    mapping(address => uint256) private _synthBalance;
    mapping(address => uint256) private _lastAction;
    mapping (address => mapping (address => uint256)) private _allowedSynth;
    mapping (address => bool) public acceptedCollateral;
    mapping (address => uint256) public collateralDecimals;
    mapping (address => address) public collateralOracle;
    mapping (address => bool) public seenCollateral;
    mapping (address => uint256) private _burnedSynth;

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    modifier sync() {
        if (_totalSupply > 0) {
            updateOracles();

            if (now - _lastRefreshReserve >= _minimumRefreshTime) {
                TwapOracle(gaiaOracle).update();
                TwapOracle(synthOracle).update();
                if (getSynthOracle() > 1 * 10 ** 9) {
                    setReserveRatio(_reserveRatio.sub(_stepSize));
                } else {
                    setReserveRatio(_reserveRatio.add(_stepSize));
                }

                _lastRefreshReserve = now;
            }
        }
        
        _;
    }

    event NewReserveRate(uint256 reserveRatio);
    event Mint(address gaia, address receiver, address collateral, uint256 collateralAmount, uint256 gaiaAmount, uint256 synthAmount);
    event Withdraw(address gaia, address receiver, address collateral, uint256 collateralAmount, uint256 gaiaAmount, uint256 synthAmount);
    event NewMinimumRefreshTime(uint256 minimumRefreshTime);
    event MintFee(uint256 fee);
    event WithdrawFee(uint256 fee);
    event NewStepSize(uint256 stepSize);

    // constructor ============================================================
    function initialize(address gaia_, uint256 gaiaDecimals_, address usdcAddress_, address usdcOracleChainLink_) public initializer {
        OwnableUpgradeSafe.__Ownable_init();
        ReentrancyGuardUpgradeSafe.__ReentrancyGuard_init();

        ERC20UpgradeSafe.__ERC20_init('USDf', 'USDf');
        ERC20UpgradeSafe._setupDecimals(9);

        gaia = gaia_;
        _minimumRefreshTime = 3600 * 1;      // 1 hours by default
        _minimumDelay = 5 * 60;              // 5 minutes or 300 seconds
        gaiaDecimals = gaiaDecimals_;
        usdcPrice = AggregatorV3Interface(usdcOracleChainLink_);
        usdcAddress = usdcAddress_;
        _reserveRatio = 100 * 10 ** 9;   // 100% reserve at first
        _totalSupply = 0;
        _stepSize = 1 * 10 ** 8;         // 0.1% step size

        MIN_RESERVE_RATIO = 99 * 10 ** 9;
    }

    // public view functions ============================================================
    function getCollateralByIndex(uint256 index_) external view returns (address) {
        return collateralArray[index_];
    }
    
    function stepSize() external view returns (uint256) {
        return _stepSize;
    }

    function burnedSynth(address user_) external view returns (uint256) {
        return _burnedSynth[user_];
    }

    function lastAction(address user_) external view returns (uint256) {
        return _lastAction[user_];
    }

    function getCollateralUsd(address collateral_) public view returns (uint256) {
        // price is $Y / USD (10 ** 8 decimals)
        ( , int price, , uint timeStamp, ) = usdcPrice.latestRoundData();
        require(timeStamp > 0, "Rounds not complete");

        if (address(collateral_) == address(usdcAddress)) {
            return uint256(price).mul(10);
        } else {
            return uint256(price).mul(10 ** 10).div((TwapOracle(collateralOracle[collateral_]).consult(usdcAddress, 10 ** 6)).mul(10 ** 9).div(10 ** collateralDecimals[collateral_]));
        }
    }

    function globalCollateralValue() public view returns (uint256) {
        uint256 totalCollateralUsd = 0; 

        for (uint i = 0; i < collateralArray.length; i++){ 
            // Exclude null addresses
            if (collateralArray[i] != address(0)){
                totalCollateralUsd += IERC20(collateralArray[i]).balanceOf(address(this)).mul(10 ** 9).div(10 ** collateralDecimals[collateralArray[i]]).mul(getCollateralUsd(collateralArray[i])).div(10 ** 9); // add stablecoin balance
            }
        }
        return totalCollateralUsd;
    }

    function usdfInfo() public view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            _totalSupply,
            _reserveRatio,
            globalCollateralValue(),
            _mintFee,
            _withdrawFee,
            _minimumDelay,
            getGaiaOracle(),
            getSynthOracle(),
            _lastRefreshReserve,
            _minimumRefreshTime
        );
    }

    function totalSupply() public override view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address who) public override view returns (uint256) {
        return _synthBalance[who];
    }

    function allowance(address owner_, address spender) public override view returns (uint256) {
        return _allowedSynth[owner_][spender];
    }

    function getGaiaOracle() public view returns (uint256) {
        uint256 gaiaTWAP = TwapOracle(gaiaOracle).consult(usdcAddress, 1 * 10 ** 6);

        ( , int price, , uint timeStamp, ) = usdcPrice.latestRoundData();

        require(timeStamp > 0, "rounds not complete");

        return uint256(price).mul(10).mul(10 ** DECIMALS).div(gaiaTWAP);
    }

    function getSynthOracle() public view returns (uint256) {
        uint256 synthTWAP = TwapOracle(synthOracle).consult(usdcAddress, 1 * 10 ** 6);

        ( , int price, , uint timeStamp, ) = usdcPrice.latestRoundData();

        require(timeStamp > 0, "rounds not complete");

        return uint256(price).mul(10).mul(10 ** DECIMALS).div(synthTWAP);
    }

    function consultSynthRatio(uint256 synthAmount, address collateral) public view returns (uint256, uint256) {
        require(synthAmount != 0, "must use valid USDf amount");
        require(seenCollateral[collateral], "must be seen collateral");

        uint256 collateralAmount = synthAmount.mul(_reserveRatio).div(MAX_RESERVE_RATIO).mul(10 ** collateralDecimals[collateral]).div(10 ** DECIMALS);

        if (_totalSupply == 0) {
            return (collateralAmount, 0);
        } else {
            collateralAmount = collateralAmount.mul(10 ** 9).div(getCollateralUsd(collateral)); // get real time price
            uint256 gaiaUsd = getGaiaOracle();                         
            uint256 synthPrice = getSynthOracle();                      

            uint256 synthPart2 = synthAmount.mul(MAX_RESERVE_RATIO.sub(_reserveRatio)).div(MAX_RESERVE_RATIO);
            uint256 gaiaAmount = synthPart2.mul(synthPrice).div(gaiaUsd);

            return (collateralAmount, gaiaAmount);
        }
    }

    // public functions ============================================================
    function updateOracles() public {
        for (uint i = 0; i < collateralArray.length; i++) {
            if (acceptedCollateral[collateralArray[i]]) TwapOracle(collateralOracle[collateralArray[i]]).update();
        } 
    }

    function transfer(address to, uint256 value) public override validRecipient(to) sync() returns (bool) {
        _synthBalance[msg.sender] = _synthBalance[msg.sender].sub(value);
        _synthBalance[to] = _synthBalance[to].add(value);
        emit Transfer(msg.sender, to, value);

        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override validRecipient(to) sync() returns (bool) {
        _allowedSynth[from][msg.sender] = _allowedSynth[from][msg.sender].sub(value);

        _synthBalance[from] = _synthBalance[from].sub(value);
        _synthBalance[to] = _synthBalance[to].add(value);
        emit Transfer(from, to, value);

        return true;
    }

    function approve(address spender, uint256 value) public override sync() returns (bool) {
        _allowedSynth[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public override returns (bool) {
        _allowedSynth[msg.sender][spender] = _allowedSynth[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedSynth[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public override returns (bool) {
        uint256 oldValue = _allowedSynth[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedSynth[msg.sender][spender] = 0;
        } else {
            _allowedSynth[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedSynth[msg.sender][spender]);
        return true;
    }

    function mint(uint256 synthAmount, address collateral) public nonReentrant sync() {
        require(acceptedCollateral[collateral], "must be an accepted collateral");

        (uint256 collateralAmount, uint256 gaiaAmount) = consultSynthRatio(synthAmount, collateral);
        require(collateralAmount <= IERC20(collateral).balanceOf(msg.sender), "sender has insufficient collateral balance");
        require(gaiaAmount <= IERC20(gaia).balanceOf(msg.sender), "sender has insufficient gaia balance");

        SafeERC20.safeTransferFrom(IERC20(collateral), msg.sender, address(this), collateralAmount);

        if (gaiaAmount != 0) IGaia(gaia).burn(msg.sender, gaiaAmount);

        synthAmount = synthAmount.sub(synthAmount.mul(_mintFee).div(100 * 10 ** DECIMALS));

        _totalSupply = _totalSupply.add(synthAmount);
        _synthBalance[msg.sender] = _synthBalance[msg.sender].add(synthAmount);

        emit Transfer(address(0x0), msg.sender, synthAmount);
        emit Mint(gaia, msg.sender, collateral, collateralAmount, gaiaAmount, synthAmount);
    }

    function withdraw(uint256 synthAmount) public nonReentrant sync() {
        require(synthAmount <= _synthBalance[msg.sender], "insufficient balance");

        _totalSupply = _totalSupply.sub(synthAmount);
        _synthBalance[msg.sender] = _synthBalance[msg.sender].sub(synthAmount);

        // record keeping
        _burnedSynth[msg.sender] = _burnedSynth[msg.sender].add(synthAmount);

        _lastAction[msg.sender] = now;

        emit Transfer(msg.sender, address(0x0), synthAmount);
    }

    function completeWithdrawal(address collateral, uint256 synthAmount) public nonReentrant sync() {
        require(now.sub(_lastAction[msg.sender]) > _minimumDelay, "action too soon");
        require(seenCollateral[collateral], "invalid collateral");
        require(synthAmount != 0);
        require(synthAmount <= _burnedSynth[msg.sender]);

        _burnedSynth[msg.sender] = _burnedSynth[msg.sender].sub(synthAmount);

        (uint256 collateralAmount, uint256 gaiaAmount) = consultSynthRatio(synthAmount, collateral);

        collateralAmount = collateralAmount.sub(collateralAmount.mul(_withdrawFee).div(100 * 10 ** DECIMALS));
        gaiaAmount = gaiaAmount.sub(gaiaAmount.mul(_withdrawFee).div(100 * 10 ** DECIMALS));

        require(collateralAmount <= IERC20(collateral).balanceOf(address(this)), "insufficient collateral");

        SafeERC20.safeTransfer(IERC20(collateral), msg.sender, collateralAmount);
        if (gaiaAmount != 0) IGaia(gaia).mint(msg.sender, gaiaAmount);

        _lastAction[msg.sender] = now;

        emit Withdraw(gaia, msg.sender, collateral, collateralAmount, gaiaAmount, synthAmount);
    }

    // governance functions ============================================================
    function burnGaia(uint256 amount) external onlyOwner {
        require(amount <= IERC20(gaia).balanceOf(msg.sender));
        IGaia(gaia).burn(msg.sender, amount);
    }

    function setDelay(uint256 val_) external onlyOwner {
        _minimumDelay = val_;
    }

    function setStepSize(uint256 _step) external onlyOwner {
        _stepSize = _step;
        emit NewStepSize(_step);
    }

    // function used to add
    function addCollateral(address collateral_, uint256 collateralDecimal_, address oracleAddress_) external onlyOwner {
        collateralArray.push(collateral_);
        acceptedCollateral[collateral_] = true;
        seenCollateral[collateral_] = true;
        collateralDecimals[collateral_] = collateralDecimal_;
        collateralOracle[collateral_] = oracleAddress_;
    }

    function setCollateralOracle(address collateral_, address oracleAddress_) external onlyOwner {
        collateralOracle[collateral_] = oracleAddress_;
    }

    function removeCollateral(address collateral_) external onlyOwner {
        delete acceptedCollateral[collateral_];
        delete collateralOracle[collateral_];

        for (uint i = 0; i < collateralArray.length; i++){ 
            if (collateralArray[i] == collateral_) {
                collateralArray[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }
    }

    function setSynthOracle(address oracle_) external onlyOwner returns (bool)  {
        synthOracle = oracle_;
        
        return true;
    }

    function setGaiaOracle(address oracle_) external onlyOwner returns (bool) {
        gaiaOracle = oracle_;

        return true;
    }

    function editMintFee(uint256 fee_) external onlyOwner {
        _mintFee = fee_;
        emit MintFee(fee_);
    }

    function editWithdrawFee(uint256 fee_) external onlyOwner {
        _withdrawFee = fee_;
        emit WithdrawFee(fee_);
    }

    function setSeenCollateral(address collateral_, bool val_) external onlyOwner {
        seenCollateral[collateral_] = val_;
    }

    function setMinReserveRate(uint256 rate_) external onlyOwner {
        require(rate_ != 0);
        require(rate_ <= 100 * 10 ** 9, "rate high");

        MIN_RESERVE_RATIO = rate_;
    }

    function setReserveRatioAdmin(uint256 newRatio_) external onlyOwner {
        require(newRatio_ != 0);

        if (newRatio_ >= MIN_RESERVE_RATIO && newRatio_ <= MAX_RESERVE_RATIO) {
            _reserveRatio = newRatio_;
            emit NewReserveRate(_reserveRatio);
        }
    }

    function setMinimumRefreshTime(uint256 val_) external onlyOwner returns (bool) {
        require(val_ != 0);

        _minimumRefreshTime = val_;

        for (uint i = 0; i < collateralArray.length; i++) {
            if (acceptedCollateral[collateralArray[i]]) TwapOracle(collateralOracle[collateralArray[i]]).changePeriod(val_);
        }

        emit NewMinimumRefreshTime(val_);
        return true;
    }

    // multi-purpose function for investing, managing treasury
    function executeTransaction(address target, uint value, string memory signature, bytes memory data) public payable onlyOwner returns (bytes memory) {
        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        (bool success, bytes memory returnData) = target.call.value(value)(callData);
        require(success);

        return returnData;
    }

    // internal private functions ============================================================
    function setReserveRatio(uint256 newRatio_) private {
        require(newRatio_ != 0);

        if (newRatio_ >= MIN_RESERVE_RATIO && newRatio_ <= MAX_RESERVE_RATIO) {
            _reserveRatio = newRatio_;
            emit NewReserveRate(_reserveRatio);
        }
    }
}
