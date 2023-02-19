// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.13;

import "forge-std/StdJson.sol";
import "forge-std/Test.sol";
import "solidity-stringutils/strings.sol";
import "era-contracts/ethereum/contracts/zksync/interfaces/IMailbox.sol";
import "era-contracts/ethereum/contracts/common/L2ContractHelper.sol";
import "era-contracts/zksync/contracts/vendor/AddressAliasHelper.sol";

///@notice This cheat codes interface is named _CheatCodes so you can use the CheatCodes interface in other testing files without errors
interface _CheatCodes {
    function ffi(string[] calldata) external returns (bytes memory);
    function envString(string calldata key) external returns (string memory value);
    function envUint(string calldata key) external returns (uint256 value);
    function parseJson(string memory json, string memory key) external returns (string memory value);
    function writeFile(string calldata, string calldata) external;
    function readFile(string calldata) external returns (string memory);
    function createFork(string calldata) external returns (uint256);
    function selectFork(uint256 forkId) external;
    function broadcast(uint256 privateKey) external;
    function allowCheatcodes(address) external;
    function addr(uint256 privateKey) external returns (address);
    function projectRoot() external view returns (string memory path);
}

contract Deployer is Test {
    using stdJson for string;
    using strings for *;

    ///@notice Addresses taken from zksync-v2-testnet/l2/system-contracts/Constants.sol
    ///@notice Cannot import due to conflicts
    IContractDeployer constant DEPLOYER_SYSTEM_CONTRACT = IContractDeployer(address(SYSTEM_CONTRACTS_OFFSET + 0x06));

    ///@notice Custom override for cheatCodes
    /* address constant HEVM_ADDRESS = address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))); */
    _CheatCodes cheatCodes = _CheatCodes(HEVM_ADDRESS);

    ///@notice Fork IDs
    uint256 public l1;
    uint256 public l2;

    ///@notice Compiler & deployment config
    string constant zksolcRepo = "https://github.com/matter-labs/zksolc-bin";
    string public projectRoot;
    string public zksolcPath;

    constructor(string memory _zksolcVersion) {
        l1 = cheatCodes.createFork("layer_1");
        ///@notice install bin compiler
        projectRoot = cheatCodes.projectRoot();
        zksolcPath = _installCompiler(_zksolcVersion);
    }

    function compileContract(string memory fileName) public returns (bytes memory bytecode) {
        ///@notice Compiles the contract using zksolc
        string[] memory cmds = new string[](3);
        cmds[0] = zksolcPath;
        cmds[1] = "--bin";
        cmds[2] = fileName;
        string memory compilerOutput = string(cheatCodes.ffi(cmds));

        ///@notice Raw compiler output includes some text as prefix which causes ffi
        ///        to default to reading as utf8 instead of bytes
        string memory utf8Bytecode = compilerOutput.toSlice().rsplit(" ".toSlice()).toString();

        ///@notice Pass stripped bytes back into ffi to parse correctly as bytes
        string[] memory echoCmds = new string[](2);
        echoCmds[0] = "echo";
        echoCmds[1] = utf8Bytecode;

        bytecode = cheatCodes.ffi(echoCmds);

        ///@notice Padd to proper length
        if (bytecode.length % 64 > 32) {
            bytes memory padding = new bytes(64 - bytecode.length % 64);
            bytecode = abi.encodePacked(padding, bytecode);
        } else if (bytecode.length % 64 < 32) {
            bytes memory padding = new bytes(32 - bytecode.length % 64);
            bytecode = abi.encodePacked(padding, bytecode);
        }
    }

    ///@notice taken from zksync-v2-testnet/l1/contracts/common/L2ContractHelper.sol
    function hashL2Bytecode(bytes memory _bytecode) internal pure returns (bytes32 hashedBytecode) {
        // Note that the length of the bytecode
        // must be provided in 32-byte words.
        require(_bytecode.length % 32 == 0, "po");

        uint256 bytecodeLenInWords = _bytecode.length / 32;
        require(bytecodeLenInWords < 2 ** 16, "pp"); // bytecode length must be less than 2^16 words
        require(bytecodeLenInWords % 2 == 1, "pr"); // bytecode length in words must be odd
        hashedBytecode = sha256(_bytecode) & 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        // Setting the version of the hash
        hashedBytecode = (hashedBytecode | bytes32(uint256(1 << 248)));
        // Setting the length
        hashedBytecode = hashedBytecode | bytes32(bytecodeLenInWords << 224);
    }

    function deployContract(string memory fileName, bytes calldata params, bool broadcast, address diamondProxy) public returns (address) {
        bytes memory bytecode = compileContract(fileName);

        bytes32 salt = bytes32(0);
        bytes32 bytecodeHash = hashL2Bytecode(bytecode);
        bytes memory encodedDeployment = abi.encodeCall(IContractDeployer.create2, (salt, bytecodeHash, params));

        ///@notice prep factoryDeps
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytecode;

        // Switch to L1
        cheatCodes.allowCheatcodes(address(this));
        cheatCodes.selectFork(l1);

        ///@notice Deploy from Layer 1
        if (broadcast) cheatCodes.broadcast(cheatCodes.envUint("PRIVATE_KEY"));
        bytes32 txHash = IMailbox(diamondProxy).requestL2Transaction(
            address(DEPLOYER_SYSTEM_CONTRACT), // address _contracts
            0, // uint256 _l2Value
            encodedDeployment, // bytes calldata _calldata
            2097152, // uint256 _ergsLimit
            800, // uint256 _l2GasPerPubdataByteLimit
            factoryDeps, // bytes[] calldata _factoryDeps
            address(this) // address _refundRecipient
        );

        ///@notice Log deployment txHash
        emit log_named_bytes32(string(abi.encodePacked("Deploying ", fileName, " in transaction ")), txHash);

        ///@notice Compute deployment address
        address deployer = cheatCodes.addr(cheatCodes.envUint("PRIVATE_KEY"));
        address deployerAlias = AddressAliasHelper.applyL1ToL2Alias(deployer);
        bytes32 paramsHash = keccak256(params);
        address contractAddress = L2ContractHelper.computeCreate2Address(deployerAlias, salt, bytecodeHash, paramsHash);

        ///@notice Log deployment address
        emit log_named_address(string(abi.encodePacked(fileName, " to be deployed to")), contractAddress);
    }

    function _installCompiler(string memory version) internal returns (string memory path) {

        ///@notice Ensure correct compiler bin is installed
        string memory os = cheatCodes.envString("OS");
        string memory arch = cheatCodes.envString("ARCH");
        string memory extension = keccak256(bytes(os)) == keccak256(bytes("win32")) ? "exe" : "";

        ///@notice Get toolchain
        string memory toolchain = "";
        if (keccak256(bytes(os)) == keccak256(bytes("win32"))) {
            toolchain = "-gnu";
        }else if (keccak256(bytes(os)) ==keccak256(bytes( "linux"))) {
            toolchain = "-musl";
        }

        ///@notice Construct urls/paths
        string memory fileName = string(abi.encodePacked("zksolc-", os, "-", arch, toolchain, "-v", version, extension));
        string memory zksolcUrl =
            string(abi.encodePacked(zksolcRepo, "/raw/main/", os, "-", arch, "/", fileName));
        path = string(abi.encodePacked(projectRoot, "/lib/", fileName));


        ///@notice Download zksolc compiler bin
        string[] memory curl_cmds = new string[](6);
        curl_cmds[0] = "curl";
        curl_cmds[1] = "-L";
        curl_cmds[2] = zksolcUrl;
        curl_cmds[3] = "--output";
        curl_cmds[4] = path;
        curl_cmds[5] = "--silent";
        cheatCodes.ffi(curl_cmds);

        ///@notice set correct file permissions
        string[] memory chmod_cmds = new string[](3);
        chmod_cmds[0] = "chmod";
        chmod_cmds[1] = "+x";
        chmod_cmds[2] = path;
        cheatCodes.ffi(chmod_cmds);
    }
}