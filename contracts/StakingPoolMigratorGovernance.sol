// SPDX-License-Identifier: agpl-3.0
//pragma solidity 0.8.8;

import "./interfaces/IStakingPool.sol";
import "./interfaces/IERC20.sol";

contract StakingMigratorGovernance {
    address public immutable actualGovernance;
    address public immutable baseToken;
    uint256 public gracePeriod;
    uint256 public deadline;
    uint256 public maxPromillesToBurn;

    constructor(
        address _baseToken,
        uint256 _customDeadline,
        uint256 _customGracePeriod,
        address _governance,
        uint256 _defaultMaxPromillesToBurn
    ) {
        actualGovernance = _governance;
        baseToken = _baseToken;
        if (_customGracePeriod != 0) gracePeriod = _customGracePeriod;
        else gracePeriod = block.timestamp + 32 days;
        if (_customDeadline != 0) deadline = gracePeriod + _customDeadline;
        else deadline = gracePeriod + 90 days;
        if (_defaultMaxPromillesToBurn != 0)
            maxPromillesToBurn = _defaultMaxPromillesToBurn;
        else maxPromillesToBurn = 200; // default max burn is 20%
    }

    function migrate(
        IStakingPool oldPool,
        uint shares,
        bool skipMint,
        IStakingPool newPool
    ) external {
        IERC20 token = IERC20(baseToken);
        uint256 startAmount = token.balanceOf(address(this));

        // first, pull the old staking tokens and temporarily set rage leave percentage so that we can pull the baseToken
        IERC20(address(oldPool)).transferFrom(
            msg.sender,
            address(this),
            shares
        );
        uint rageReceived = oldPool.rageReceivedPromilles();
        oldPool.setRageReceived(1000);
        oldPool.rageLeave(shares, skipMint);
        oldPool.setRageReceived(rageReceived);

        // then stake all baseTokens we have in the new pool
        require(
            address(token) == address(newPool.baseToken()),
            "baseToken not the same"
        );
        uint tokenAmount = token.balanceOf(address(this)) - startAmount;
        require(tokenAmount > 0, "no tokens to migrate");

        // Migration period math
        uint amountToMigrate = tokenAmount;
        uint amountToBurn = 0;

        if (block.timestamp > gracePeriod) {
            uint256 promillesToBurn = maxPromillesToBurn;
            if (block.timestamp < deadline) {
                promillesToBurn =
                    ((block.timestamp - gracePeriod) * maxPromillesToBurn) /
                    (deadline - gracePeriod);
            }
            amountToBurn = (tokenAmount * promillesToBurn) / 1000;
            amountToMigrate = tokenAmount - amountToBurn;
        }

        require(amountToMigrate > 0, "nothing to migrate");

        token.approve(address(newPool), amountToMigrate);
        newPool.enterTo(msg.sender, amountToMigrate);
		if(amountToBurn > 0) {
        token.transfer(address(0), amountToBurn); // Burn tokens
		}
    }

    // needed because we appoint this contract as the sole governance of the StakingPool, so we need to be able to do arbitrary calls
    function call(address to, bytes calldata data) external {
        require(msg.sender == actualGovernance, "is not governance");
        (bool success, bytes memory returnData) = to.call{value: 0}(data);
        uint size = returnData.length;
        if (success) {
            assembly {
                return(add(returnData, 32), size)
            }
        } else {
            assembly {
                revert(add(returnData, 32), size)
            }
        }
    }
}
