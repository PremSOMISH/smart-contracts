/* Copyright (C) 2017 NexusMutual.io

  This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

  This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
    along with this program.  If not, see http://www.gnu.org/licenses/ */

//Claims Reward Contract contains the functions for calculating number of tokens
// that will get rewarded, unlocked or burned depending upon the status of claim.

pragma solidity 0.5.7;

import "./ClaimsData.sol";
import "./Governance.sol";
import "./Claims.sol";
import "./Pool1.sol";
import "./StakedData.sol";


contract ClaimsReward is Iupgradable {
    using SafeMath for uint;

    NXMToken internal tk;
    TokenController internal tc;
    TokenFunctions internal tf;
    TokenData internal td;
    QuotationData internal qd;
    Claims internal c1;
    ClaimsData internal cd;
    Pool1 internal p1;
    Pool2 internal p2;
    PoolData internal pd;
    Governance internal gv;
    StakedData internal sd;

    uint private constant DECIMAL1E18 = uint(10) ** 18;
    uint private constant POINT_MULTIPLIER = 10;

    constructor(address  _stakeDataAdd) public {
        sd = StakedData(_stakeDataAdd);
    }

    /**
     * @dev Migrates all users to new staking structure.
     * @param _ra address of user.
     */
    function migrateStake(address _ra) external {

        require(!sd.userMigrated(_ra));
        claimAllCommissionAndUnlockable(_ra, 10);
        uint snxm = tf.getStakerAllLockedTokens(_ra);
        if (snxm > 0) {

            tc.mint(_ra, snxm);
            tf.increaseStake(_ra, snxm);
            uint stakedLen = td.getStakerStakedContractLength(_ra);
            uint[] memory stakedAllocations = new uint[](stakedLen);
            address[] memory stakedAddresses = new address[](stakedLen);
            uint i;
            for (i = 0; i < stakedLen; i++) {
                uint scIndex;
                stakedAddresses[i] = td.getStakerStakedContractByIndex(_ra, i);
                scIndex = td.getStakerStakedContractIndex(_ra, i);
                uint stakedAmount;
                (, stakedAmount) = tf._unlockableBeforeBurningAndCanBurn(_ra, stakedAddresses[i], i);
                stakedAllocations[i] = stakedAmount.mul(10000).div(snxm);
                if (stakedAllocations[i] > 1000) {
                    stakedAllocations[i] = 1000;
                }
                if (stakedAllocations[i] < 200) {
                    stakedAllocations[i] = 0;
                }
                td.pushBurnedTokens(_ra, i, stakedAmount);
                bytes32 reason = keccak256(abi.encodePacked("UW", _ra,
                    stakedAddresses[i], scIndex));
                tc.burnLockedTokens(_ra, reason, stakedAmount);
            }
            tf.increaseAllocation(_ra, stakedAddresses, stakedAllocations);
        }
        sd.setUserMigrated(_ra);
        sd.callEvent(_ra, address(0), 0, 2);
    }
  
    function changeDependentContractAddress() public onlyInternal {
        c1 = Claims(ms.getLatestAddress("CL"));
        cd = ClaimsData(ms.getLatestAddress("CD"));
        tk = NXMToken(ms.tokenAddress());
        tc = TokenController(ms.getLatestAddress("TC"));
        td = TokenData(ms.getLatestAddress("TD"));
        tf = TokenFunctions(ms.getLatestAddress("TF"));
        p1 = Pool1(ms.getLatestAddress("P1"));
        p2 = Pool2(ms.getLatestAddress("P2"));
        pd = PoolData(ms.getLatestAddress("PD"));
        qd = QuotationData(ms.getLatestAddress("QD"));
        gv = Governance(ms.getLatestAddress("GV"));
    }

    /// @dev Decides the next course of action for a given claim.
    function changeClaimStatus(uint claimid) public checkPause onlyInternal {

        uint coverid;
        (, coverid) = cd.getClaimCoverId(claimid);

        uint status;
        (, status) = cd.getClaimStatusNumber(claimid);

        // when current status is "Pending-Claim Assessor Vote"
        if (status == 0) {
            _changeClaimStatusCA(claimid, coverid, status);
        } else if (status >= 1 && status <= 5) { 
            _changeClaimStatusMV(claimid, coverid, status);
        } else if (status == 12) { // when current status is "Claim Accepted Payout Pending"
            bytes32 curr = qd.getCurrencyOfCover(coverid);
            tf.burnStakerStake(claimid, coverid, bytes4(curr));
            bool succ = p1.sendClaimPayout(coverid, claimid, qd.getCoverSumAssured(coverid).mul(DECIMAL1E18), 
            qd.getCoverMemberAddress(coverid), bytes4(curr));
            if (succ) 
                c1.setClaimStatus(claimid, 14);
        }
        c1.changePendingClaimStart();
    }

    /// @dev Amount of tokens to be rewarded to a user for a particular vote id.
    /// @param check 1 -> CA vote, else member vote
    /// @param voteid vote id for which reward has to be Calculated
    /// @param flag if 1 calculate even if claimed,else don't calculate if already claimed
    /// @return tokenCalculated reward to be given for vote id
    /// @return lastClaimedCheck true if final verdict is still pending for that voteid
    /// @return tokens number of tokens locked under that voteid
    /// @return perc percentage of reward to be given.
    function getRewardToBeGiven(
        uint check,
        uint voteid,
        uint flag
    ) 
        public
        view
        returns (
            uint tokenCalculated,
            bool lastClaimedCheck,
            uint tokens,
            uint perc
        )

    {
        uint claimId;
        int8 verdict;
        bool claimed;
        uint tokensToBeDist;
        uint totalTokens;
        (tokens, claimId, verdict, claimed) = cd.getVoteDetails(voteid);
        lastClaimedCheck = false;
        int8 claimVerdict = cd.getFinalVerdict(claimId);
        if (claimVerdict == 0)
            lastClaimedCheck = true;

        if (claimVerdict == verdict && (claimed == false || flag == 1)) {
            
            if (check == 1) {
                (perc, , tokensToBeDist) = cd.getClaimRewardDetail(claimId);
            } else {
                (, perc, tokensToBeDist) = cd.getClaimRewardDetail(claimId);
            }
                
            if (perc > 0) {
                if (check == 1) {
                    if (verdict == 1) {
                        (, totalTokens, ) = cd.getClaimsTokenCA(claimId);
                    } else {
                        (, , totalTokens) = cd.getClaimsTokenCA(claimId);
                    }
                } else {
                    if (verdict == 1) {
                        (, totalTokens, ) = cd.getClaimsTokenMV(claimId);
                    }else {
                        (, , totalTokens) = cd.getClaimsTokenMV(claimId);
                    }
                }
                tokenCalculated = (perc.mul(tokens).mul(tokensToBeDist)).div(totalTokens.mul(100));
                
                
            }
        }
    }

    /// @dev Transfers all tokens held by contract to a new contract in case of upgrade.
    function upgrade(address _newAdd) public onlyInternal {
        uint amount = tk.balanceOf(address(this));
        if (amount > 0)
            require(tk.transfer(_newAdd, amount));
        
    }

    /// @dev Total reward in token due for claim by a user.
    /// @return total total number of tokens
    function getRewardToBeDistributedByUser(address _add) public view returns(uint total) {
        uint lengthVote = cd.getVoteAddressCALength(_add);
        uint lastIndexCA;
        uint lastIndexMV;
        uint tokenForVoteId;
        uint voteId;
        (lastIndexCA, lastIndexMV) = cd.getRewardDistributedIndex(_add);

        for (uint i = lastIndexCA; i < lengthVote; i++) {
            voteId = cd.getVoteAddressCA(_add, i);
            (tokenForVoteId, , , ) = getRewardToBeGiven(1, voteId, 0);
            total = total.add(tokenForVoteId);
        }

        lengthVote = cd.getVoteAddressMemberLength(_add);

        for (uint j = lastIndexMV; j < lengthVote; j++) {
            voteId = cd.getVoteAddressMember(_add, j);
            (tokenForVoteId, , , ) = getRewardToBeGiven(0, voteId, 0);
            total = total.add(tokenForVoteId);
        }
        return (total);
    }

    /// @dev Gets reward amount and claiming status for a given claim id.
    /// @return reward amount of tokens to user.
    /// @return claimed true if already claimed false if yet to be claimed.
    function getRewardAndClaimedStatus(uint check, uint claimId) public view returns(uint reward, bool claimed) {
        uint voteId;
        uint claimid;
        uint lengthVote;

        if (check == 1) {
            lengthVote = cd.getVoteAddressCALength(msg.sender);
            for (uint i = 0; i < lengthVote; i++) {
                voteId = cd.getVoteAddressCA(msg.sender, i);
                (, claimid, , claimed) = cd.getVoteDetails(voteId);
                if (claimid == claimId) break;
            }
        } else {
            lengthVote = cd.getVoteAddressMemberLength(msg.sender);
            for (uint j = 0; j < lengthVote; j++) {
                voteId = cd.getVoteAddressMember(msg.sender, j);
                (, claimid, , claimed) = cd.getVoteDetails(voteId);
                if (claimid == claimId) break;
            }
        }
        (reward, , , ) = getRewardToBeGiven(check, voteId, 1);

    }

    /**
     * @dev Function used to claim all pending rewards on a list of proposals.
     */
    function claimAllPendingReward(address userAdd, uint records) public {
        require((ms.isInternal(msg.sender) || userAdd == msg.sender) && ms.isMember(userAdd) && !ms.isPause());
        _claimRewardToBeDistributed(userAdd, records);
        _claimPooledStakeCommission(userAdd, records);
        // tf.unlockStakerUnlockableTokens(msg.sender); 
        uint gvReward = gv.claimReward(userAdd, records);
        if (gvReward > 0) {
            require(tk.transfer(userAdd, gvReward));
        }
    }

    /**
     * @dev Function used to get pending rewards of a particular user address.
     * @param _add user address.
     * @return total reward amount of the user
     */
    function getAllPendingRewardOfUser(address _add) public view returns(uint total) {
        uint caReward = getRewardToBeDistributedByUser(_add);
        (uint commission, , , ) = getPendingPooledCommission(_add, 100);
        // uint commissionReedmed = td.getStakerTotalReedmedStakeCommission(_add);
        // uint unlockableStakedTokens = tf.getStakerAllUnlockableStakedTokens(_add);
        uint governanceReward = gv.getPendingReward(_add);
        total = caReward.add(commission).add(governanceReward);
    }

    function getPendingPooledCommission(address _user, uint _records) public view returns(uint reward, uint i, uint totalBurned, uint burnedClaimIndex) {
        i = sd.lastClaimedforCoverId(_user);
        burnedClaimIndex = sd.lastBurnedforClaim(_user);
        uint burnedStakeLen = sd.getClaimIdBurnedStake();
        uint burntOn;
        if(burnedClaimIndex < burnedStakeLen)
            (burntOn, , ) = sd.claimIdBurnedStake(burnedClaimIndex);
        uint lastCover = qd.getCoverLength();
        reward = 0;
        uint globalStaked = sd.globalStake(_user);
        uint j=0;
        totalBurned = 0;
        for (; i < lastCover && j < _records; i++) {
            uint purchasedOn = qd.getValidityOfCover(i).sub(uint(qd.getCoverPeriod(i)).mul(1 days));
            if(burntOn < purchasedOn && burnedClaimIndex < burnedStakeLen)
            {
                uint burnedForIndex = _getUserStakeBurnForClaim(_user, burnedClaimIndex, globalStaked);
                globalStaked = globalStaked.sub(burnedForIndex);
                totalBurned = totalBurned.add(burnedForIndex);
                burnedClaimIndex++;
                if(burnedClaimIndex < burnedStakeLen)
                    (burntOn, ,) = sd.claimIdBurnedStake(burnedClaimIndex);

            }
            reward = reward.add(_getUserRewardForCover(_user, i, globalStaked));
            j++;
        }
    }

    function claimAllCommissionAndUnlockable(address _user, uint records) internal {
        _claimStakeCommission(records, _user);
        tf.unlockStakerUnlockableTokens(_user); 
    } 

    function _getUserStakeBurnForClaim(address _user, uint index, uint globalStake) internal view returns(uint) {
        uint claimid;
        uint burntByStakedRatiox1000;
        (, burntByStakedRatiox1000, claimid) = sd.claimIdBurnedStake(index);
        if(burntByStakedRatiox1000 < 10000)
            burntByStakedRatiox1000 = 10000;
        (, uint coverIdOfClaim) = cd.getClaimCoverId(claimid);
        (, address smartCover) = qd.getscAddressOfCover(coverIdOfClaim);
        int scUserIndex = sd.getScUserIndex(smartCover, _user);
        if(scUserIndex != -1)
        {
            (, uint allocation) = sd.stakerStakedContracts(_user, uint(scUserIndex));
            return allocation.mul(globalStake).mul(POINT_MULTIPLIER).mul(burntByStakedRatiox1000).div(100000000);
        }
        return 0; // scUserIndex == -1 means user has not staked against the smart contract for which calim is accepted.

    }

    function _getUserRewardForCover(address _user, uint coverId, uint globalStaked) internal view returns(uint) {
        (, address smartCover) = qd.getscAddressOfCover(coverId);
        int scUser = sd.getScUserIndex(smartCover, _user);
        if(scUser != -1)
        {
            (, uint allocation) = sd.stakerStakedContracts(_user, uint(scUser));
            uint stakedOnScAtCoverPurchase;
            uint rewardForCover;
            (rewardForCover, stakedOnScAtCoverPurchase) = sd.coverIdCommission(coverId);
            return allocation.mul(globalStaked).mul(rewardForCover).div(stakedOnScAtCoverPurchase).div(10000);
        }
        return 0; // scUserIndex == -1 means user has not staked against the smart contract for which cover is purchased.

    }

    /// @dev Rewards/Punishes users who  participated in Claims assessment.
    //             Unlocking and burning of the tokens will also depend upon the status of claim.
    /// @param claimid Claim Id.
    function _rewardAgainstClaim(uint claimid, uint coverid, uint sumAssured, uint status) internal {
        uint premiumNXM = qd.getCoverPremiumNXM(coverid);
        bytes4 curr = qd.getCurrencyOfCover(coverid);
        uint distributableTokens = premiumNXM.mul(cd.claimRewardPerc()).div(100);//  20% of premium
            
        uint percCA;
        uint percMV;

        (percCA, percMV) = cd.getRewardStatus(status);
        cd.setClaimRewardDetail(claimid, percCA, percMV, distributableTokens);
        if (percCA > 0 || percMV > 0) {
            tc.mint(address(this), distributableTokens);
        }

        if (status == 6 || status == 9 || status == 11) {
            cd.changeFinalVerdict(claimid, -1);
            td.setDepositCN(coverid, false); // Unset flag
            tf.burnDepositCN(coverid); // burn Deposited CN
            
            pd.changeCurrencyAssetVarMin(curr, pd.getCurrencyAssetVarMin(curr).sub(sumAssured));
            p2.internalLiquiditySwap(curr);
            
        } else if (status == 7 || status == 8 || status == 10) {
            cd.changeFinalVerdict(claimid, 1);
            td.setDepositCN(coverid, false); // Unset flag
            tf.unlockCN(coverid);
            tf.burnStakerStake(claimid, coverid, curr);
            p1.sendClaimPayout(coverid, claimid, sumAssured, qd.getCoverMemberAddress(coverid), curr); //send payout
        } 
    }

    /// @dev Computes the result of Claim Assessors Voting for a given claim id.
    function _changeClaimStatusCA(uint claimid, uint coverid, uint status) internal {
        // Check if voting should be closed or not
        if (c1.checkVoteClosing(claimid) == 1) {
            uint caTokens = c1.getCATokens(claimid, 0); // converted in cover currency. 
            uint accept;
            uint deny;
            uint acceptAndDeny;
            bool rewardOrPunish;
            uint sumAssured;
            (, accept) = cd.getClaimVote(claimid, 1);
            (, deny) = cd.getClaimVote(claimid, -1);
            acceptAndDeny = accept.add(deny);
            accept = accept.mul(100);
            deny = deny.mul(100);

            if (caTokens == 0) {
                status = 3;
            } else {
                sumAssured = qd.getCoverSumAssured(coverid).mul(DECIMAL1E18);
                // Min threshold reached tokens used for voting > 5* sum assured  
                if (caTokens > sumAssured.mul(5)) {

                    if (accept.div(acceptAndDeny) > 70) {
                        status = 7;
                        qd.changeCoverStatusNo(coverid, uint8(QuotationData.CoverStatus.ClaimAccepted));
                        rewardOrPunish = true;
                    } else if (deny.div(acceptAndDeny) > 70) {
                        status = 6;
                        qd.changeCoverStatusNo(coverid, uint8(QuotationData.CoverStatus.ClaimDenied));
                        rewardOrPunish = true;
                    } else if (accept.div(acceptAndDeny) > deny.div(acceptAndDeny)) {
                        status = 4;
                    } else {
                        status = 5;
                    }

                } else {

                    if (accept.div(acceptAndDeny) > deny.div(acceptAndDeny)) {
                        status = 2;
                    } else {
                        status = 3;
                    }
                }
            }

            c1.setClaimStatus(claimid, status);

            if (rewardOrPunish)
                _rewardAgainstClaim(claimid, coverid, sumAssured, status);
        }
    }

    /// @dev Computes the result of Member Voting for a given claim id.
    function _changeClaimStatusMV(uint claimid, uint coverid, uint status) internal {

        // Check if voting should be closed or not
        if (c1.checkVoteClosing(claimid) == 1) {
            uint8 coverStatus;
            uint statusOrig = status;
            uint mvTokens = c1.getCATokens(claimid, 1); // converted in cover currency. 

            // If tokens used for acceptance >50%, claim is accepted
            uint sumAssured = qd.getCoverSumAssured(coverid).mul(DECIMAL1E18);
            uint thresholdUnreached = 0;
            // Minimum threshold for member voting is reached only when 
            // value of tokens used for voting > 5* sum assured of claim id
            if (mvTokens < sumAssured.mul(5))
                thresholdUnreached = 1;

            uint accept;
            (, accept) = cd.getClaimMVote(claimid, 1);
            uint deny;
            (, deny) = cd.getClaimMVote(claimid, -1);

            if (accept.add(deny) > 0) {
                if (accept.mul(100).div(accept.add(deny)) >= 50 && statusOrig > 1 && 
                    statusOrig <= 5 && thresholdUnreached == 0) {
                    status = 8;
                    coverStatus = uint8(QuotationData.CoverStatus.ClaimAccepted);
                } else if (deny.mul(100).div(accept.add(deny)) >= 50 && statusOrig > 1 &&
                    statusOrig <= 5 && thresholdUnreached == 0) {
                    status = 9;
                    coverStatus = uint8(QuotationData.CoverStatus.ClaimDenied);
                }
            }
            
            if (thresholdUnreached == 1 && (statusOrig == 2 || statusOrig == 4)) {
                status = 10;
                coverStatus = uint8(QuotationData.CoverStatus.ClaimAccepted);
            } else if (thresholdUnreached == 1 && (statusOrig == 5 || statusOrig == 3 || statusOrig == 1)) {
                status = 11;
                coverStatus = uint8(QuotationData.CoverStatus.ClaimDenied);
            }

            c1.setClaimStatus(claimid, status);
            qd.changeCoverStatusNo(coverid, uint8(coverStatus));
            // Reward/Punish Claim Assessors and Members who participated in Claims assessment
            _rewardAgainstClaim(claimid, coverid, sumAssured, status);
        }
    }

    /// @dev Allows a user to claim all pending  Claims assessment rewards.
    function _claimRewardToBeDistributed(address _userAdd, uint _records) internal {
        uint lengthVote = cd.getVoteAddressCALength(_userAdd);
        uint voteid;
        // uint lastIndex;
        // (lastIndex, ) = cd.getRewardDistributedIndex(msg.sender);
        uint total = 0;
        uint tokenForVoteId = 0;
        bool lastClaimedCheck;
        uint _days = td.lockCADays();
        bool claimed;   
        uint counter = 0;
        uint claimId;
        uint perc;
        uint i;
        uint lastClaimed = lengthVote;

        for ((i, ) = cd.getRewardDistributedIndex(_userAdd); i < lengthVote && counter < _records; i++) {
            voteid = cd.getVoteAddressCA(_userAdd, i);
            (tokenForVoteId, lastClaimedCheck, , perc) = getRewardToBeGiven(1, voteid, 0);
            if (lastClaimed == lengthVote && lastClaimedCheck == true)
                lastClaimed = i;
            (, claimId, , claimed) = cd.getVoteDetails(voteid);

            if (perc > 0 && !claimed) {
                counter++;
                cd.setRewardClaimed(voteid, true);
            } else if (perc == 0 && cd.getFinalVerdict(claimId) != 0 && !claimed) {
                (perc, , ) = cd.getClaimRewardDetail(claimId);
                if (perc == 0)
                    counter++;
                cd.setRewardClaimed(voteid, true);
            }
            if (tokenForVoteId > 0)
                total = tokenForVoteId.add(total);
        }
        _days = _days.mul(counter);
        // Added check for non zero locked tokens inside reduceLock function to avoid stack too deep error.
        tc.reduceLock(_userAdd, "CLA", _days); 
        if (lastClaimed == lengthVote) {
            cd.setRewardDistributedIndexCA(_userAdd, i);
        } else {
            cd.setRewardDistributedIndexCA(_userAdd, lastClaimed);
        }
        lengthVote = cd.getVoteAddressMemberLength(_userAdd);
        lastClaimed = lengthVote;
        
        // (, lastIndex) = cd.getRewardDistributedIndex(msg.sender);
        lastClaimed = lengthVote;
        counter = 0;
        for ((i, ) = cd.getRewardDistributedIndex(_userAdd); i < lengthVote && counter < _records; i++) {
            voteid = cd.getVoteAddressMember(_userAdd, i);
            (tokenForVoteId, lastClaimedCheck, , ) = getRewardToBeGiven(0, voteid, 0);
            if (lastClaimed == lengthVote && lastClaimedCheck == true)
                lastClaimed = i;
            (, claimId, , claimed) = cd.getVoteDetails(voteid);
            if (claimed == false && cd.getFinalVerdict(claimId) != 0) {
                cd.setRewardClaimed(voteid, true);
                counter++;
            }
            if (tokenForVoteId > 0)
                total = tokenForVoteId.add(total);
        }
        if (total > 0)
            require(tk.transfer(_userAdd, total));
        if (lastClaimed == lengthVote) {
            cd.setRewardDistributedIndexMV(_userAdd, i);
        } else {
            cd.setRewardDistributedIndexMV(_userAdd, lastClaimed);
        }
    }

    /**
     * @dev Function used to claim the commission earned by the staker.
     */
    function _claimStakeCommission(uint _records, address _user) internal {
        uint total=0;
        uint len = td.getStakerStakedContractLength(_user);
        uint lastCompletedStakeCommission = td.lastCompletedStakeCommission(_user);
        uint commissionEarned;
        uint commissionRedeemed;
        uint maxCommission;
        uint lastCommisionRedeemed = len;
        uint counter;
        uint i;

        for (i = lastCompletedStakeCommission; i < len && counter < _records; i++) {
            commissionRedeemed = td.getStakerRedeemedStakeCommission(_user, i);
            commissionEarned = td.getStakerEarnedStakeCommission(_user, i);
            maxCommission = td.getStakerInitialStakedAmountOnContract(
                _user, i).mul(td.stakerMaxCommissionPer()).div(100);
            if (lastCommisionRedeemed == len && maxCommission != commissionEarned)
                lastCommisionRedeemed = i;
            td.pushRedeemedStakeCommissions(_user, i, commissionEarned.sub(commissionRedeemed));
            total = total.add(commissionEarned.sub(commissionRedeemed));
            counter++;
        }
        if (lastCommisionRedeemed == len) {
            td.setLastCompletedStakeCommissionIndex(_user, i);
        } else {
            td.setLastCompletedStakeCommissionIndex(_user, lastCommisionRedeemed); 
        }

        if (total > 0) 
            require(tk.transfer(_user, total)); //solhint-disable-line
        
    }

    /**
     * @dev Function used to claim the commission earned by the staker by new stratergy.
     */
    function _claimPooledStakeCommission(address _user, uint _records) internal {
        (uint reward, uint lastCover, uint totalBurned, uint burnedClaimIndex) = getPendingPooledCommission(_user, _records);
        sd.decreaseGlobalStake(_user, totalBurned);
        tc.decreaseGlobalBurn(_user, totalBurned);
        sd.updateLastClaimedforCoverId(_user, lastCover);
        sd.updateLastBurnedforClaim(_user, burnedClaimIndex);
        if (reward > 0) 
            require(tk.transfer(_user, reward));
        sd.callEvent(_user, address(0), reward, 3);
    }
}
