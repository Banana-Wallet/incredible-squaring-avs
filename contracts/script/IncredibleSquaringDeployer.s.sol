// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import "@eigenlayer/contracts/permissions/PauserRegistry.sol";
import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager, IStrategy} from "@eigenlayer/contracts/interfaces/IStrategyManager.sol";
import {ISlasher} from "@eigenlayer/contracts/interfaces/ISlasher.sol";
import {StrategyBaseTVLLimits} from "@eigenlayer/contracts/strategies/StrategyBaseTVLLimits.sol";
import "@eigenlayer/test/mocks/EmptyContract.sol";

import "@eigenlayer-middleware/src/experimental/ECDSARegistryCoordinator.sol" as regcoord;
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/experimental/ECDSAStakeRegistry.sol";
import {ECDSAIndexRegistry} from "@eigenlayer-middleware/src/experimental/ECDSAIndexRegistry.sol";
import {ECDSAOperatorStateRetriever} from "@eigenlayer-middleware/src/experimental/ECDSAOperatorStateRetriever.sol";

import {IncredibleSquaringServiceManager, IServiceManager} from "../src/IncredibleSquaringServiceManager.sol";
import {IncredibleSquaringTaskManager} from "../src/IncredibleSquaringTaskManager.sol";
import {IIncredibleSquaringTaskManager} from "../src/IIncredibleSquaringTaskManager.sol";
import "../src/ERC20Mock.sol";

import {Utils} from "./utils/Utils.sol";

import "forge-std/Test.sol";
import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";

// # To deploy and verify our contract
// forge script script/IncredibleSquaringDeployer.s.sol:IncredibleSquaringDeployer --rpc-url $RPC_URL  --private-key $PRIVATE_KEY --broadcast -vvvv
contract IncredibleSquaringDeployer is Script, Utils {
    // DEPLOYMENT CONSTANTS
    uint256 public constant QUORUM_THRESHOLD_PERCENTAGE = 100;
    uint32 public constant TASK_RESPONSE_WINDOW_BLOCK = 30;
    uint32 public constant TASK_DURATION_BLOCKS = 0;
    // TODO: right now hardcoding these (this address is anvil's default address 9)
    address public constant AGGREGATOR_ADDR =
        0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;
    address public constant TASK_GENERATOR_ADDR =
        0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;

    // ERC20 and Strategy: we need to deploy this erc20, create a strategy for it, and whitelist this strategy in the strategymanager

    ERC20Mock public erc20Mock;
    StrategyBaseTVLLimits public erc20MockStrategy;

    // Credible Squaring contracts
    ProxyAdmin public incredibleSquaringProxyAdmin;
    PauserRegistry public incredibleSquaringPauserReg;

    regcoord.ECDSARegistryCoordinator public registryCoordinator;
    regcoord.ECDSARegistryCoordinator public registryCoordinatorImplementation;

    ECDSAStakeRegistry public stakeRegistry;
    ECDSAStakeRegistry public stakeRegistryImplementation;

    ECDSAIndexRegistry public indexRegistry;
    ECDSAIndexRegistry public indexRegistryImplementation;

    ECDSAOperatorStateRetriever public operatorStateRetriever;

    IncredibleSquaringServiceManager public incredibleSquaringServiceManager;
    IServiceManager public incredibleSquaringServiceManagerImplementation;

    IncredibleSquaringTaskManager public incredibleSquaringTaskManager;
    IIncredibleSquaringTaskManager
        public incredibleSquaringTaskManagerImplementation;

    function run() external {
        // Eigenlayer contracts
        string memory eigenlayerDeployedContracts = readOutput(
            "eigenlayer_deployment_output"
        );
        IStrategyManager strategyManager = IStrategyManager(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.strategyManager"
            )
        );
        IDelegationManager delegationManager = IDelegationManager(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.delegation"
            )
        );
        ProxyAdmin eigenLayerProxyAdmin = ProxyAdmin(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.eigenLayerProxyAdmin"
            )
        );
        PauserRegistry eigenLayerPauserReg = PauserRegistry(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.eigenLayerPauserReg"
            )
        );
        StrategyBaseTVLLimits baseStrategyImplementation = StrategyBaseTVLLimits(
                stdJson.readAddress(
                    eigenlayerDeployedContracts,
                    ".addresses.baseStrategyImplementation"
                )
            );

        address credibleSquaringCommunityMultisig = msg.sender;
        address credibleSquaringPauser = msg.sender;

        vm.startBroadcast();
        _deployErc20AndStrategyAndWhitelistStrategy(
            eigenLayerProxyAdmin,
            eigenLayerPauserReg,
            baseStrategyImplementation,
            strategyManager
        );
        _deployCredibleSquaringContracts(
            delegationManager,
            erc20MockStrategy,
            credibleSquaringCommunityMultisig,
            credibleSquaringPauser
        );
        vm.stopBroadcast();
    }

    function _deployErc20AndStrategyAndWhitelistStrategy(
        ProxyAdmin eigenLayerProxyAdmin,
        PauserRegistry eigenLayerPauserReg,
        StrategyBaseTVLLimits baseStrategyImplementation,
        IStrategyManager strategyManager
    ) internal {
        erc20Mock = new ERC20Mock();
        // TODO(samlaf): any reason why we are using the strategybase with tvl limits instead of just using strategybase?
        // the maxPerDeposit and maxDeposits below are just arbitrary values.
        erc20MockStrategy = StrategyBaseTVLLimits(
            address(
                new TransparentUpgradeableProxy(
                    address(baseStrategyImplementation),
                    address(eigenLayerProxyAdmin),
                    abi.encodeWithSelector(
                        StrategyBaseTVLLimits.initialize.selector,
                        1 ether, // maxPerDeposit
                        100 ether, // maxDeposits
                        IERC20(erc20Mock),
                        eigenLayerPauserReg
                    )
                )
            )
        );
        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = erc20MockStrategy;
        strategyManager.addStrategiesToDepositWhitelist(strats);
    }

    function _deployCredibleSquaringContracts(
        IDelegationManager delegationManager,
        IStrategy strat,
        address incredibleSquaringCommunityMultisig,
        address credibleSquaringPauser
    ) internal {
        // Adding this as a temporary fix to make the rest of the script work with a single strategy
        // since it was originally written to work with an array of strategies
        IStrategy[1] memory deployedStrategyArray = [strat];
        uint numStrategies = deployedStrategyArray.length;

        // deploy proxy admin for ability to upgrade proxy contracts
        incredibleSquaringProxyAdmin = new ProxyAdmin();

        // deploy pauser registry
        {
            address[] memory pausers = new address[](2);
            pausers[0] = credibleSquaringPauser;
            pausers[1] = incredibleSquaringCommunityMultisig;
            incredibleSquaringPauserReg = new PauserRegistry(
                pausers,
                incredibleSquaringCommunityMultisig
            );
        }

        EmptyContract emptyContract = new EmptyContract();

        // hard-coded inputs

        /**
         * First, deploy upgradeable proxy contracts that **will point** to the implementations. Since the implementation contracts are
         * not yet deployed, we give these proxies an empty contract as the initial implementation, to act as if they have no code.
         */
        incredibleSquaringServiceManager = IncredibleSquaringServiceManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(incredibleSquaringProxyAdmin),
                    ""
                )
            )
        );
        incredibleSquaringTaskManager = IncredibleSquaringTaskManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(incredibleSquaringProxyAdmin),
                    ""
                )
            )
        );
        registryCoordinator = regcoord.ECDSARegistryCoordinator(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(incredibleSquaringProxyAdmin),
                    ""
                )
            )
        );
        stakeRegistry = ECDSAStakeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(incredibleSquaringProxyAdmin),
                    ""
                )
            )
        );
        indexRegistry = ECDSAIndexRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(incredibleSquaringProxyAdmin),
                    ""
                )
            )
        );

        operatorStateRetriever = new ECDSAOperatorStateRetriever();

        // Second, deploy the *implementation* contracts, using the *proxy contracts* as inputs
        {
            stakeRegistryImplementation = new ECDSAStakeRegistry(
                registryCoordinator,
                delegationManager
            );

            incredibleSquaringProxyAdmin.upgrade(
                TransparentUpgradeableProxy(payable(address(stakeRegistry))),
                address(stakeRegistryImplementation)
            );

            indexRegistryImplementation = new ECDSAIndexRegistry(
                registryCoordinator
            );

            incredibleSquaringProxyAdmin.upgrade(
                TransparentUpgradeableProxy(payable(address(indexRegistry))),
                address(indexRegistryImplementation)
            );
        }

        registryCoordinatorImplementation = new regcoord.ECDSARegistryCoordinator(
            incredibleSquaringServiceManager,
            regcoord.ECDSAStakeRegistry(address(stakeRegistry)),
            regcoord.ECDSAIndexRegistry(address(indexRegistry))
        );

        {
            uint numQuorums = 1;
            // for each quorum to setup, we need to define
            // minimumStakeForQuorum, and strategyParams
            // set to 0 for every quorum
            uint96[] memory quorumsMinimumStake = new uint96[](numQuorums);
            regcoord.ECDSAStakeRegistry.StrategyParams[][]
                memory quorumsStrategyParams = new regcoord.ECDSAStakeRegistry.StrategyParams[][](
                    numQuorums
                );
            for (uint i = 0; i < numQuorums; i++) {
                quorumsStrategyParams[
                    i
                ] = new regcoord.ECDSAStakeRegistry.StrategyParams[](
                    numStrategies
                );
                for (uint j = 0; j < numStrategies; j++) {
                    quorumsStrategyParams[i][j] = regcoord
                        .ECDSAStakeRegistry
                        .StrategyParams({
                            strategy: deployedStrategyArray[j],
                            // setting this to 1 ether since the divisor is also 1 ether
                            // therefore this allows an operator to register with even just 1 token
                            // see https://github.com/Layr-Labs/eigenlayer-middleware/blob/m2-mainnet/src/StakeRegistry.sol#L484
                            //    weight += uint96(sharesAmount * strategyAndMultiplier.multiplier / WEIGHTING_DIVISOR);
                            multiplier: 1 ether
                        });
                }
            }
            incredibleSquaringProxyAdmin.upgradeAndCall(
                TransparentUpgradeableProxy(
                    payable(address(registryCoordinator))
                ),
                address(registryCoordinatorImplementation),
                abi.encodeWithSelector(
                    regcoord.ECDSARegistryCoordinator.initialize.selector,
                    // we set initialOwner and ejector to communityMultisig
                    incredibleSquaringCommunityMultisig,
                    incredibleSquaringCommunityMultisig,
                    incredibleSquaringPauserReg,
                    0, // 0 initialPausedStatus means everything unpaused
                    quorumsMinimumStake,
                    quorumsStrategyParams
                )
            );
        }

        incredibleSquaringServiceManagerImplementation = new IncredibleSquaringServiceManager(
            delegationManager,
            registryCoordinator,
            stakeRegistry,
            incredibleSquaringTaskManager
        );
        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        incredibleSquaringProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(
                payable(address(incredibleSquaringServiceManager))
            ),
            address(incredibleSquaringServiceManagerImplementation),
            abi.encodeWithSelector(
                incredibleSquaringServiceManager.initialize.selector,
                incredibleSquaringCommunityMultisig
            )
        );

        incredibleSquaringTaskManagerImplementation = new IncredibleSquaringTaskManager(
            registryCoordinator,
            TASK_RESPONSE_WINDOW_BLOCK
        );

        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        incredibleSquaringProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(
                payable(address(incredibleSquaringTaskManager))
            ),
            address(incredibleSquaringTaskManagerImplementation),
            abi.encodeWithSelector(
                incredibleSquaringTaskManager.initialize.selector,
                incredibleSquaringPauserReg,
                incredibleSquaringCommunityMultisig,
                AGGREGATOR_ADDR,
                TASK_GENERATOR_ADDR
            )
        );

        // WRITE JSON DATA
        string memory parent_object = "parent object";

        string memory deployed_addresses = "addresses";
        vm.serializeAddress(
            deployed_addresses,
            "erc20Mock",
            address(erc20Mock)
        );
        vm.serializeAddress(
            deployed_addresses,
            "erc20MockStrategy",
            address(erc20MockStrategy)
        );
        vm.serializeAddress(
            deployed_addresses,
            "credibleSquaringServiceManager",
            address(incredibleSquaringServiceManager)
        );
        vm.serializeAddress(
            deployed_addresses,
            "credibleSquaringServiceManagerImplementation",
            address(incredibleSquaringServiceManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "credibleSquaringTaskManager",
            address(incredibleSquaringTaskManager)
        );
        vm.serializeAddress(
            deployed_addresses,
            "credibleSquaringTaskManagerImplementation",
            address(incredibleSquaringTaskManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "registryCoordinator",
            address(registryCoordinator)
        );
        vm.serializeAddress(
            deployed_addresses,
            "registryCoordinatorImplementation",
            address(registryCoordinatorImplementation)
        );
        string memory deployed_addresses_output = vm.serializeAddress(
            deployed_addresses,
            "operatorStateRetriever",
            address(operatorStateRetriever)
        );

        // serialize all the data
        string memory finalJson = vm.serializeString(
            parent_object,
            deployed_addresses,
            deployed_addresses_output
        );

        writeOutput(finalJson, "credible_squaring_avs_deployment_output");
    }
}
