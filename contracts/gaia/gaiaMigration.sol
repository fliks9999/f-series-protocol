pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract gaiaMigration {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public gaiaV1;
    IERC20 public gaiaV2;
    address public treasury;
    bool private reEntrancy;
    address public timelock;

    event Migrate(address indexed user, uint256 gaiaV1Burned, uint256 gaiaV2Earned);

    constructor (
        IERC20 _gaiaV1,
        IERC20 _gaiaV2
    )  
        public
    {
        gaiaV1 = _gaiaV1;
        gaiaV2 = _gaiaV2;
        treasury = address(0x4a7644f6dd90e91B66C489240cE1bF77cec1175d);
        timelock = address(0xf4a4534a9A049E5B3B6701e71b276b8a11F09139);
    }

    // rate is 500 gaiaV1 -> 1 gaiaV2
    function migrate(uint256 amount) public {
        require(!reEntrancy);
        reEntrancy = true;
        gaiaV1.safeTransferFrom(msg.sender, address(this), amount);
        safeGaiaV2Transfer(msg.sender, amount.div(500));
        reEntrancy = false;

        emit Migrate(msg.sender, amount, amount.div(500));
    }

    // removes gaiaV2 to send to treasury
    function withdrawGaiaV2() public {
        require(msg.sender == timelock, 'only timelock');
        uint256 gaiaBal = gaiaV2.balanceOf(address(this));
        safeGaiaV2Transfer(treasury, gaiaBal);
    }

    function safeGaiaV2Transfer(address _to, uint256 _amount) internal {
        uint256 gaiaBal = gaiaV2.balanceOf(address(this));
        if (_amount > gaiaBal) {
            gaiaV2.transfer(_to, gaiaBal);
        } else {
            gaiaV2.transfer(_to, _amount);
        }
    }
}
