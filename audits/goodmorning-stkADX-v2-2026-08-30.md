# stkADX v2 — Security Review

**goodmorning** · The Web3 Development Studio · [goodmorning.dev](https://goodmorning.dev)

| | |
|---|---|
| **Prepared by** | goodmorning |
| **Prepared for** | AdEx / Ambire — `adex-protocol-eth` |
| **Date** | 2026-08-30 |
| **Branch** | `feature/aura-staking` |
| **Head reviewed** | `a7c82a9` (after `git pull`, 11 commits from `origin`) |
| **Previous head** | `c534560` |
| **Scope** | `contracts/StakingPool.sol`, `contracts/StakingPoolMigratorGovernance.sol`, `contracts/HeyAuraLoginDomain.sol` (new), plus `contracts/SupplyController.sol` and `contracts/interfaces/*` where they determine in-scope behaviour |
| **Out of scope** | OUTPACE, Identity, Guardian, xWALLET, `contracts/adx/*` (reviewed only as the trusted `baseToken`) |

This document has three parts:

1. **[Part 1](#part-1--reconstructed-audit-report)** — reconstruction of the audit findings that were already fixed in the commit history.
2. **[Part 2](#part-2--the-uncommitted-transfer-event-change)** — the uncommitted working-tree change, why it was probably dropped, and whether that was right.
3. **[Part 3](#part-3--new-audit-pass-on-a7c82a9)** — a fresh pass over the code as pulled.

---

## Part 1 — Reconstructed audit report

### Method

The original audit report was not available. The findings below are reconstructed from the commit history, which separates cleanly into two phases:

| Phase | Range | Dates | Character |
|---|---|---|---|
| **Development** | `70b4211` → `f8948d7` | 2026-01-02 → 01-03 | Feature work: mechanics, renames, simplification, migrator introduction |
| **Audit remediation** | `be4939d` → `c534560` | 2026-01-04, 01-23, 01-25 | Exclusively `fix:` / `security fixes` commits, each a narrow behavioural correction |

Three independent signals corroborate the split:

- The Jan-4 commits are all one- or two-line behavioural corrections with `fix:` subjects, in contrast to the Jan-2/3 commits which add and restructure functionality.
- Two auditor questions were left verbatim in the source and are **still unresolved today**: `contracts/StakingPool.sol:143` (`// AUDIT: should there be a minimum here?`) and `contracts/SupplyController.sol:42` (`// AUDIT: pending incentive lost here`).
- The Jan-23 and Jan-25 fixes (`1230e9e`, `c534560`) are follow-ups on the same findings, consistent with a remediation-review round.

Severities below are assigned by this review, not recovered from the original report.

### Findings summary

| ID | Severity | Finding | Fixed in |
|---|---|---|---|
| A-01 | High | `transferFrom` deducted *share* amounts from a *token*-denominated allowance | `c24fffb` |
| A-02 | Medium | `transferFrom` checked the unbonding lock against the spender, not the token owner | `8f72ed1` |
| A-03 | Medium | `Transfer` events carried share amounts, not token amounts | `8f72ed1`, `495ee1d` |
| A-04 | Medium | Rage-leaving could permanently brick an account holding a stale unbonding commitment | `be4939d` |
| A-05 | Medium | Sub-share transfers moved nothing but still emitted a `Transfer` event | `6e1fa68` |
| A-06 | Medium | Pool hardcoded the ADX interface despite claiming a generic `baseToken` | `7ae8466`, `59b26f1` |
| A-07 | Low | Infinite (`type(uint256).max`) approvals were decremented | `cb867ee` |
| A-08 | Low | Inconsistent / mispositioned guard against transferring to the pool itself | `119c3f0` |
| A-09 | Low | Allowance over-deducted by the share-rounding remainder | `c534560` |
| A-10 | Low | Default `timeToUnbond` fell outside the governance-settable range | `1230e9e` |
| A-11 | Low | Base-token transfer failures reverted without a reason string | `be4939d` |

---

### A-01 · High · `transferFrom` deducted share amounts from a token-denominated allowance

**Fixed in** `c24fffb` — *"transferFrom should deduct token amount, not shares amount"*

```diff
-		allowed[from][msg.sender] = allowed[from][msg.sender] - shareAmount;
+		allowed[from][msg.sender] = allowed[from][msg.sender] - amount;
```

stkADX presents an ERC-20 surface denominated in **base tokens** — `balanceOf`, `totalSupply`, `approve` and `permit` all speak ADX, while `shares` is the internal accounting unit. Allowances are therefore set in ADX, but were being decremented in shares.

For any pool that has accrued rewards, `shareValue > 1e18`, so `shareAmount = amount * 1e18 / shareValue < amount`. Every `transferFrom` consumed *less* allowance than the value it moved, by exactly the factor `shareValue / 1e18`.

**Failure scenario.** Alice approves Bob for 100 ADX. The pool has doubled, so one share is worth 2 ADX. Bob calls `transferFrom(alice, bob, 100e18)`: 50 shares (100 ADX of value) move, but only 50 is deducted from the allowance. Bob repeats and moves another 100 ADX. Bob extracts 200 ADX against a 100 ADX approval, and the multiple grows with the pool.

---

### A-02 · Medium · `transferFrom` checked the unbonding lock against the spender

**Fixed in** `8f72ed1` — *"fix: Transfer event in transferFrom"* (the commit also carried this change)

```diff
-		require(commitments[msg.sender].shareAmount == 0, "unstaking in progress");
+		require(commitments[from].shareAmount == 0, "unstaking in progress");
```

`1f8cd09` established the invariant that stkADX is non-transferable while its owner has an open unbonding commitment. `transferFrom` checked `msg.sender` — the *spender* — so the invariant was wrong in both directions:

- **False negative (lock bypass):** an owner with an open commitment could move their shares freely by approving any third party, or a contract they control, and routing through `transferFrom`. The intended lock was fully bypassable.
- **False positive (unrelated DoS):** any spender that itself held stkADX and had begun unbonding — a router, a vault, a protocol treasury — was blocked from executing `transferFrom` on behalf of *every* user, regardless of those users' own state.

---

### A-03 · Medium · `Transfer` events carried share amounts, not token amounts

**Fixed in** `8f72ed1` (`transferFrom`) and `495ee1d` (`transfer`)

```diff
-		emit Transfer(from, to, shareAmount);
+		emit Transfer(from, to, amount);
```

The rest of the ERC-20 surface is denominated in base tokens, but the events were emitting the internal share unit. Every event consumer — explorers, indexers, exchange deposit crediting, accounting, bridges — would have understated flows by the factor `shareValue / 1e18`, and reconstructed balances would never reconcile against `balanceOf`. ERC-20 requires the event value to be the number of tokens transferred.

This finding is the direct ancestor of the uncommitted change discussed in [Part 2](#part-2--the-uncommitted-transfer-event-change).

---

### A-04 · Medium · Rage-leaving could permanently brick an account with a stale commitment

**Fixed in** `be4939d` — *"some security fixes"*

```diff
+		if (commitments[msg.sender].shareAmount > shares[msg.sender]) {
+			// reset that user's committment, otherwise they end up bricked until they deposit more tokens
+			commitments[msg.sender] = UnbondCommitment({ unlocksAt: 0, tokensToReceive: 0, shareAmount: 0 });
+		}
```

`unstake()` records a commitment but does **not** escrow the shares — they stay in `shares[msg.sender]` and continue to count toward `totalShares`. `rageLeave()` was not blocked by an open commitment, so a user could burn away the shares their commitment was written against.

**Failure scenario.** Alice `unstake`s her full 100 shares, then rage-leaves all 100. `shares[alice]` is now 0 but `commitments[alice].shareAmount` is still 100. `withdraw()` reverts forever on `burnShares` underflow, and `transfer`/`transferFrom` stay permanently blocked by `"unstaking in progress"`. The account is frozen until Alice deposits at least 100 shares' worth of fresh ADX purely to clear the stuck commitment.

The fix is correct and complete for this scenario: the reset triggers exactly when the commitment can no longer be honoured.

---

### A-05 · Medium · Sub-share transfers moved nothing but still emitted a `Transfer` event

**Fixed in** `6e1fa68` — *"fix rounding errors"*

```diff
+		require(shareAmount > 0, "trying to transfer zero shares");
```

`shareAmount = amount * 1e18 / shareValue` truncates. Any `amount` smaller than the value of one share rounded to zero shares, and the call then succeeded, moved nothing, and emitted `Transfer(from, to, amount)` anyway. In `transferFrom` it also burned allowance for value that never moved.

**Failure scenario.** Any integrator that credits on `Transfer` — exchange deposits, bridges, payment processors, point systems — could be credited repeatedly for free. The amount per call is bounded by the per-share value (`shareValue / 1e18` base units), so this is a bounded rather than unlimited mint of phantom credit, which is why this is rated Medium rather than High. Event-log spam was unbounded.

> ⚠️ **This fix introduced a compliance regression** that is still present. See [N-06](#informational--no-action-required).

---

### A-06 · Medium · Pool hardcoded the ADX interface despite claiming a generic `baseToken`

**Fixed in** `7ae8466` and `59b26f1`

```diff
-		require(IADXToken(baseToken).transferFrom(msg.sender, address(this), amount));
+		require(IERC20(baseToken).transferFrom(msg.sender, address(this), amount));
```

`baseToken` is a constructor parameter and the contract is written as a generic pool, but every balance and transfer call went through `IADXToken`, which carries supply-control methods (`mint`, `supplyController`, `changeSupplyController`) that a generic base token would not implement. All plain ERC-20 interactions were moved to `IERC20`; `IADXToken` is now used only where the ADX-specific incentive mechanism is genuinely required.

---

### A-07 · Low · Infinite approvals were decremented

**Fixed in** `cb867ee` — *"do not deduct infinite approvals"*

```diff
-		allowed[from][msg.sender] = allowed[from][msg.sender] - amount;
+		uint256 prevAllowance = allowed[from][msg.sender];
+		if (prevAllowance < type(uint256).max) allowed[from][msg.sender] = prevAllowance - amount;
```

`type(uint256).max` is the near-universal sentinel for an unlimited approval; decrementing it silently converted "unlimited" into "very large but finite" and cost an extra `SSTORE` on every transfer.

---

### A-08 · Low · Inconsistent guard against transferring to the pool itself

**Fixed in** `119c3f0` — *"consistently block transfer to contract"*

`transfer` had the guard but placed it *after* the share computation; `transferFrom` had no guard at all. Both were moved to the top of the function and given a common message.

stkADX sent to the pool is unrecoverable, and because those shares remain in `totalShares`, the loss is permanent for the sender with no offsetting gain to other stakers — they simply dilute everyone forever.

---

### A-09 · Low · Allowance over-deducted by the share-rounding remainder

**Fixed in** `c534560` — *"stricter allowance deduction"*

```diff
-		if (prevAllowance < type(uint256).max) allowed[from][msg.sender] = prevAllowance - amount;
+		if (prevAllowance < type(uint256).max) allowed[from][msg.sender] = prevAllowance - (shareAmount * _shareValue) / 1e18;
```

Because `shareAmount` truncates, the value actually moved is `(shareAmount * shareValue) / 1e18 ≤ amount`. Deducting `amount` charged the spender for the truncated remainder. The fix deducts exactly the value moved.

The discrepancy is bounded above by the per-share value, so the practical impact is dust. **This is the commit the uncommitted change in Part 2 builds on.**

---

### A-10 · Low · Default `timeToUnbond` fell outside the governance-settable range

**Fixed in** `1230e9e` — *"fix defaults"*

```diff
-	uint public timeToUnbond = 20 days;
+	uint public timeToUnbond = 60 days;
...
-		require(time >= 1 days && time <= 30 days, "BOUNDS");
+		require(time >= 1 days && time <= 365 days, "BOUNDS");
```

The governance bound was `1..30 days`, so the intended 60-day unbonding period could not have been set by governance at all — the deployed default would have been unreachable and irreversible once changed. Both the default and the bound were corrected together.

---

### A-11 · Low · Base-token transfer failures reverted without a reason string

**Fixed in** `be4939d`

```diff
-		require(IADXToken(baseToken).transfer(msg.sender, receivedTokens));
+		require(IERC20(baseToken).transfer(msg.sender, receivedTokens), "base token transfer failed");
```

---

### Development-phase security hardening (not audit findings)

Three Jan-3 commits on the migrator are security-motivated but predate the audit window, so they are recorded separately:

- **`c254b26`** — *"do not give away residual amount if any"*. Added the `startAmount` delta so `migrate()` deposits only the ADX that this call actually produced. Without it, any ADX resting in the migrator could be swept by the next caller.
- **`36ede1e`** — added the migration `deadline`. The July rewrite removed the check again; migration is now permanently open at the maximum burn rate, which the author confirms is intended.
- **`f8948d7`** — added the arbitrary-`call()` escape hatch, needed because the migrator is appointed sole governance of the pool. This concentrates full pool control in `actualGovernance`; see [N-14](#informational--no-action-required).

### Process observations

**Three of the eleven remediation commits do not compile.**

- `7ae8466` renamed `totalADX` → `totalBase` in `withdraw()` but left the old identifier in the expression below it — an undefined-variable error, repaired two commits later in `cf65601`.
- `ac16dd3` wrote `commitments[msg.sender].shareAmount = UnbondCommitment({...})` — assigning a struct to a `uint` member — and used a positional field `shareAmount` in a named-argument literal. Both were repaired in `cf65601`.

Fixes were being committed without a compile step. That gap is still open — it is why [N-04](#informational--no-action-required) (the branch builds under no compiler at all) survives in the current head, and it is the single highest-leverage thing to fix about the workflow.

---

## Part 2 — The uncommitted `Transfer` event change

### What it was

```diff
 	function transferFrom(address from, address to, uint amount) external returns (bool success) {
 		...
-		if (prevAllowance < type(uint256).max) allowed[from][msg.sender] = prevAllowance - (shareAmount * _shareValue) / 1e18;
+		uint realAmount = (shareAmount * _shareValue) / 1e18;
+		if (prevAllowance < type(uint256).max) allowed[from][msg.sender] = prevAllowance - realAmount;
 		shares[to] = shares[to] + shareAmount;
-		emit Transfer(from, to, amount);
+		emit Transfer(from, to, realAmount);
 	}
```

It extracts the value already computed inline by [A-09](#a-09--low--allowance-over-deducted-by-the-share-rounding-remainder) and reuses it in the event, so that the event reports the value actually moved rather than the value requested.

### Why it was dropped

The reason given by the author, and it is the right one:

> **The emitted value should be consistent with the argument the caller passed, and consistent with what `transfer` does.**

Both halves hold up, and the first is the stronger of the two.

**1. `Transfer.value` should echo the caller's expressed intent.** `transferFrom(from, to, amount)` takes a *token amount* from the caller. Echoing that amount back in the event is what every ERC-20 integrator expects: you asked to move 100, the log says 100, and "did my transfer of X go through" is answerable by matching on the value. Emitting a silently-adjusted `realAmount` breaks that match for no benefit the caller can observe.

**2. `transfer()` would be left behind.** It is three lines above and still emits `amount`. Landing this in `transferFrom` alone makes the two functions disagree about what the third event argument means, for identical rounding behaviour — a discrepancy that reads as a bug to the next reviewer.

**3. It re-opens a line the auditor had just signed off on.** `495ee1d` and `8f72ed1` were the remediation for [A-03](#a-03--medium--transfer-events-carried-share-amounts-not-token-amounts), which is specifically about what the third argument of `Transfer` means. Changing it again after remediation review costs an auditor round for no security gain.

**4. The magnitude is dust anyway.** `amount - realAmount < shareValue / 1e18` — strictly less than the base-token value of one share, a few wei at realistic share values. Meanwhile the underlying balance drifts every second because `totalSupply()` includes `mintableIncentive()`. A rebasing balance can never be reconstructed from `Transfer` events regardless.

**What is *not* a reason:** gas. `(shareAmount * _shareValue) / 1e18` is already computed on the committed path; hoisting it into a local is neutral to slightly cheaper.

### Verdict — the decision was correct

I initially framed this as "immaterial and incomplete, so leaving it is defensible." The caller-intent argument is stronger than that: it makes the committed code **actively right**, not merely good enough.

It also dissolves an inconsistency I claimed in an earlier draft of this report. I had noted that `withdraw()` and `rageLeave()` emit `Transfer(..., currentTokens)` — computed value, not requested — and concluded that `transfer`/`transferFrom` were the odd ones out. They are not, under the rule the contract is actually following:

> **`Transfer.value` is the token amount the caller expressed, when they expressed one; otherwise the computed value.**

`withdraw()` takes no amount at all, and `rageLeave()` takes *shares* — neither caller expresses a token amount, so both must compute one. `transfer`/`transferFrom` take a token amount, so they echo it. The contract is consistent; the stashed change would have broken that consistency, not restored it.

The one genuine loose end is that [A-09](#a-09--low--allowance-over-deducted-by-the-share-rounding-remainder) deducts `realAmount` from the allowance while the event reports `amount`. Under the rule above, **A-09 is now the odd one out, not the event** — and the cleaner reconciliation would be to deduct `amount` and match the caller's intent on both. The difference is bounded by one share's value either way, so this is not worth a change on its own. Recorded as informational at [N-13](#informational--no-action-required).

### Action taken

Stashed rather than committed:

```
stash@{0}: On feature/aura-staking: stkADX: emit realAmount in transferFrom Transfer event
           (deliberately not committed - cosmetic/dust-level, incomplete: transfer() unchanged)
```

The working tree was clean before `git pull`, and the pull fast-forwarded `c534560..a7c82a9` without conflict. Upstream's only change to `StakingPool.sol` was the commented-out pragma line, so the stash still applies cleanly if you ever want it back.

---

## Part 3 — New audit pass on `a7c82a9`

The 11 pulled commits rewrote `StakingPoolMigratorGovernance.sol` (burn-ramp migration policy, new constructor) and added `HeyAuraLoginDomain.sol`. `StakingPool.sol` changed only in a comment.

### Findings

| ID | Severity | Finding | Location |
|---|---|---|---|
| [N-01](#n-01--medium--enterto-dust-permanently-blocks-a-user-from-lowering-their-unbond-time) | Medium | `enterTo` dust permanently blocks a user from lowering their unbond time | `StakingPool.sol:187-193` |
| [N-02](#n-02--low--permit-domain-separator-is-fixed-at-construction--cross-fork-replay) | Low | `permit` domain separator fixed at construction — cross-fork signature replay | `StakingPool.sol:125-134` |
| [N-03](#n-03--low--setincentive-destroys-accrued-staker-rewards) | Low | `setIncentive` destroys accrued staker rewards | `SupplyController.sol:36-43` |

Fifteen further items (N-04 – N-18) are recorded as [informational](#informational--no-action-required): design decisions confirmed with the team, closed historical issues, non-exploitable conformance and build problems, and code-quality notes. None require action.

### Scope note

This part reports defects in the code under review. Engineering-practice observations are not findings and are not reported as such; where the state of the repository limited what could be verified, that is stated as a limitation in the [appendix](#appendix--verification--limitations) instead.

An earlier draft of this review carried a Critical and three Highs. None survived scrutiny: two rested on evidence that was wrong on re-testing, several described intentional design decisions, and several were classified as vulnerabilities when they were engineering-practice or code-quality observations. The corrections are recorded in place, and the appendix records what that pattern implies about the confidence of what remains.

---

### N-01 · Medium · `enterTo` dust permanently blocks a user from lowering their unbond time

**`contracts/StakingPool.sol:187-193`**

```solidity
function enterWithUnbondTime(uint amount, uint time) external {
	require(time >= individualTimeToUnbond[msg.sender] || shares[msg.sender] == 0,
	        "you cannot reduce individual time to unbond unless you have zero stake");
```

Lowering your own unbond time requires `shares[msg.sender] == 0`. But `enterTo(address recipient, uint amount)` lets **anyone mint shares to anyone**, with no consent from the recipient.

**Failure scenario.** Alice previously set `individualTimeToUnbond` to 180 days and now wants it back at the 60-day default. She must first reach zero shares. Mallory calls `enterTo(alice, x)` with the smallest `x` that mints at least one share — a few wei of ADX plus gas — and Alice is above zero again. Mallory can repeat this indefinitely for effectively nothing. Alice's only route to zero is `rageLeave`, costing her 30% of her stake; `unstake`/`withdraw` is worse, because it takes her own 180-day period to complete and Mallory can re-grief at the end of it.

The griefer gains nothing and forfeits their dust, so this is nuisance rather than theft — but it is permissionless, effectively free, indefinitely repeatable, and the victim's cheapest escape costs 30% of their position.

**Recommendation.** Gate the reduction on state a third party cannot influence — keying it to the caller's own unbonding state rather than to a balance others can top up:

```solidity
require(time >= individualTimeToUnbond[msg.sender] || commitments[msg.sender].shareAmount == 0,
        "cannot reduce while unstaking");
```

If a zero-stake condition is genuinely wanted, track a per-user self-deposited figure that third-party `enterTo` does not increment. Separately, `time` has no upper bound — a user can set a value that makes `block.timestamp + unbondTime` overflow and permanently disable their own `unstake` path, leaving `rageLeave` as their only exit. Bound it to the same `1 days .. 365 days` range as `setTimeToUnbond`.

---

### N-02 · Low · `permit` domain separator is fixed at construction — cross-fork replay

**`contracts/StakingPool.sol:125-134`**

```solidity
constructor(IADXToken token, address governanceAddr) {
	...
	uint chainId;
	assembly { chainId := chainid() }
	DOMAIN_SEPARATOR = keccak256(abi.encode(..., chainId, address(this)));
}
```

`DOMAIN_SEPARATOR` is computed once at deployment and stored. `permit` uses that stored value forever, never re-deriving it from the current `block.chainid`.

**Failure scenario.** A chain split leaves two chains running the same bytecode at the same address, with different chain IDs. Both keep validating against the *original* chain ID, so the domain separator is identical on both. Any `permit` signature — including one already broadcast and visible on-chain — is replayable on the other chain against the same nonce. The `deadline` bounds the window but does not close it, and an unspent approval signed before the fork is valid on both sides after it.

The pool is on a single chain today and forks are rare, hence Low. But the signature is a bearer instrument, so exposure is created retroactively for signatures already issued.

**Recommendation.** `HeyAuraLoginDomain.sol:141-147`, added in this same branch, already implements the correct pattern — cache the separator, and rebuild it whenever `block.chainid` or `address(this)` has moved:

```solidity
function _domainSeparatorV4() private view returns (bytes32) {
	if (address(this) == _cachedThis && block.chainid == _cachedChainId) return _cachedDomainSeparator;
	return _buildDomainSeparator();
}
```

Adopt it in the pool. It keeps the gas saving in the common case and costs nothing until a fork actually happens.

---

### N-03 · Low · `setIncentive` destroys accrued staker rewards

**`contracts/SupplyController.sol:36-43`**

```solidity
function setIncentive(address addr, uint amountPerSecond) external {
	require(governance[msg.sender] >= uint8(GovernanceLevel.All), "NOT_GOVERNANCE");
	require(amountPerSecond < 1e18, "AMOUNT_TOO_LARGE");
	incentiveLastMint[addr] = block.timestamp;   // clock reset...
	incentivePerSecond[addr] = amountPerSecond;  // ...but nothing minted
	// AUDIT: pending incentive lost here
}
```

The auditor's own comment, still unanswered in shipped code.

Incentive accrues as `(block.timestamp - incentiveLastMint[addr]) * incentivePerSecond[addr]`. `mintIncentive` mints that amount and resets the clock. `setIncentive` resets the clock **without minting first**, so everything accrued since the last `mintIncentive` is destroyed — never minted, unrecoverable.

**Magnitude.** `amountPerSecond` is capped at 1 ADX/sec. At a rate of 0.1 ADX/sec with 30 days since the last mint, a single rate change silently burns ~259,200 ADX of staker rewards; the ceiling over a 30-day gap is ~2.59M ADX.

**Who bears it.** Those rewards belong to stakers, not to the caller. `StakingPool.totalSupply()` includes `mintableIncentive(address(this))`, so `shareValue()` and every holder's `balanceOf` step down in the same block by the destroyed amount.

Note this is *only* destruction of accrued rewards, not a pricing exploit. Deposits are not mispriced: `innerEnter` calls `mintIncentive` before reading `IERC20(baseToken).balanceOf(address(this))`, so entrants are always priced off the real balance rather than the `totalSupply()` figure that carries the pending term.

**Why this survives the trust model.** Governance being trusted means trusted not to act maliciously; it does not mean trusted never to adjust an incentive rate. Adjusting the rate is a routine operation, the loss lands on users rather than on the party being trusted, there is no warning and no recovery, and the obvious way to perform the operation is the one that triggers it.

**Recommendation.** Call `mintIncentive(addr)` at the top of `setIncentive`, before touching `incentiveLastMint`. `mintIncentive` is already permissionless, so as an interim operational measure it can simply be called first in the same transaction.

---

## Informational — no action required

**N-04 · Compiler version is unpinned, and the branch does not build under its own config.** Every in-scope file except `HeyAuraLoginDomain.sol` has its `pragma` commented out. `StakingPool` omits `override` specifiers, legal only from 0.8.8, but `truffle-config.js:153` pins 0.8.7 and `HeyAuraLoginDomain.sol:2` pins 0.8.7 exactly — no single version satisfies both, so `npx truffle compile` fails on this branch and the deployed bytecode cannot be reproduced from this tree. Not exploitable: 0.7.5 and 0.7.6 also reject these sources on the same missing `override`, so there is no compiler that both accepts them and has unchecked arithmetic. Fix is `pragma solidity ^0.8.8;` in each file plus a config bump.

**N-05 · Migrator constructor mixes absolute and relative time, and validates nothing.** `_customGracePeriod` is an absolute timestamp while `_customDeadline` — the adjacent parameter, immediately before it — is a duration, and both defaults are written as durations. Passing `32 days` for the grace period puts it in 1970, making every migration burn the full `maxPromillesToBurn` from day one with no grace period and no setter to correct it. `_defaultMaxPromillesToBurn` is unbounded; above 1000 it underflows every post-grace migration. Requires a trusted deployer to pass wrong arguments, so this is a deployment-safety note rather than a vulnerability — assert the resulting values in the deploy script.

**N-06 · Zero-value transfers revert (ERC-20 conformance).** `amount == 0` gives `shareAmount == 0`, so the [A-05](#a-05--medium--sub-share-transfers-moved-nothing-but-still-emitted-a-transfer-event) guard makes `transfer(to, 0)` and `transferFrom(from, to, 0)` revert, against an explicit spec requirement that they be treated as normal transfers. The contract declares `is IERC20`, so this is a real deviation, but it risks nothing in the pool — it can only break an integrator that performs zero-value transfers. `if (amount == 0) { emit Transfer(msg.sender, to, 0); return true; }` restores conformance without weakening A-05.

**N-07 · Migration unlocks staged v1 unbonds, leaving v1 lock state stale.** `migrate()` pulls with `transferFrom`, which in v1 does not subtract `lockedShares`, so stake staged for a pending `leave()` migrates too. This is intended: `lockedShares` is stake already on its way out, and migrating it delivers that value early and unencumbered. No double-claim is possible — `innerBurn` decrements `balances`, which the migration has already debited, so `withdraw` reverts exactly when it would double-count. The residue is stale bookkeeping: v1 `commitments` and `lockedShares` persist as records of value already delivered, which `scripts/tomPendingToLeave.js` (it reads `LogLeave` plus `lockedShares`) will over-count for every migrator who had an unbond in flight. Adjust that reconciliation; no contract change. *This item was filed twice during review and withdrawn twice — first as a Critical claiming unit confusion between `transferFrom` and `rageLeave`, which is wrong because the v1 pool is share-denominated 1:1 (`balances` holds shares, `transferFrom` moves them directly with no `shareValue` conversion); then as a Medium claiming the un-migrated remainder was stranded, which is wrong because neither `rageLeave` nor a repeat `migrate()` consults `lockedShares`.*

**N-08 · First-depositor share inflation — window closed in practice.** `innerEnter` has no `require(newShares > 0)`, so against an *unseeded* pool an attacker could `enter(1)` to take the `totalShares == 0` branch, donate a large amount by plain transfer to make one share worth everything, and then absorb the next depositor's stake entirely (`newShares = amount * 1 / totalADX = 0` mints nothing, but the ADX is still pulled). The pool is already deployed and was seeded with a substantial stake early, so the `totalShares == 0` branch is no longer reachable and this is historical. Retain as a **deployment requirement for any future pool**: seed atomically with deployment, and add `require(newShares > 0, "zero shares minted")` as a one-line guard. Note `SupplyController.mintIncentive` is permissionless and mints directly into the pool, which is a second donation channel into the same denominator.

**N-09 · Both pools are caller-supplied and trusted by assumption.** `migrate()` takes `oldPool` and `newPool` as unvalidated parameters, leaves a standing `token.approve(newPool, ...)` that is never reset, and reaches them through an `IStakingPool` whose `baseToken()` and `rageReceivedPromilles()` are declared non-`view` and therefore compile to `CALL` rather than `STATICCALL`. Both pools are trusted, which closes this. One recommendation survives on other grounds: pinning them as `immutable` constructor arguments also prevents this migrator being pointed at a v2-style pool, where the share/token unit equivalence that makes the current code correct no longer holds.

**N-10 · The burn is a transfer to `address(0)`, by design.** `token.transfer(address(0), amountToBurn)` works because `ADXToken` has no zero-address guard, and this is the intended mechanism. Recorded for the accounting consequence only: it does not reduce `ADXToken.totalSupply`, and `ADXSupplyController.innerMint` credits burns at `0x23C2c34f38ce66ccC10E71e9bB2A06532D52C5E9`, not `address(0)` — so these tokens stay counted against the cap while being unspendable, tightening future mint headroom for staking incentives. Worth confirming that is priced in.

**N-11 · Deposits have no `skipMint`, by design.** `unstake`, `withdraw` and `rageLeave` take `skipMint`; `enter` / `enterTo` / `enterWithUnbondTime` do not, because the escape hatch is deliberately for getting funds out. Recorded for one second-order effect that is not about escape hatches: `StakingPool.totalSupply()` adds `mintableIncentive(address(this))`, which keeps accruing whether or not it can still be minted. Past the ADX cap, `shareValue()` and `balanceOf()` would inflate without bound while redeemable ADX stays fixed, since `withdraw` and `rageLeave` pay from the real balance. Capping that term at what the supply controller can actually mint would keep the displayed balance honest.

**N-12 · Unchecked ERC-20 return values in the migrator.** `transferFrom`, `approve` and `transfer` discard their `bool` at `StakingPoolMigratorGovernance.sol:42,77,80`. `ADXToken` reverts rather than returning `false`, and ADX is the only base token, so this is not reachable. Noted only because `StakingPool.sol` is disciplined about it (the A-11 fix) and the migrator is not.

**N-13 · Allowance deduction and `Transfer` event disagree by the rounding remainder.** `transferFrom` deducts `(shareAmount * _shareValue) / 1e18` from the allowance ([A-09](#a-09--low--allowance-over-deducted-by-the-share-rounding-remainder)) but emits the caller's `amount`. Emitting `amount` is correct — it echoes the caller's expressed intent, which is what ERC-20 consumers match on, and it is what `transfer` does. Under that rule A-09 is the inconsistent one. The gap is bounded by one share's value either way. Full reasoning in [Part 2](#part-2--the-uncommitted-transfer-event-change).

**N-14 · Governance bounds and the leftover `// AUDIT:` comment.** `setRageReceived` has no lower bound — `StakingPool.sol:143` still carries the auditor's unanswered *"should there be a minimum here?"* — so governance can set it to 0 and make `rageLeave` pay nothing, and `setGovernance` is single-step with no zero-address check. Governance is trusted, so this is a trust assumption rather than a vulnerability. Worth resolving the comment either way, since it reads as an open question in shipped code.

**N-15 · heyAura login signatures rely entirely on offchain replay protection.** `LoginInfo` carries no nonce and no numeric expiry — `requestedAt` is a free-form `string` — and the contract holds no replay state, `hashLoginInfo` being a pure hashing helper. This is by design, but it means a captured signature is a permanent bearer credential unless the backend enforces both single-use and a freshness window. The domain binding itself is correct: `verifyingContract` and `chainId` pin signatures to this deployment and chain. Adding `uint256 nonce` and `uint256 expiresAt` to the typehash would let the backend enforce both from signed data rather than an unsigned string.

**N-16 · `HeyAuraLoginDomain` ownership is vestigial.** The contract carries a full two-step `Ownable` — `_owner`, `_pendingOwner`, `transferOwnership`, `acceptOwnership`, disabled `renounceOwnership`, an `onlyOwner` modifier — and **no function is gated by it** except `transferOwnership` itself. Neither `eip712Domain()` nor `hashLoginInfo()` reads `_owner`; the tests confirm it ("keeps the domain and digest unchanged after ownership transfer"). Its only effect is on the deployment address, since `initialOwner` is part of the ERC-2470 CREATE2 salt input. Harmless, but it advertises authority that does not exist — worth a NatSpec line.

**N-17 · Scope and licensing.** `HeyAuraLoginDomain` is an EIP-712 login anchor for an AI assistant, unrelated to AdEx staking, licensed **MIT** where the rest of `contracts/` is **AGPL-3.0**. Landing it on `feature/aura-staking` means approving the staking migration implicitly approves it, and vice versa. Worth its own branch next time; confirm the licence divergence is deliberate.

**N-18 · Gas.** `this.shareValue()` and `this.totalSupply()` (`StakingPool.sol:27,37,48,156`) are external self-calls — a full `CALL` where an internal one would do, paid on every `balanceOf` read and every transfer; note `transfer()` also fails to cache the result the way `transferFrom` does in `_shareValue`. `gracePeriod`, `deadline` and `maxPromillesToBurn` (`StakingPoolMigratorGovernance.sol:10-12`) are written once with no setters but are plain storage; `immutable` removes three `SLOAD`s per `migrate()` and stops them reading as configurable. `StakingPoolMigratorGovernance.sol:79-81` has tab indentation inside a space-indented file.

---

## Recommended order of work

1. **[N-03](#n-03--low--setincentive-destroys-accrued-staker-rewards)** — one line, and it prevents a routine governance action from silently burning staker rewards. Until it lands, call `mintIncentive(pool)` in the same transaction as any `setIncentive`.
2. **[N-01](#n-01--medium--enterto-dust-permanently-blocks-a-user-from-lowering-their-unbond-time)** — the only Medium, and the only defect a third party can trigger against another user.
3. **[N-02](#n-02--low--permit-domain-separator-is-fixed-at-construction--cross-fork-replay)** — adopt the pattern `HeyAuraLoginDomain` already uses in this same branch.
4. Informational items as convenient. Two are worth doing opportunistically: N-04 (restore the pragmas) because it is five minutes and makes the tree buildable again, and N-08's one-line `require(newShares > 0)` before any *future* pool deployment.

---

## Appendix — verification & limitations

Compiler behaviour (N-04) was verified by compiling the in-scope sources through `solc-js` standard JSON at pinned remote versions, **each set in isolation**:

| Compiler | Staking contracts | `HeyAuraLoginDomain` |
|---|---|---|
| 0.7.5 / 0.7.6 | rejected — missing `override` | rejected (pragma) |
| 0.8.7 (pinned in `truffle-config.js`) | rejected — 13 × missing `override` | accepted |
| 0.8.8 | clean | rejected (pragma) |

Isolation matters: compiling both sets together produces a misleading result, because a `ParserError` in any source aborts the run at parse stage and suppresses type-level errors for every other file. An earlier draft rated the missing pragmas High on exactly that artifact, believing the contracts compiled silently under 0.7.x with unchecked arithmetic; they do not.

`npx truffle compile` could not be run against the repository directly — `node_modules` is not installed and `truffle-config.js` fails to load without `@truffle/hdwallet-provider`.

N-07 was checked against the deployed pool's source (`git show master:contracts/StakingPool.sol`), which established that the v1 ERC-20 surface is share-denominated 1:1.

**Limitation.** Every other finding was derived by reading the sources at `a7c82a9`; **none was validated by execution.** No usable harness exists to do so: `test/TestStakingPool.js` targets an API deleted in `43a352f` (`leave`, `claim`, `penalize`, `setGuardian`, `setDailyPenaltyMax`), `StakingMigratorGovernance` has no tests, and the tree does not compile under its pinned config (N-04). This is a constraint on this review's confidence, not a defect in the code under audit.

That constraint is load-bearing. Of 22 items in the first draft, one Critical, three Highs and several Mediums were withdrawn — some as intentional design, some as engineering-practice observations misfiled as vulnerabilities, two because the underlying evidence was wrong on re-testing. The claims that survived are those checkable by static reading; those that failed were assertions about runtime behaviour. **Any claim here that asserts a revert, a loss, or a griefing path should be made executable before it is acted on.**
