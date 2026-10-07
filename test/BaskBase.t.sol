// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {MockFactory, MockFeed, MockStock, RevertingRecipient, HostileUpgrade} from "./mocks/StockMocks.sol";

abstract contract BaskBase is Test {
    address internal constant OWNER = 0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3;
    address internal constant GUARDIAN = 0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant FACTORY = 0x4783C67b63dE2B358Ac5951a7D41F47A38F3C046;
    uint256 internal constant MONDAY = 20003 days + 55800; // Monday, 2024-10-07, 15:30 UTC.
    BaskVault internal vault;
    MockStock[] internal stocks;
    MockFeed[] internal feeds;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(MONDAY - 3 days);
        MockFactory factory = new MockFactory();
        vm.etch(FACTORY, address(factory).code);
        vault = new BaskVault(OWNER, GUARDIAN);
        for (uint256 i; i < 3; ++i) {
            _addAsset();
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vm.warp(MONDAY);
        _refresh();
    }

    function _newAsset(uint256 id) internal returns (MockStock token, MockFeed feed) {
        token = new MockStock(bytes32(id));
        feed = new MockFeed();
        MockFactory(FACTORY).set(bytes32(id), address(token));
    }

    function _addAsset() internal {
        (MockStock token, MockFeed feed) = _newAsset(stocks.length + 1);
        stocks.push(token);
        feeds.push(feed);
        vm.prank(OWNER);
        vault.proposeAsset(address(token), address(feed));
    }

    function _refresh() internal {
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].set(100e8, vm.getBlockTimestamp());
        }
    }

    function _deposit(uint256 index, uint256 amount, address who) internal returns (uint256 shares) {
        MockStock token = stocks[index];
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(vault), amount);
        shares = vault.deposit(address(token), amount, who, 0, vm.getBlockTimestamp());
        vm.stopPrank();
    }

    function _redeem(address who, uint256 shares) internal returns (uint256[] memory) {
        vm.prank(who);
        return vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp());
    }

    function _depositReverts(uint256 index, uint256 amount, bytes4 reason) internal {
        MockStock token = stocks[index];
        token.mint(ALICE, amount);
        vm.startPrank(ALICE);
        token.approve(address(vault), amount);
        vm.expectRevert(reason);
        vault.deposit(address(token), amount, ALICE, 0, vm.getBlockTimestamp());
        vm.stopPrank();
    }

    function _status(uint256 index, BaskVault.Reason reason, address fault) internal view {
        (BaskVault.Reason got, address asset) = vault.depositStatus(address(stocks[index]));
        assertEq(uint256(got), uint256(reason));
        assertEq(asset, fault);
    }

    function _statusRevert(uint256 index, BaskVault.Reason reason, address fault) internal {
        _status(index, reason, fault);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, reason, fault));
        vault.deposit(address(stocks[index]), 1e18, ALICE, 0, vm.getBlockTimestamp());
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        return amount / 200 + (amount % 200 == 0 ? 0 : 1);
    }

    function _execute(uint256 id) internal {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.executeProposal(id);
    }
}
