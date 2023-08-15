// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {LidoSplitFactory, LidoSplit} from "src/lido/LidoSplitFactory.sol";
import {ERC20} from 'solmate/tokens/ERC20.sol';
import {LidoSplitTestHelper} from '../LidoSplitTestHelper.sol';
import {ISplitMain} from "src/interfaces/ISplitMain.sol";

contract LidoSplitIntegrationTest is LidoSplitTestHelper, Test {

    LidoSplitFactory internal lidoSplitFactory;
    LidoSplit internal lidoSplit;

    address splitter;

    address[] accounts;
    uint32[] percentAllocations;
    
    address internal SPLIT_MAIN_MAINNET = 0x2ed6c4B5dA6378c7897AC67Ba9e43102Feb694EE;

    function setUp() public {
        uint256 mainnetBlock = 17421005;
        vm.createSelectFork(getChain("mainnet").rpcUrl, mainnetBlock);

        lidoSplitFactory = new LidoSplitFactory(
            ERC20(STETH_MAINNET_ADDRESS),
            ERC20(WSTETH_MAINNET_ADDRESS)
        );
        
        accounts = new address[](2);
        accounts[0] = makeAddr("accounts0");
        accounts[1] = makeAddr("accounts1");

        percentAllocations = new uint32[](2);
        percentAllocations[0] = 400_000;
        percentAllocations[1] = 600_000;

        splitter = ISplitMain(SPLIT_MAIN_MAINNET).createSplit(
            accounts,
            percentAllocations,
            0,
            address(0)
        );

        lidoSplit = LidoSplit(
            lidoSplitFactory.createSplit(
                splitter
            )
        );

    }

    function test_CanDistribute() public {
        vm.prank(RANDOM_stETH_ACCOUNT_ADDRESS);
        ERC20(STETH_MAINNET_ADDRESS).transfer(address(lidoSplit), 100 ether);

        lidoSplit.distribute();

        ISplitMain(SPLIT_MAIN_MAINNET).distributeERC20(
            splitter,
            ERC20(WSTETH_MAINNET_ADDRESS),
            accounts,
            percentAllocations,
            0,
            address(0)
        );

        ERC20[] memory tokens = new ERC20[](1);
        tokens[0] = ERC20(WSTETH_MAINNET_ADDRESS);

        ISplitMain(SPLIT_MAIN_MAINNET).withdraw(accounts[0], 0, tokens);
        ISplitMain(SPLIT_MAIN_MAINNET).withdraw(accounts[1], 0, tokens);

        assertEq(
            ERC20(WSTETH_MAINNET_ADDRESS).balanceOf(accounts[0]),
            35483996363190140092, 
            "invalid account 0 balance"
        );
        assertEq(
            ERC20(WSTETH_MAINNET_ADDRESS).balanceOf(accounts[1]),
            53225994544785210138,
            "invalid account 1 balance"
        );
    }
}
