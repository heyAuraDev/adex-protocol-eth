// SPDX-License-Identifier: agpl-3.0

interface IStakingPool {
	function baseToken() external returns (address);
	function shareValue() external view returns (uint256);
	function enterTo(address recipient, uint amount) external;
	function rageReceivedPromilles() external returns (uint256);
	function governance() external view returns (address);
	function setRageReceived(uint256) external;
	function rageLeave(uint256, bool) external;
}
