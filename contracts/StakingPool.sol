// SPDX-License-Identifier: agpl-3.0
// pragma solidity 0.8.8;

import "./interfaces/IADXToken.sol";
import "./interfaces/IStakingPool.sol";
import "./interfaces/IERC20.sol";

contract StakingPool is IStakingPool, IERC20 {
	// ERC20 stuff
	// Constants
	string public constant name = "AdEx Staking Token v2";
	uint8 public constant decimals = 18;
	string public constant symbol = "stkADX";

	// Mutable variables
	uint public totalShares;
	mapping(address => uint) public shares;
	mapping(address => mapping(address => uint)) private allowed;
	// EIP 2612
	bytes32 public DOMAIN_SEPARATOR;
	// keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
	bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
	mapping(address => uint) public nonces;

	// ERC20 methods
	function balanceOf(address owner) external view returns (uint balance) {
		return (shares[owner] * this.shareValue()) / 1e18;
	}

	function totalSupply() external view returns (uint total) {
		return IERC20(baseToken).balanceOf(address(this)) + IADXToken(baseToken).supplyController().mintableIncentive(address(this));
	}

	function transfer(address to, uint amount) external returns (bool success) {
		require(to != address(this), "cannot send to contract");
		require(commitments[msg.sender].shareAmount == 0, "unstaking in progress");
		uint shareAmount = (amount * 1e18) / this.shareValue();
		require(shareAmount > 0, "trying to transfer zero shares");
		shares[msg.sender] = shares[msg.sender] - shareAmount;
		shares[to] = shares[to] + shareAmount;
		emit Transfer(msg.sender, to, amount);
		return true;
	}

	function transferFrom(address from, address to, uint amount) external returns (bool success) {
		require(to != address(this), "cannot send to contract");
		require(commitments[from].shareAmount == 0, "unstaking in progress");
		uint _shareValue = this.shareValue();
		uint256 shareAmount = (amount * 1e18) / _shareValue;
		require(shareAmount > 0, "trying to transfer zero shares");
		shares[from] = shares[from] - shareAmount;
		uint256 prevAllowance = allowed[from][msg.sender];
		if (prevAllowance < type(uint256).max) allowed[from][msg.sender] = prevAllowance - (shareAmount * _shareValue) / 1e18;
		shares[to] = shares[to] + shareAmount;
		emit Transfer(from, to, amount);
		return true;
	}

	function approve(address spender, uint amount) external returns (bool success) {
		allowed[msg.sender][spender] = amount;
		emit Approval(msg.sender, spender, amount);
		return true;
	}

	function allowance(address owner, address spender) external view returns (uint remaining) {
		return allowed[owner][spender];
	}

	// EIP 2612
	function permit(address owner, address spender, uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
		require(deadline >= block.timestamp, "DEADLINE_EXPIRED");
		bytes32 digest = keccak256(abi.encodePacked(
			"\x19\x01",
			DOMAIN_SEPARATOR,
			keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, amount, nonces[owner]++, deadline))
		));
		address recoveredAddress = ecrecover(digest, v, r, s);
		require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNATURE");
		allowed[owner][spender] = amount;
		emit Approval(owner, spender, amount);
	}

	// Inner
	function mintShares(address owner, uint shareAmount) internal {
		totalShares = totalShares + shareAmount;
		shares[owner] = shares[owner] + shareAmount;
	}
	function burnShares(address owner, uint shareAmount) internal {
		totalShares = totalShares - shareAmount;
		shares[owner] = shares[owner] - shareAmount;
	}

	// Pool functionality
	uint public timeToUnbond = 60 days;
	uint public rageReceivedPromilles = 700;

	address public immutable baseToken;
	address public governance;

	// Each user can only have one unbonding committment at a time
	mapping (address => UnbondCommitment) public commitments;
	mapping (address => uint) public individualTimeToUnbond;
	// Unbonding commitment from a staker
	struct UnbondCommitment {
		uint shareAmount;
		uint tokensToReceive;
		uint unlocksAt;
	}

	// Staking pool events
	// LogLeave/LogWithdraw must begin with the UnbondCommitment struct
	event LogLeave(address indexed owner, uint shareAmount, uint unlocksAt, uint maxTokens);
	event LogWithdraw(address indexed owner, uint shareAmount, uint unlocksAt, uint maxTokens, uint receivedTokens);
	event LogRageLeave(address indexed owner, uint shareAmount, uint maxTokens, uint receivedTokens);

	constructor(IADXToken token, address governanceAddr) {
		baseToken = address(token);
		governance = governanceAddr;

		// EIP 2612
		uint chainId;
		assembly {
			chainId := chainid()
		}
		DOMAIN_SEPARATOR = keccak256(
			abi.encode(
				keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
				keccak256(bytes(name)),
				keccak256(bytes("1")),
				chainId,
				address(this)
			)
		);
	}

	// Governance functions
	function setGovernance(address addr) external {
		require(governance == msg.sender, "NOT_GOVERNANCE");
		governance = addr;
	}
	function setRageReceived(uint rageReceived) external {
		require(governance == msg.sender, "NOT_GOVERNANCE");
		// AUDIT: should there be a minimum here?
		require(rageReceived <= 1000, "TOO_LARGE");
		rageReceivedPromilles = rageReceived;
	}
	function setTimeToUnbond(uint time) external {
		require(governance == msg.sender, "NOT_GOVERNANCE");
		require(time >= 1 days && time <= 365 days, "BOUNDS");
		timeToUnbond = time;
	}

	// Pool stuff
	function shareValue() external view returns (uint) {
		if (totalShares == 0) return 0;
		return (this.totalSupply()
			* 1e18)
			/ totalShares;
	}

	function innerEnter(address recipient, uint amount) internal {
		// Please note that minting has to be in the beginning so that we take it into account
		// when using IADXToken(baseToken).balanceOf()
		// Minting makes an external call but it's to a trusted contract (ADXToken)
		IADXToken(baseToken).supplyController().mintIncentive(address(this));

		uint totalADX = IERC20(baseToken).balanceOf(address(this));

		// The totalADX == 0 check here should be redudnant; the only way to get totalShares to a nonzero val is by adding ADX
		if (totalShares == 0 || totalADX == 0) {
			mintShares(recipient, amount);
		} else {
			uint256 newShares = (amount * totalShares) / totalADX;
			mintShares(recipient, newShares);
		}
		require(IERC20(baseToken).transferFrom(msg.sender, address(this), amount));
		// @TODO: perhaps emit the share value here too
		// Because of https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20.md#transfer-1
		emit Transfer(address(0), recipient, amount);
	}

	function enter(uint amount) external {
		innerEnter(msg.sender, amount);
	}

	// not allowed for enterTo because it would be unfair to set somebody else's time
	function enterWithUnbondTime(uint amount, uint time) external {
		require(time >= individualTimeToUnbond[msg.sender] || shares[msg.sender] == 0, "you cannot reduce individual time to unbond unless you have zero stake");
		individualTimeToUnbond[msg.sender] = time;
		// This method can be invoked with zero amount, just to adjust time
		if (amount > 0) innerEnter(msg.sender, amount);
	}

	function enterTo(address recipient, uint amount) external {
		innerEnter(recipient, amount);
	}

	function unstake(uint shareAmount, bool skipMint) external {
		if (!skipMint) IADXToken(baseToken).supplyController().mintIncentive(address(this));

		require(shareAmount > 0, "shareAmount must be greater than 0");
		require(commitments[msg.sender].shareAmount == 0, "unstaking already in progress");
		require(shareAmount <= shares[msg.sender], "insufficient shares");

		uint totalBase = IERC20(baseToken).balanceOf(address(this));
		uint unbondTime = individualTimeToUnbond[msg.sender] > timeToUnbond ? individualTimeToUnbond[msg.sender] : timeToUnbond;

		commitments[msg.sender] = UnbondCommitment({
			tokensToReceive: (shareAmount * totalBase) / totalShares,
			unlocksAt: block.timestamp + unbondTime,
			shareAmount: shareAmount
		});

		emit LogLeave(msg.sender, shareAmount, commitments[msg.sender].unlocksAt, commitments[msg.sender].tokensToReceive);
	}

	function withdraw(bool skipMint) external {
		if (!skipMint) IADXToken(baseToken).supplyController().mintIncentive(address(this));

		uint shareAmount = commitments[msg.sender].shareAmount;
		require(shareAmount > 0, "no unbonding committment");

		uint unlocksAt = commitments[msg.sender].unlocksAt;
		require(block.timestamp > unlocksAt, "too early to withdraw");

		// This math only exists in case the pool goes DOWN in total tokens,
		// otherwise we can simply use .tokensToReceive
		uint maxTokens = commitments[msg.sender].tokensToReceive;
		uint totalBase = IERC20(baseToken).balanceOf(address(this));
		uint currentTokens = (shareAmount * totalBase) / totalShares;
		uint receivedTokens = currentTokens > maxTokens ? maxTokens : currentTokens;

		burnShares(msg.sender, shareAmount);
		commitments[msg.sender] = UnbondCommitment({ unlocksAt: 0, tokensToReceive: 0, shareAmount: 0 });

		require(IERC20(baseToken).transfer(msg.sender, receivedTokens), "base token transfer failed");

		emit Transfer(msg.sender, address(0), currentTokens);
		emit LogWithdraw(msg.sender, shareAmount, unlocksAt, maxTokens, receivedTokens);
	}

	function rageLeave(uint shareAmount, bool skipMint) external {
		if (!skipMint) IADXToken(baseToken).supplyController().mintIncentive(address(this));

		uint totalBase = IERC20(baseToken).balanceOf(address(this));
		uint currentTokens = (shareAmount * totalBase) / totalShares;
		uint receivedTokens = (currentTokens * rageReceivedPromilles) / 1000;
		burnShares(msg.sender, shareAmount);
		require(IERC20(baseToken).transfer(msg.sender, receivedTokens), "base token transfer failed");

		if (commitments[msg.sender].shareAmount > shares[msg.sender]) {
			// reset that user's committment, otherwise they end up bricked until they deposit more tokens
			commitments[msg.sender] = UnbondCommitment({ unlocksAt: 0, tokensToReceive: 0, shareAmount: 0 });
		}

		emit Transfer(msg.sender, address(0), currentTokens);
		emit LogRageLeave(msg.sender, shareAmount, currentTokens, receivedTokens);
	}
}