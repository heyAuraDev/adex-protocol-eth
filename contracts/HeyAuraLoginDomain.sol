// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

/// @title heyAura EIP-712 login signing domain
/// @notice Anchors the immutable heyAura login domain used by offchain signature validation.
contract HeyAuraLoginDomain {
    string public constant EIP712_NAME = "heyAura AI Assistant";
    string public constant EIP712_VERSION = "1";

    bytes32 public constant LOGIN_INFO_TYPEHASH =
        keccak256(
            "LoginInfo(address wallet,string purpose,string requestedAt)"
        );

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 private constant _EIP712_NAME_HASH =
        keccak256(bytes(EIP712_NAME));
    bytes32 private constant _EIP712_VERSION_HASH =
        keccak256(bytes(EIP712_VERSION));

    struct LoginInfo {
        address wallet;
        string purpose;
        string requestedAt;
    }

    address private _owner;
    address private _pendingOwner;

    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;
    address private immutable _cachedThis;

    event OwnershipTransferStarted(
        address indexed previousOwner,
        address indexed newOwner
    );
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event EIP712DomainChanged();

    modifier onlyOwner() {
        require(msg.sender == _owner, "ONLY_OWNER");
        _;
    }

    constructor(address initialOwner) {
        require(initialOwner != address(0), "INVALID_OWNER");

        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
        _cachedThis = address(this);
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function pendingOwner() external view returns (address) {
        return _pendingOwner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        // A zero pending owner cancels an unaccepted transfer without changing ownership.
        // slither-disable-next-line missing-zero-check
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == _pendingOwner, "ONLY_PENDING_OWNER");

        address previousOwner = _owner;
        _owner = msg.sender;
        delete _pendingOwner;

        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    function renounceOwnership() external pure {
        revert("OWNERSHIP_RENOUNCE_DISABLED");
    }

    /// @notice Returns the immutable signing domain in the ERC-5267 format.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f",
            EIP712_NAME,
            EIP712_VERSION,
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    function hashLoginInfo(LoginInfo calldata loginInfo)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                LOGIN_INFO_TYPEHASH,
                loginInfo.wallet,
                keccak256(bytes(loginInfo.purpose)),
                keccak256(bytes(loginInfo.requestedAt))
            )
        );

        return
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    _domainSeparatorV4(),
                    structHash
                )
            );
    }

    function _domainSeparatorV4() private view returns (bytes32) {
        if (address(this) == _cachedThis && block.chainid == _cachedChainId) {
            return _cachedDomainSeparator;
        }

        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _EIP712_DOMAIN_TYPEHASH,
                    _EIP712_NAME_HASH,
                    _EIP712_VERSION_HASH,
                    block.chainid,
                    address(this)
                )
            );
    }
}
