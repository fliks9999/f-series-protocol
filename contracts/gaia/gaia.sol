pragma solidity ^0.6.0;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

// SPDX-License-Identifier: GNU GENERAL PUBLIC LICENSE
contract Gaia is ERC20UpgradeSafe, OwnableUpgradeSafe {
    using SafeMath for uint256;

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    modifier onlyMinter() {
        require(minter[msg.sender]);
        _;
    }

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_SUPPLY = 50 * 10 ** 9 * 10 ** DECIMALS;
    uint256 private constant MAX_SUPPLY = ~uint128(0);
    uint256 private _totalSupply;

    mapping (address => bool) public minter;
    mapping (address => uint256) private _gaiaBalances;
    mapping (address => mapping (address => uint256)) private _allowedGaia;

    event EditMinter(address minter, bool val);

    function initialize()
        public
        initializer
    {
        OwnableUpgradeSafe.__Ownable_init();

        ERC20UpgradeSafe.__ERC20_init("Gaia", "Gaia");
        ERC20UpgradeSafe._setupDecimals(uint8(DECIMALS));

        _totalSupply = INITIAL_SUPPLY;
        _gaiaBalances[msg.sender] = _totalSupply;

        emit Transfer(address(0x0), msg.sender, _totalSupply);
    }

    function setMinter(address _minter, bool _val) external onlyOwner {
        minter[_minter] = _val;
        emit EditMinter(_minter, _val);
    }

    function burn(address from, uint256 amount)
        external
        onlyMinter
    {
        require(_gaiaBalances[from] >= amount, "insufficient Gaia balance to burn");

        _totalSupply = _totalSupply.sub(amount);
        _gaiaBalances[from] = _gaiaBalances[from].sub(amount);
        emit Transfer(from, address(0x0), amount);
    }

    function mint(address to, uint256 amount)
        external
        onlyMinter
    {
        _totalSupply = _totalSupply.add(amount);
        _gaiaBalances[to] = _gaiaBalances[to].add(amount);

        emit Transfer(address(0x0), to, amount);
    }

    function totalSupply() public override view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address who) public override view returns (uint256) {
        return _gaiaBalances[who];
    }

    function transfer(address to, uint256 value) public override validRecipient(to) returns (bool) {
        _gaiaBalances[msg.sender] = _gaiaBalances[msg.sender].sub(value);
        _gaiaBalances[to] = _gaiaBalances[to].add(value);
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function allowance(address owner_, address spender) public override view returns (uint256) {
        return _allowedGaia[owner_][spender];
    }

    function transferFrom(address from, address to, uint256 value) public override validRecipient(to) returns (bool) {
        _allowedGaia[from][msg.sender] = _allowedGaia[from][msg.sender].sub(value);

        _gaiaBalances[from] = _gaiaBalances[from].sub(value);
        _gaiaBalances[to] = _gaiaBalances[to].add(value);
        emit Transfer(from, to, value);

        return true;
    }

    function approve(address spender, uint256 value) public override validRecipient(spender) returns (bool) {
        _allowedGaia[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public override returns (bool) {
        _allowedGaia[msg.sender][spender] =
            _allowedGaia[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedGaia[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public override returns (bool) {
        uint256 oldValue = _allowedGaia[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedGaia[msg.sender][spender] = 0;
        } else {
            _allowedGaia[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedGaia[msg.sender][spender]);
        return true;
    }
}
