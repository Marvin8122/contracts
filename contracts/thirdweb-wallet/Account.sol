// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

////////// Interface //////////
import "./interface/IAccount.sol";

////////// Utils //////////

import "../extension/Multicall.sol";
import "../extension/PermissionsEnumerable.sol";
import "../openzeppelin-presets/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

////////// NOTE(S) //////////
/**
 *  - The Account can have many Signers.
 *  - There are two kinds of signers: `Admin`s and `Operator`s.
 *
 *    Each `Admin` can:
 *      - Perform any transaction / action on this account with 1/n approval.
 *      - Add signers or remove existing signers.
 *      - Approve a particular smart contract call (i.e. fn signature + contract address) for an `Operator`.
 *
 *    Each `Operator` can:
 *      - Perform smart contract calls it is approved for (i.e. wherever Operator => (fn signature + contract address) => TRUE).
 *
 *  - The Account can:
 *      - Deploy smart contracts.
 *      - Send native tokens.
 *      - Call smart contracts.
 *      - Sign messages. (EIP-1271)
 *      - Own and transfer assets. (ERC-20/721/1155)
 */

interface ISignerTracker {
    function addSignerToAccount(address signer, bytes32 accountId) external;

    function removeSignerToAccount(address signer, bytes32 accountId) external;
}

contract Account is
    IAccount,
    Initializable,
    EIP712Upgradeable,
    Multicall,
    ERC2771ContextUpgradeable,
    PermissionsEnumerable
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using ECDSAUpgradeable for bytes32;

    /*///////////////////////////////////////////////////////////////
                            Constants
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER");

    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    bytes32 private constant EXECUTE_TYPEHASH =
        keccak256(
            "TransactionParams(address signer,address target,bytes data,uint256 nonce,uint256 value,uint256 gas,uint128 validityStartTimestamp,uint128 validityEndTimestamp)"
        );

    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/

    /// @notice The admin smart contract of the account.
    address public controller;

    /// @notice The nonce of the account.
    uint256 public nonce;

    /// @notice Mapping from Signer => CallTargets approved (at least once).
    mapping(address => CallTarget[]) private callTargets;

    /// @notice Mapping from Signer => contracts approved to call.
    mapping(address => EnumerableSet.AddressSet) private approvedContracts;

    /// @notice Mapping from Signer => functions approved to call.
    mapping(address => EnumerableSet.Bytes32Set) private approvedFunctions;

    /// @notice  Mapping from Signer => (fn sig, contract address) => approval to call.
    mapping(address => mapping(bytes32 => bool)) private isApprovedFor;

    /// @notice  Mapping from Signer => contract address => approval to call.
    mapping(address => mapping(address => bool)) private isApprovedForContract;

    /// @notice  Mapping from Signer => function signature => approval to call.
    mapping(address => mapping(bytes4 => bool)) private isApprovedForFunction;

    /*///////////////////////////////////////////////////////////////
                    Constructor + initializer
    //////////////////////////////////////////////////////////////*/

    constructor() {}

    function initialize(
        address[] memory _trustedForwarders,
        address _controller,
        address _signer
    ) external payable initializer {
        __EIP712_init("thirdweb_wallet", "1");
        __ERC2771Context_init(_trustedForwarders);

        controller = _controller;
        _setupRole(DEFAULT_ADMIN_ROLE, _signer);

        emit AdminAdded(_signer);
    }

    /*///////////////////////////////////////////////////////////////
                                Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Checks whether the caller is self.
    modifier onlySelf() {
        require(_msgSender() == address(this), "Account: caller not self.");
        _;
    }

    /*///////////////////////////////////////////////////////////////
                        Receive native tokens.
    //////////////////////////////////////////////////////////////*/

    /// @notice Lets this contract receive native tokens.
    receive() external payable {}

    /*///////////////////////////////////////////////////////////////
     Execute a transaction. Send native tokens, call smart contracts
    //////////////////////////////////////////////////////////////*/

    /// @notice Perform transactions; send native tokens or call a smart contract.
    function execute(TransactionParams calldata _params, bytes calldata _signature)
        external
        payable
        returns (bool success)
    {
        _validateCallConditions(
            _params.nonce,
            _params.value,
            _params.validityStartTimestamp,
            _params.validityEndTimestamp
        );
        _validateSignature(_params, _signature);
        _validatePermissions(_params.signer, _params.target, _params.data);

        success = _call(_params);

        emit TransactionExecuted(
            _params.signer,
            _params.target,
            _params.data,
            _params.nonce,
            _params.value,
            _params.gas
        );
    }

    /*///////////////////////////////////////////////////////////////
                        Deploy smart contracts.
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys a smart contract.
    function deploy(
        bytes calldata _bytecode,
        bytes32 _salt,
        uint256 _value
    ) external payable onlySelf returns (address deployment) {
        bytes32 safeSalt = keccak256(abi.encode(_salt, tx.origin));
        deployment = Create2.deploy(_value, safeSalt, _bytecode);
        emit ContractDeployed(deployment);
    }

    /*///////////////////////////////////////////////////////////////
                Change signer composition to the account.
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds an admin to the account.
    function addAdmin(address _signer, bytes32 _accountId) external onlySelf {
        require(!hasRole(DEFAULT_ADMIN_ROLE, _signer), "Account: admin already exists.");
        _setupRole(DEFAULT_ADMIN_ROLE, _signer);
        emit AdminAdded(_signer);

        try ISignerTracker(controller).addSignerToAccount(_signer, _accountId) {} catch {}
    }

    /// @notice Removes an admin from the account.
    function removeAdmin(address _signer, bytes32 _accountId) external onlySelf {
        require(hasRole(DEFAULT_ADMIN_ROLE, _signer), "Account: admin already does not exist.");
        _revokeRole(DEFAULT_ADMIN_ROLE, _signer);
        emit AdminRemoved(_signer);

        try ISignerTracker(controller).removeSignerToAccount(_signer, _accountId) {} catch {}
    }

    /// @notice Adds a signer to the account.
    function addSigner(address _signer, bytes32 _accountId) external onlySelf {
        require(!hasRole(SIGNER_ROLE, _signer), "Account: signer already exists.");
        _setupRole(SIGNER_ROLE, _signer);
        emit SignerAdded(_signer);

        try ISignerTracker(controller).addSignerToAccount(_signer, _accountId) {} catch {}
    }

    /// @notice Removes a signer from the account.
    function removeSigner(address _signer, bytes32 _accountId) external onlySelf {
        require(hasRole(SIGNER_ROLE, _signer), "Account: signer already does not exist.");
        _revokeRole(SIGNER_ROLE, _signer);
        emit SignerRemoved(_signer);

        try ISignerTracker(controller).removeSignerToAccount(_signer, _accountId) {} catch {}
    }

    /*///////////////////////////////////////////////////////////////
        Override permission functions without AccountAdmin callback
    //////////////////////////////////////////////////////////////*/

    function grantRole(bytes32, address) public virtual override(IPermissions, Permissions) {
        _permissionsRevert();
    }

    function revokeRole(bytes32, address) public virtual override(IPermissions, Permissions) {
        _permissionsRevert();
    }

    function renounceRole(bytes32, address) public virtual override(IPermissions, Permissions) {
        _permissionsRevert();
    }

    function _permissionsRevert() private pure {
        revert("Account: cannot directly change permissions.");
    }

    /*///////////////////////////////////////////////////////////////
            Approve non-admin signers for function calls.
    //////////////////////////////////////////////////////////////*/

    /// @notice Approves a signer to be able to call `_selector` function on `_target` smart contract.
    function approveSignerForTarget(
        address _signer,
        bytes4 _selector,
        address _target
    ) external onlySelf {
        bytes32 targetHash = keccak256(abi.encode(_selector, _target));
        bool currentApproval = isApprovedFor[_signer][targetHash];

        require(!currentApproval, "Account: already approved.");

        isApprovedFor[_signer][targetHash] = true;
        callTargets[_signer].push(CallTarget(_selector, _target));

        emit TargetApprovedForSigner(_signer, _selector, _target, true);
    }

    /// @notice Approves a signer to be able to call any function on `_target` smart contract.
    function approveSignerForContract(address _signer, address _target) external onlySelf {
        require(approvedContracts[_signer].add(_target), "Account: already approved.");
        isApprovedForContract[_signer][_target] = true;

        emit ContractApprovedForSigner(_signer, _target, true);
    }

    /// @notice Approves a signer to be able to call `_selector` function on any smart contract.
    function approveSignerForFunction(address _signer, bytes4 _selector) external onlySelf {
        require(approvedFunctions[_signer].add(bytes32(_selector)), "Account: already approved.");
        isApprovedForFunction[_signer][_selector] = true;

        emit FunctionApprovedForSigner(_signer, _selector, true);
    }

    /// @notice Removes approval of a signer from being able to call `_selector` function on `_target` smart contract.
    function disapproveSignerForTarget(
        address _signer,
        bytes4 _selector,
        address _target
    ) external onlySelf {
        bytes32 targetHash = keccak256(abi.encode(_selector, _target));
        bool currentApproval = isApprovedFor[_signer][targetHash];

        require(currentApproval, "Account: already not approved.");

        isApprovedFor[_signer][targetHash] = false;

        CallTarget[] memory targets = callTargets[_signer];
        uint256 len = targets.length;

        for (uint256 i = 0; i < len; i += 1) {
            bytes32 targetHashToCheck = keccak256(abi.encode(targets[i].selector, targets[i].targetContract));
            if (targetHashToCheck == targetHash) {
                delete callTargets[_signer][i];
                break;
            }
        }

        emit TargetApprovedForSigner(_signer, _selector, _target, false);
    }

    /// @notice Disapproves a signer from being able to call arbitrary function on `_target` smart contract.
    function disapproveSignerForContract(address _signer, address _target) external onlySelf {
        require(approvedContracts[_signer].remove(_target), "Account: already not approved.");
        isApprovedForContract[_signer][_target] = false;

        emit ContractApprovedForSigner(_signer, _target, false);
    }

    /// @notice Disapproves a signer from being able to call `_selector` function on arbitrary smart contract.
    function disapproveSignerForFunction(address _signer, bytes4 _selector) external onlySelf {
        require(approvedFunctions[_signer].remove(bytes32(_selector)), "Account: already not approved.");
        isApprovedForFunction[_signer][_selector] = false;

        emit FunctionApprovedForSigner(_signer, _selector, false);
    }

    /// @notice Returns all call targets approved for a given signer.
    function getAllApprovedTargets(address _signer) external view returns (CallTarget[] memory approvedTargets) {
        CallTarget[] memory targets = callTargets[_signer];
        uint256 len = targets.length;

        uint256 count = 0;
        for (uint256 i = 0; i < len; i += 1) {
            if (targets[i].targetContract != address(0)) {
                count += 1;
            }
        }

        approvedTargets = new CallTarget[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < len; i += 1) {
            if (targets[i].targetContract != address(0)) {
                approvedTargets[idx].selector = targets[i].selector;
                approvedTargets[idx].targetContract = targets[i].targetContract;

                idx += 1;
            }
        }
    }

    /// @notice Returns all contract targets approved for a given signer.
    function getAllApprovedContracts(address _signer) external view returns (address[] memory) {
        return approvedContracts[_signer].values();
    }

    /// @notice Returns all function targets approved for a given signer.
    function getAllApprovedFunctions(address _signer) external view returns (bytes4[] memory functions) {
        uint256 len = approvedFunctions[_signer].length();
        functions = new bytes4[](len);

        for (uint256 i = 0; i < len; i += 1) {
            functions[i] = bytes4(approvedFunctions[_signer].at(i));
        }
    }

    /*///////////////////////////////////////////////////////////////
                    EIP-1271 Smart contract signatures
    //////////////////////////////////////////////////////////////*/

    /// @notice See EIP-1271. Returns whether a signature is a valid signature made on behalf of this contract.
    function isValidSignature(bytes32 _hash, bytes calldata _signature) external view override returns (bytes4) {
        address signer = _hashTypedDataV4(_hash).recover(_signature);

        // Validate signatures
        if (hasRole(SIGNER_ROLE, signer) || hasRole(DEFAULT_ADMIN_ROLE, signer)) {
            return MAGICVALUE;
        } else {
            return 0xffffffff;
        }
    }

    /*///////////////////////////////////////////////////////////////
                    Receive assets (ERC-721/1155)
    //////////////////////////////////////////////////////////////*/

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates a signature for a call to account.
    function _validateSignature(TransactionParams calldata _params, bytes calldata _signature) internal view {
        bool validSignature = false;
        {
            bytes32 messageHash = keccak256(_encodeTransactionParams(_params));

            if (_params.signer.code.length > 0) {
                validSignature = MAGICVALUE == IERC1271(_params.signer).isValidSignature(messageHash, _signature);
            } else {
                address recoveredSigner = _hashTypedDataV4(messageHash).recover(_signature);
                validSignature = _params.signer == recoveredSigner;
            }
        }

        require(validSignature, "Account: invalid signer.");
    }

    /// @dev Validates the permissions of the signer.
    function _validatePermissions(
        address _signer,
        address _target,
        bytes calldata _data
    ) internal view {
        bool hasPermissions = hasRole(DEFAULT_ADMIN_ROLE, _signer);

        if (!hasPermissions) {
            bytes32 targetHash = keccak256(abi.encode(_getSelector(_data), _target));
            hasPermissions =
                hasRole(SIGNER_ROLE, _signer) &&
                (isApprovedFor[_signer][targetHash] ||
                    isApprovedForContract[_signer][_target] ||
                    isApprovedForFunction[_signer][_getSelector(_data)]);
        }

        require(hasPermissions, "Account: unauthorized signer.");
    }

    /// @dev Validates conditions for a call to account.
    function _validateCallConditions(
        uint256 _nonce,
        uint256 _value,
        uint128 _validityStartTimestamp,
        uint128 _validityEndTimestamp
    ) internal {
        require(msg.value == _value, "Account: incorrect value sent.");
        require(
            _validityStartTimestamp <= block.timestamp && block.timestamp < _validityEndTimestamp,
            "Account: request premature or expired."
        );
        require(_nonce == nonce, "Account: incorrect nonce.");
        nonce += 1;
    }

    /// @notice See `https://ethereum.stackexchange.com/questions/111384/how-to-load-the-first-4-bytes-from-a-bytes-calldata-var`
    function _getSelector(bytes calldata data) internal pure returns (bytes4 selector) {
        assembly {
            selector := calldataload(data.offset)
        }
    }

    /// @dev Performs a call; sends native tokens or calls a smart contract.
    function _call(TransactionParams memory txParams) internal returns (bool) {
        address target = txParams.target;

        bool success;
        bytes memory result;
        if (txParams.gas > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (success, result) = target.call{ gas: txParams.gas, value: txParams.value }(txParams.data);
        } else {
            // solhint-disable-next-line avoid-low-level-calls
            (success, result) = target.call{ value: txParams.value }(txParams.data);
        }
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        return success;
    }

    function _encodeTransactionParams(TransactionParams calldata _params) private pure returns (bytes memory) {
        return
            abi.encode(
                EXECUTE_TYPEHASH,
                _params.signer,
                _params.target,
                keccak256(_params.data),
                _params.nonce,
                _params.value,
                _params.gas,
                _params.validityStartTimestamp,
                _params.validityEndTimestamp
            );
    }
}