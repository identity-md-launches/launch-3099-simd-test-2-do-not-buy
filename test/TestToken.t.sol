// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";

contract TestTokenTest is Test {
    TestToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new TestToken();
    }

    function test_fixedLaunchSupplyAndMetadata() public view {
        assertEq(token.name(), "SIMD TEST 2 - DO NOT BUY");
        assertEq(token.symbol(), "SIMDTEST2");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_launchTransfersAndAllowanceConserveSupply(uint256 seed) public {
        uint256 amount = bound(seed, 1, 1e27);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(bob);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(bob), token.totalSupply());
        assertEq(token.totalSupply(), 1e27);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(address(this), bob, 1);
    }

    function test_noOwnerMintPauseBlacklistOrUpgradeEvenForDeployer() public {
        token.transfer(alice, 100 ether);
        string[8] memory calls = [
            "mint(address,uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "transferOwnership(address)",
            "initialize(address)",
            "upgradeTo(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(calls[i], alice, 100 ether));
            assertFalse(ok);
        }
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_invalidTransfersDoNotChangeBalances() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(bob), 0);
    }
}
