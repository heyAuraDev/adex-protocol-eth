// SPDX-License-Identifier: agpl-3.0

import "./interfaces/IStakingPool.sol";
import "./interfaces/IERC20.sol";

contract StakingMigratorGovernance {
	address public immutable actualGovernance;
	address public immutable baseToken;
	uint256 public deadline;

	constructor(address _baseToken, uint256 _customDeadline, address _governance) {
		actualGovernance = _governance;
		baseToken =_baseToken;
		if (_customDeadline != 0) deadline = _customDeadline;
		else deadline = block.timestamp + 90 days;
	}

	function migrate(IStakingPool oldPool, uint shares, bool skipMint, IStakingPool newPool) external {
		require(block.timestamp <= deadline, "migrating past deadline");

		IERC20 token = IERC20(baseToken);
		uint256 startAmount = token.balanceOf(address(this));

		// first, pull the old staking tokens and temporarily set rage leave percentage so that we can pull the baseToken
		IERC20(address(oldPool)).transferFrom(msg.sender, address(this), shares); 
		uint rageReceived = oldPool.rageReceivedPromilles();
		oldPool.setRageReceived(1000);
		oldPool.rageLeave(shares, skipMint);
		oldPool.setRageReceived(rageReceived);

		// then stake all baseTokens we have in the new pool
		require(address(token) == address(newPool.baseToken()), "baseToken not the same");
		uint tokenAmount = token.balanceOf(address(this)) - startAmount;
		token.approve(address(newPool), tokenAmount);
		newPool.enterTo(msg.sender, tokenAmount);
	}

	// needed because we appoint this contract as the sole governance of the StakingPool, so we need to be able to do arbitrary calls
	function call(address to, bytes calldata data) external {
		require(msg.sender == actualGovernance, "is not governance");
		(bool success, bytes memory returnData) = to.call{ value: 0 }(data);
		uint size = returnData.length;
		if (success) {
			assembly {
				return (add(returnData, 32), size)
			}
		} else {
			assembly {
				revert(add(returnData, 32), size)
			}
		}
	}
}