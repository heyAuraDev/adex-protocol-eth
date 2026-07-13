const { ContractFactory } = require('ethers')
const { expectRevert } = require('@openzeppelin/test-helpers')
const { _TypedDataEncoder, getCreate2Address, hexZeroPad, id, keccak256 } = require('ethers').utils

const HeyAuraLoginDomain = artifacts.require('HeyAuraLoginDomain')

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
const ZERO_BYTES32 = `0x${'00'.repeat(32)}`
const SINGLETON_FACTORY = '0xce0042B868300000d44A59004Da54A005ffdcf9f'
const EIP712_NAME = 'heyAura AI Assistant'
const EIP712_VERSION = '1'
const LOGIN_INFO_TYPE = 'LoginInfo(address wallet,string purpose,string requestedAt)'
const LOGIN_INFO_TYPES = {
	LoginInfo: [
		{ name: 'wallet', type: 'address' },
		{ name: 'purpose', type: 'string' },
		{ name: 'requestedAt', type: 'string' }
	]
}

contract('HeyAuraLoginDomain', function(accounts) {
	const deployer = accounts[0]
	const initialOwner = accounts[1]
	const nextOwner = accounts[2]
	const otherAccount = accounts[3]

	let chainId
	let domain

	before(async function() {
		chainId = Number(await web3.eth.getChainId())
	})

	beforeEach(async function() {
		domain = await HeyAuraLoginDomain.new(initialOwner, { from: deployer })
	})

	it('rejects a zero initial owner', async function() {
		await expectRevert(HeyAuraLoginDomain.new(ZERO_ADDRESS, { from: deployer }), 'INVALID_OWNER')
	})

	it('sets the explicit owner instead of the deployer', async function() {
		assert.notEqual(initialOwner, deployer)
		assert.equal(await domain.owner(), initialOwner)
		assert.equal(await domain.pendingOwner(), ZERO_ADDRESS)
	})

	it('requires the pending owner to accept an ownership transfer', async function() {
		await expectRevert(domain.transferOwnership(nextOwner, { from: otherAccount }), 'ONLY_OWNER')

		await domain.transferOwnership(nextOwner, { from: initialOwner })

		assert.equal(await domain.owner(), initialOwner)
		assert.equal(await domain.pendingOwner(), nextOwner)
		await expectRevert(domain.acceptOwnership({ from: otherAccount }), 'ONLY_PENDING_OWNER')

		await domain.acceptOwnership({ from: nextOwner })

		assert.equal(await domain.owner(), nextOwner)
		assert.equal(await domain.pendingOwner(), ZERO_ADDRESS)
	})

	it('allows the owner to cancel a pending ownership transfer', async function() {
		await domain.transferOwnership(nextOwner, { from: initialOwner })
		await domain.transferOwnership(ZERO_ADDRESS, { from: initialOwner })

		assert.equal(await domain.owner(), initialOwner)
		assert.equal(await domain.pendingOwner(), ZERO_ADDRESS)
		await expectRevert(domain.acceptOwnership({ from: nextOwner }), 'ONLY_PENDING_OWNER')
	})

	it('rejects ownership renunciation', async function() {
		await expectRevert(
			domain.renounceOwnership({ from: initialOwner }),
			'OWNERSHIP_RENOUNCE_DISABLED'
		)
	})

	it('reports the fixed EIP-712 domain through ERC-5267', async function() {
		const result = await domain.eip712Domain()

		assert.equal(result.fields, '0x0f')
		assert.equal(result.name, EIP712_NAME)
		assert.equal(result.version, EIP712_VERSION)
		assert.equal(result.chainId.toString(), chainId.toString())
		assert.equal(result.verifyingContract, domain.address)
		assert.equal(result.salt, ZERO_BYTES32)
		assert.equal(result.extensions.length, 0)
	})

	it('exposes the exact LoginInfo type hash', async function() {
		assert.equal(await domain.LOGIN_INFO_TYPEHASH(), id(LOGIN_INFO_TYPE))
	})

	it('matches an independently encoded EIP-712 LoginInfo digest', async function() {
		const message = {
			wallet: accounts[4],
			purpose: 'Wallet login verification',
			requestedAt: '2026-07-10T10:15:30.000Z'
		}
		const expected = _TypedDataEncoder.hash(
			{
				name: EIP712_NAME,
				version: EIP712_VERSION,
				chainId,
				verifyingContract: domain.address
			},
			LOGIN_INFO_TYPES,
			message
		)

		const actual = await domain.hashLoginInfo([
			message.wallet,
			message.purpose,
			message.requestedAt
		])

		assert.equal(actual, expected)
	})

	it('keeps the domain and digest unchanged after ownership transfer', async function() {
		const message = [accounts[4], 'Wallet login verification', '2026-07-10T10:15:30.000Z']
		const domainBefore = await domain.eip712Domain()
		const digestBefore = await domain.hashLoginInfo(message)

		await domain.transferOwnership(nextOwner, { from: initialOwner })
		await domain.acceptOwnership({ from: nextOwner })

		const domainAfter = await domain.eip712Domain()
		const digestAfter = await domain.hashLoginInfo(message)

		assert.equal(domainAfter.name, domainBefore.name)
		assert.equal(domainAfter.version, domainBefore.version)
		assert.equal(domainAfter.chainId.toString(), domainBefore.chainId.toString())
		assert.equal(domainAfter.verifyingContract, domainBefore.verifyingContract)
		assert.equal(digestAfter, digestBefore)
	})

	it('makes the ERC-2470 address depend on the explicit initial owner', async function() {
		const factory = new ContractFactory(HeyAuraLoginDomain.abi, HeyAuraLoginDomain.bytecode)
		const initCode = factory.getDeployTransaction(initialOwner).data
		const otherInitCode = factory.getDeployTransaction(nextOwner).data
		const predictedAddress = getCreate2Address(SINGLETON_FACTORY, ZERO_BYTES32, keccak256(initCode))
		const otherPredictedAddress = getCreate2Address(
			SINGLETON_FACTORY,
			ZERO_BYTES32,
			keccak256(otherInitCode)
		)

		assert.isTrue(
			initCode.toLowerCase().endsWith(
				hexZeroPad(initialOwner, 32)
					.slice(2)
					.toLowerCase()
			)
		)
		assert.notEqual(keccak256(initCode), keccak256(otherInitCode))
		assert.notEqual(predictedAddress, otherPredictedAddress)
	})
})
