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
    
pragma solidity 0.5.7;

import "./external/openzeppelin-solidity/math/SafeMath.sol";
import "./NXMaster.sol";


contract StakedData {
    using SafeMath for uint;

    // Maximum possible allocation against single smart contract, changeable via governance
    uint public maxAllocationPerx100; 
    // Minimum possible allocation against single smart contract, changeable via governance
    uint public minAllocationPerx100; 
    // Minimum stake need to be maintained by risk assessors, changeable via governance
    uint public minStake;
    // Parameter which used in determining max global stake for single contract, changeable via governance
    uint public globalMaxStakeMultiplier;
    // Varible that determines minimum time after which disallocation will effect, changeable via governance
    uint public disallocateEffectTime;

    // max percentx100 user can allocate.
    uint private constant MAX_TOTAL_STAKE = 10000; 
    // 10^18
    uint private constant DECIMAL1E18 = uint(10) ** 18; 

    NXMaster internal ms;
    MemberRoles internal mr;

    // Structure to hold staker's staked contract and allocation against it.
    struct Staked {
        address smartContract;
        uint allocationx100;
    }

    // Structure to hold staked contract's staker and allocation against it.
    struct Staker {
        address stakerAddress;
        uint allocationx100;
    }

    // Structure to hold unstaking records.
    struct DecreaseAllocationRequest {
        address smartContract;
        uint disAllocationx100;
        uint timestamp;
    }

    // Structure to hold Burned stake records.
    struct BurnedStake {
        // uint burned;
        uint timestamp;
        uint burntByStakedRatiox1000;
    }

    // Structure to hold Commission records.
    struct CommissionData {
        uint reward;
        uint stakedNXM;
    }

    /**
     * @dev mapping of uw address to array of sc address to fetch 
     * all staked contract address of underwriter 
     */ 
    mapping(address => Staked[]) public stakerStakedContracts; 

    /**
     * @dev mapping of uw address to total allocation 
     */
    mapping(address => uint) public userTotalAllocated;

    /**
     * @dev mapping of uw address to coverId till which user have claimed commission 
     */
    mapping(address => uint) public lastClaimedforCoverId;

    /**
     * @dev mapping of uw address to array of requested unallocation records to fetch 
     * all unallocation records of underwriter 
     */
    mapping(address=> DecreaseAllocationRequest[]) public userDisallocationRequest;
    
    /**
     * @dev mapping of uw address to Total global stake.
     * ie., actualStake = globalStake - globalBurned 
     */
    mapping(address => uint) public globalStake;

    /**
     * @dev mapping of uw address to Total burned stake which is not reduced from global stake. 
     * ie., actualStake = globalStake - globalBurned 
     */
    mapping(address => uint) public globalBurned;

    /**
     * @dev mapping of uw address to claim id which determines if action took place for UW for particular claim id. 
     */
    mapping(address => mapping(uint => bool)) public riskAssesorClaimAction;
    

    /** 
     * @dev mapping of sc address to array of UW address to fetch
     * all underwritters of the staked smart contract
     */
    mapping(address => Staker[]) public stakedContractStakers;

    mapping(address => uint) public lastBurnedforClaimId;

    /** 
     * @dev mapping of UW address to smart contract address to index.
     * To interlink stakedContractStakers and stakerStakedContracts
     */
    mapping(address=> mapping(address=> uint)) internal userSCIndex;

    /** 
     * @dev mapping of smart contract address to UW address to index.
     * To interlink stakedContractStakers and stakerStakedContracts
     */
    mapping(address=> mapping(address=> uint)) internal scUserIndex;

    /** 
     * @dev mapping of staker address to executed disallocation index.    
     */
    mapping(address=> uint) public userDisallocationExecuted;

    /** 
     * @dev mapping of claim id to burned stake against it.    
     */
    mapping(uint=> BurnedStake) public claimIdBurnedStake;

    /** 
     * @dev mapping of cover id to reward to be distributed.    
     */
    mapping(uint=> CommissionData) public coverIdCommission;

    /** 
     * @dev mapping of user to boolean to determine if user is migrated.    
     */
    mapping(address => bool) public userMigrated;

    /** 
     * @dev Modifier that ensure that transaction is from internal contracts only.
     */
    modifier onlyInternal {
        ms = NXMaster(mr.nxMasterAddress());
        require(ms.isInternal(msg.sender));
        _;
    }

    /** 
     * @dev Event to raise while any user raise dissallocation request.
     */
    event DisalloctionRequest(address indexed _user);

    /** 
     * @dev Event to raise while any user migrates.
     */
    event Migrated(address indexed _user);

    /** 
     * @dev Event to raise while any user claim their commission.
     */
    event CommissionClaimed(address indexed _user, uint _amount);

    /** 
     * @dev Event to raise while any user increases global stake.
     */
    event IncreaseStake(address indexed _user, uint _amount);

    /** 
     * @dev Event to raise while any user decreases global stake.
     */
    event DecreaseStake(address indexed _user, uint _amount);

    /** 
     * @dev Event to raise while any user increases stake allocation.
     */
    event IncreaseAllocation(address indexed _user, address indexed _scAddress, uint _amount);

    /** 
     * @dev Event to raise while any user decreases stake allocation.
     */
    event DecreaseAllocation(address indexed _user, address indexed _scAddress, uint _amount);

    constructor(address _mrAdd) public {

        mr = MemberRoles(_mrAdd);
        maxAllocationPerx100 = 1000;
        minAllocationPerx100 = 200;
        minStake = 100 * DECIMAL1E18;
        globalMaxStakeMultiplier = 2;
        disallocateEffectTime = 90 * 1 days;

    }

    /**
     * @dev Updates Global stake of staker.
     * @param staker address of staker.
     * @param amount amount of NXM to be updated.
     */
    function updateGlobalStake(address staker, uint amount) external onlyInternal
    {
        globalStake[staker] = amount;
    }

    /**
     * @dev Marks user as migrated.
     * @param _user address of user.
     */
    function setUserMigrated(address _user) external onlyInternal
    {
        userMigrated[_user] = true;
    }

    /**
     * @dev Decreases Global burned of staker.
     * @param staker address of staker.
     * @param amount amount of NXM burned to reduce.
     */
    function decreaseGlobalBurn(address staker, uint amount) external onlyInternal
    {
        globalBurned[staker] = globalBurned[staker].sub(amount);
    }

    /**
     * @dev Increases Global burned of staker.
     * @param staker address of staker.
     * @param amount amount of NXM burned to increase.
     */
    function increaseGlobalBurn(address staker, uint amount) external onlyInternal
    {
        globalBurned[staker] = globalBurned[staker].add(amount);
    }

    /**
     * @dev Updates coverid till which user had claimed commission.
     * @param staker address of staker.
     * @param coverId cover id till which user had claimed.
     */
    function updateLastClaimedforCoverId(address staker, uint coverId) external onlyInternal 
    {
        lastClaimedforCoverId[staker] = coverId; 
    }

    /**
     * @dev Adjusts allocation to keep actual staked NXM against each contract.
     * @param staker address of staker.
     * @param differenceAmount amount unstaked.
     * @param _type True if, called from decrease stake. False if, called from increase stake.
     */
    function updateAllocations(address staker, uint differenceAmount, bool _type) external onlyInternal {
        uint stakedLen = stakerStakedContracts[staker].length;
        uint previousStake = globalStake[staker];
        for (uint i=0; i < stakedLen; i++) {
            uint updatedPer;
            if (_type) {

                updatedPer = previousStake.mul(stakerStakedContracts[staker][i].allocationx100)
                .div(previousStake.sub(differenceAmount));
            } else {

                updatedPer = previousStake.mul(stakerStakedContracts[staker][i].allocationx100)
                .div(previousStake.add(differenceAmount));
            }

            stakerStakedContracts[staker][i].allocationx100 = updatedPer;
            stakedContractStakers[stakerStakedContracts[staker][i].smartContract][uint(getUserSCIndex(staker,
            stakerStakedContracts[staker][i].smartContract))].allocationx100 = updatedPer;

        }   
    }

    /**
     * @dev Pushes stake data into array.
     * @param staker address of staker.
     * @param smartContract sc against which stake is allocated.
     * @param allocationx100 allocated percentx100.
     */
    function pushStakeData(address staker, address smartContract, uint allocationx100) external onlyInternal {
          
        userSCIndex[staker][smartContract] = stakedContractStakers[smartContract].length;
        scUserIndex[smartContract][staker] = stakerStakedContracts[staker].length;  
        stakedContractStakers[smartContract].push(Staker(staker, allocationx100));
        stakerStakedContracts[staker].push(Staked(smartContract, allocationx100));
        userTotalAllocated[staker] = userTotalAllocated[staker].add(allocationx100);
    }

    /**
     * @dev Pushes dissallocation requests into array.
     * @param staker address of staker.
     * @param smartContract sc against which allocation is to reduce.
     * @param disAllocationx100 percentx100 to reduce.
     */
    function pushDecreaseAllocationRequest(
        address staker, 
        address smartContract, 
        uint disAllocationx100
        ) 
        external 
        onlyInternal 
    {
        userDisallocationRequest[staker].push(
            DecreaseAllocationRequest(
                smartContract, 
                disAllocationx100, 
                uint(now).add(disallocateEffectTime))
            );
    }

    /**
     * @dev Increases stake allocations.
     * @param staker address of staker.
     * @param smartContract sc against which stake is allocated.
     * @param allocationx100 allocation to increase percentx100.
     */
    function increaseStakeAllocation(
        address staker, 
        address smartContract, 
        uint allocationx100
        ) 
        external 
        onlyInternal 
    {
          
        uint indexUserSC = userSCIndex[staker][smartContract];
        stakedContractStakers[smartContract][indexUserSC].allocationx100 = stakedContractStakers[smartContract]
        [indexUserSC].allocationx100.add(allocationx100);
        uint indexSCUser = scUserIndex[smartContract][staker]; 
        stakerStakedContracts[staker][indexSCUser].allocationx100 = stakerStakedContracts[staker]
        [indexSCUser].allocationx100.add(allocationx100);  
        userTotalAllocated[staker] = userTotalAllocated[staker].add(allocationx100);
    }

    /**
     * @dev Decreases stake allocations.
     * @param staker address of staker.
     * @param smartContract sc against which stake is allocated.
     * @param allocationx100 allocation to decrease percentx100.
     */
    function decreaseStakeAllocation(
        address staker, 
        address smartContract, 
        uint allocationx100
        ) 
        external 
        onlyInternal 
    {

        uint indexUserSC = userSCIndex[staker][smartContract];
        stakedContractStakers[smartContract][indexUserSC].allocationx100 = stakedContractStakers[smartContract]
        [indexUserSC].allocationx100.sub(allocationx100);
        uint indexSCUser = scUserIndex[smartContract][staker]; 
        stakerStakedContracts[staker][indexSCUser].allocationx100 = stakerStakedContracts[staker]
        [indexSCUser].allocationx100.sub(allocationx100);  
        userTotalAllocated[staker] = userTotalAllocated[staker].sub(allocationx100);
        if (stakedContractStakers[smartContract][indexUserSC].allocationx100 == 0) {
            _removeRecord(staker, smartContract);
        }
    }

    /**
     * @dev Sets index upto which disallocation requests are executed for given user.
     * @param staker address of staker.
     * @param index index upto which disallocation requests are executed.
     */
    function setUserDisallocationExecuted(address staker, uint index) external onlyInternal {
          
        userDisallocationExecuted[staker] = index;
    }

    /**
     * @dev Updates burned stake data against claim id.
     * @param claimid claim id.
     * @param burntByStakedRatio ratio of amount of nxm burned by amount of nxm staked against sc at time of burning.
     */
    function setClaimIdBurnedStake(uint claimid, uint burntByStakedRatio) external onlyInternal {

        claimIdBurnedStake[claimid] = BurnedStake(now, burntByStakedRatio);
    }

    /**
     * @dev Updates Commission to be distributed against coverId.
     * @param coverId cover id against which reward is to be distributed.
     * @param reward amount of nxm to be distributed.
     * @param stakedNXM amount of nxm staked against sc at time of cover purchase.
     */
    function setCoverIdCommission(uint coverId, uint reward, uint stakedNXM) external onlyInternal {

        coverIdCommission[coverId] = CommissionData(reward, stakedNXM);
    }

    /**
     * @dev Emits events for appropriate type.
     * @param _user address of user.
     * @param _scAdd address of smart contract.
     * @param _amount amount of nxm claimed.
     * @param _type It determines type of event to emit. 1 for dissallocation request,
     * 2 for migration, 3 for commission claimed, 4 for increase stake, 5 for decrease stake.
     * 6 for increase allocation, 7 for decrease allocation.
     */
    function callEvent(address _user, address _scAdd, uint _amount, uint _type) external onlyInternal {

        if(_type == 1)
        {
            emit DisalloctionRequest(_user);

        } else if(_type == 2) {

            emit Migrated(_user);

        } else if(_type == 3) {

            emit CommissionClaimed(_user, _amount);

        } else if(_type == 4) {

            emit IncreaseStake(_user, _amount);

        } else if(_type == 5) {

            emit DecreaseStake(_user, _amount);

        } else if(_type == 6) {
            emit IncreaseAllocation(_user, _scAdd, _amount);

        } else if(_type == 7) {
            emit DecreaseAllocation(_user, _scAdd, _amount);

        } else {

            revert("invalid type");
        }

    }
    
    /**
     * @dev Updates Uint Parameters of a code
     * @param code whose details we want to update
     * @param val value to set
     */
    function updateUintParameters(bytes8 code, uint val) external {
        ms = NXMaster(mr.nxMasterAddress());
        require(ms.checkIsAuthToGoverned(msg.sender));
        if (code == "MAXALOC") {

            _setMaxAllocationPerx100(val); 

        } else if (code == "MINALOC") {

            _setMinAllocationPerx100(val);

        } else if (code == "MINSTK") {

            _setMinStake(val);

        } else if (code == "GLSTKMUL") {

            _setGlobalMaxStakeMultiplier(val);

        } else if (code == "DSALCT") {

            _setDisallocateEffectTime(val);

        } else {
            revert("Invalid param code");
        }
         
    }

    /**
     * @dev Gets Uint Parameters of a code
     * @param code whose details we want
     * @return string value of the code
     * @return associated amount (time or perc or value) to the code
     */
    function getUintParameters(bytes8 code) external view returns(bytes8 codeVal, uint val) {
        codeVal = code;
        if (code == "MAXALOC") {

            val = maxAllocationPerx100; 

        } else if (code == "MINALOC") {

            val = minAllocationPerx100;

        } else if (code == "MINSTK") {

            val = minStake;

        } else if (code == "GLSTKMUL") {

            val = globalMaxStakeMultiplier;

        } else if (code == "DSALCT") {

            val = disallocateEffectTime;

        }  
    }

    /**
     * @dev Gets NXM staked for mentioned smart contract.
     * @param _stakedContractAddress address of staked smart cover.
     * @return total total nxms.
     */
    function getTotalStakedTokensOnSmartContract(address _stakedContractAddress) external view returns(uint total) {
        uint len = stakedContractStakers[_stakedContractAddress].length;
        for (uint i=0; i < len; i++) {

            total = total.add(stakedContractStakers[_stakedContractAddress][i].allocationx100.mul(
            globalStake[stakedContractStakers[_stakedContractAddress][i].stakerAddress].sub(
            globalBurned[stakedContractStakers[_stakedContractAddress][i].stakerAddress])));
        }
    }

    /**
     * @dev Gets max unstakable tokens.
     * @param staker address of staker.
     * @return val max amount unstakable.
     */
    function getMaxUnstakable(address staker) external view returns(uint val)
    {
        // (SNXM - SBurn) 
        uint actualStake = globalStake[staker].sub(globalBurned[staker]);
        // (100 - sum(P))
        uint proportion = uint(MAX_TOTAL_STAKE).sub(userTotalAllocated[staker]);
        // 10 * (Max Stake% - MaxPn), multiplying with 10 so both proportion can have same format (divide by 100)
        uint proportion1 = ((maxAllocationPerx100).sub(getMaxAllocation(staker))).mul(10);

        if (proportion > proportion1) {
            proportion = proportion1;
        }

        val = actualStake.mul(proportion).div(MAX_TOTAL_STAKE);
    }

    /**
     * @dev Gets max allocation.
     * @param staker address of staker.
     * @return max maximum allocation by staker.
     */
    function getMaxAllocation(address staker) public view returns(uint max)
    {
        uint stakedLen = stakerStakedContracts[staker].length;
        for (uint i=0; i < stakedLen; i++) {
            if (stakerStakedContracts[staker][i].allocationx100 > max)
                max = stakerStakedContracts[staker][i].allocationx100;
        }

    }

    /**
     * @dev Gets mapped index for smart contract to user.
     * @param smartContract address of smart cover.
     * @param staker address of staker.
     * @return index mapped index.
     */
    function getScUserIndex(address smartContract, address staker) public view returns(int index)
    {
        index = int(scUserIndex[smartContract][staker]);
        if (stakerStakedContracts[staker].length == 0) {
            return -1;
        }
        if (index == 0) {
            if (smartContract != stakerStakedContracts[staker][uint(index)].smartContract)
                return -1;
        }
    }

    /**
     * @dev Gets mapped index for user to smart contract.
     * @param staker address of staker.
     * @param smartContract address of smart cover.
     * @return index mapped index.
     */
    function getUserSCIndex(address staker, address smartContract) public view returns(int index)
    {
        index = int(userSCIndex[staker][smartContract]);
        if (stakedContractStakers[smartContract].length == 0) {
            return -1;
        }
        if (index == 0) {
            if (staker != stakedContractStakers[smartContract][uint(index)].stakerAddress)
                return -1;
        }
    }

    /**
     * @dev Gets length of dissallocation requests.
     * @param staker address of staker.
     * @return len length.
     */
    function getDissallocationLen(address staker) public view returns(uint len)
    {
        len = userDisallocationRequest[staker].length;
    }

    /**
     * @dev Gets total number of staker staked against a smart cover.
     * @param smartContractAddress address of smart contract.
     * @return len length.
     */
    function getTotalStakerAgainstSC(address smartContractAddress) public view returns(uint len)
    {
        len = stakedContractStakers[smartContractAddress].length;
    }

    /**
     * @dev Gets total number of NXM staked in actual.
     * @param stakerAdd address of staker.
     * @return stakeAmt actual staked amount.
     */
    function getActualGlobalStake(address stakerAdd) public view returns(uint stakeAmt)
    {
        stakeAmt = globalStake[stakerAdd].sub(globalBurned[stakerAdd]);
    }

    /**
     * @dev to remove staker data from structure if allocation becomes 0.
     * @param staker address of staker.
     * @param smartContract address of smart contract.
     */
    function _removeRecord(address staker, address smartContract) internal {
        uint indexUserSC = userSCIndex[staker][smartContract];
        uint indexSCUser = scUserIndex[smartContract][staker]; 
        stakedContractStakers[smartContract][indexUserSC] = stakedContractStakers[smartContract]
        [stakedContractStakers[smartContract].length.sub(1)];
        stakerStakedContracts[staker][indexSCUser] = stakerStakedContracts[staker]
        [stakerStakedContracts[staker].length.sub(1)];  
        userSCIndex[stakedContractStakers[smartContract][indexUserSC].stakerAddress][smartContract] = indexUserSC;
        scUserIndex[stakerStakedContracts[staker][indexSCUser].smartContract][staker] = indexSCUser;
        userSCIndex[staker][smartContract] = 0;
        scUserIndex[smartContract][staker] = 0;
        stakedContractStakers[smartContract].pop();
        stakerStakedContracts[staker].pop();
    }

    /**
     * @dev to set the maximum allocation for single smart cover
     * @param _val is new percentage value (x100)
     */
    function _setMaxAllocationPerx100(uint _val) internal {
        maxAllocationPerx100 = _val;
    }

    /**
     * @dev to set the minimum allocation for single smart cover
     * @param _val is new percentage value (x100)
     */
    function _setMinAllocationPerx100(uint _val) internal {
        minAllocationPerx100 = _val;
    }

    /**
     * @dev to set the minimum stake allowed
     * @param _val is new min stake value
     */
    function _setMinStake(uint _val) internal {
        minStake = _val;
    }

    /**
     * @dev to set global max stake multiplier 
     * @param _val is new value
     */
    function _setGlobalMaxStakeMultiplier(uint _val) internal {
        globalMaxStakeMultiplier = _val;
    }

    /**
     * @dev to set minimum time between disallocation request and effect. 
     * @param _val is new value
     */
    function _setDisallocateEffectTime(uint _val) internal {
        disallocateEffectTime = _val;
    }
}