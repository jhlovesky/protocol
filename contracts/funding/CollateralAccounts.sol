/*

    Copyright 2019 The Hydro Protocol Foundation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;


import "../lib/Store.sol";
import "../lib/SafeMath.sol";
import "../lib/Consts.sol";
import "../funding/Auctions.sol";
import "../lib/Types.sol";

library CollateralAccounts {
    using SafeMath for uint256;

    function getDetails(
        Store.State storage state,
        address user,
        uint16 marketID
    )
        internal view
        returns (Types.CollateralAccountDetails memory details)
    {
        Types.CollateralAccount storage account = state.accounts[user][marketID];
        Types.Market storage market = state.markets[marketID];
        details.status = account.status;
        uint256 liquidateRate = state.markets[marketID].liquidateRate;

        uint256 baseUSDPrice = state.oracles[market.baseAsset].getPrice(market.baseAsset);
        uint256 quoteUSDPrice = state.oracles[market.quoteAsset].getPrice(market.quoteAsset);

        details.debtsTotalUSDValue = baseUSDPrice.mul(Pool._getPoolBorrowOf(state, market.baseAsset, user, marketID)).add(
            quoteUSDPrice.mul(Pool._getPoolBorrowOf(state, market.quoteAsset, user, marketID))
        ).div(Consts.ORACLE_PRICE_BASE());

        details.balancesTotalUSDValue = baseUSDPrice.mul(account.wallet.balances[market.baseAsset]).add(
            quoteUSDPrice.mul(account.wallet.balances[market.quoteAsset])
        ).div(Consts.ORACLE_PRICE_BASE());

        if (account.status == Types.CollateralAccountStatus.Normal) {
            details.liquidable = details.balancesTotalUSDValue <
            details.debtsTotalUSDValue.mul(liquidateRate).div(Consts.LIQUIDATE_RATE_BASE());
        } else {
            details.liquidable = false;
        }
    }

    /**
     * Liquidate multiple collateral account at once
     */
    function liquidateMulti(
        Store.State storage state,
        address[] memory users,
        uint16[] memory marketIDs
    )
        internal
        returns (uint32[] memory)
    {
        uint32[] memory auctionIDs = new uint32[](users.length);
        for( uint256 i = 0; i < users.length; i++ ) {
            uint32 auctionID = liquidate(state, users[i], marketIDs[i]);
            auctionIDs[i] = auctionID;
        }
        return auctionIDs;
    }

    /**
     * Liquidate a collateral account
     */
    function liquidate(
        Store.State storage state,
        address user,
        uint16 marketID
    )
        internal
        returns (uint32)
    {
        Types.CollateralAccountDetails memory details = getDetails(state, user, marketID);

        require(details.liquidable, "ACCOUNT_NOT_LIQUIDABLE");

        Types.Market storage market = state.markets[marketID];
        Types.CollateralAccount storage account = state.accounts[user][marketID];

        Pool.repay(state, user, marketID, market.baseAsset, account.wallet.balances[market.baseAsset]);
        Pool.repay(state, user, marketID, market.quoteAsset, account.wallet.balances[market.quoteAsset]);

        address collateralAsset;
        address debtAsset;

        if(account.wallet.balances[market.baseAsset] > 0) {
            // quote asset is debt, base asset is collateral
            collateralAsset = market.baseAsset;
            debtAsset = market.quoteAsset;
        } else {
            // base asset is debt, quote asset is collateral
            collateralAsset = market.quoteAsset;
            debtAsset = market.baseAsset;
        }

        account.status = Types.CollateralAccountStatus.Liquid;

        return Auctions.create(
            state,
            marketID,
            user,
            msg.sender,
            debtAsset,
            collateralAsset
        );
    }
}