pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SDAOBondedTokenStake is Ownable{

    using SafeMath for uint256;

    ERC20 public token; // Address of token contract

    struct StakeInfo {
        bool exist;
        uint256 approvedAmount;
        uint256 rewardComputeIndex;
    }

    // Staking period timestamp (Debatable on timestamp vs blocknumber - went with timestamp)
    struct StakePeriod {
        uint256 startPeriod;
        uint256 submissionEndPeriod;
        uint256 endPeriod;

        uint256 maxStake;

        uint256 windowRewardAmount;
        
    }

    address public tokenOperator; // Address to manage the Stake 

    uint256 public maxAirDropStakeBlocks; // Block numbers to complete the airDrop Auto Stakes

    mapping (address => uint256) public balances; // Useer Token balance in the contract

    uint256 public currentStakeMapIndex; // Current Stake Index to avoid math calc in all methods

    mapping (uint256 => StakePeriod) public stakeMap;

    // List of Stake Holders
    address[] stakeHolders; 

    // All Stake Holders
    mapping(address => StakeInfo) stakeHolderInfo;

    // To store the total stake in a window
    uint256 public windowTotalStake;

    // Events
    event NewOperator(address tokenOperator);

    event WithdrawToken(address indexed tokenOperator, uint256 amount);

    event OpenForStake(uint256 indexed stakeIndex, address indexed tokenOperator, uint256 startPeriod, uint256 endPeriod, uint256 rewardAmount);
    event SubmitStake(uint256 indexed stakeIndex, address indexed staker, uint256 stakeAmount);
    event WithdrawStake(uint256 indexed stakeIndex, address indexed staker, uint256 stakeAmount);
    event ClaimStake(uint256 indexed stakeIndex, address indexed staker, uint256 totalAmount);
    event AddReward(address indexed staker, uint256 indexed stakeIndex, address tokenOperator, uint256 stakeAmount, uint256 rewardAmount, uint256 windowTotalStake);


    // Modifiers
    modifier onlyOperator() {
        require(
            msg.sender == tokenOperator,
            "Only operator can call this function."
        );
        _;
    }

    // Token Operator should be able to do auto renewal
    modifier allowSubmission() {        
        require(
            now >= stakeMap[currentStakeMapIndex].startPeriod && 
            now <= stakeMap[currentStakeMapIndex].submissionEndPeriod, 
            "Staking at this point not allowed"
        );
        _;
    }

    modifier validStakeLimit(address staker, uint256 stakeAmount) {

        uint256 stakerTotalStake;
        stakerTotalStake = stakeAmount.add(stakeHolderInfo[staker].approvedAmount);

        // Check for Min Stake
        require(
            stakeAmount > 0 && 
            stakerTotalStake <= stakeMap[currentStakeMapIndex].maxStake,
            "Need to have min stake"
        );
        _;

    }

    // SRIDHAR -------- Need to check the logic -- Check whether we need to verify with the CurrentStakeMap Index
    // ---- Need to improvise the condition check

    // Check for claim - Stake Window should be either in submission phase or after end period
    modifier allowClaimStake(uint256 stakeMapIndex) {

        require(
          (now >= stakeMap[currentStakeMapIndex].startPeriod && now <= stakeMap[currentStakeMapIndex].submissionEndPeriod && stakeHolderInfo[msg.sender].approvedAmount > 0) || 
          (now > stakeMap[currentStakeMapIndex].endPeriod && stakeHolderInfo[msg.sender].approvedAmount > 0), "Invalid claim request");
        _;

    }

    constructor(address _token, uint256 _maxAirDropStakeBlocks)
    public
    {
        token = ERC20(_token);
        tokenOperator = msg.sender;
        currentStakeMapIndex = 0;
        windowTotalStake = 0;
        maxAirDropStakeBlocks = _maxAirDropStakeBlocks.add(block.number); 
    }

    function updateOperator(address newOperator) public onlyOwner {

        require(newOperator != address(0), "Invalid operator address");
        
        tokenOperator = newOperator;

        emit NewOperator(newOperator);
    }
    
    function withdrawToken(uint256 value) public onlyOperator
    {

        // Check if contract is having required balance 
        require(token.balanceOf(address(this)) >= value, "Not enough balance in the contract");
        require(token.transfer(msg.sender, value), "Unable to transfer token to the operator account");

        emit WithdrawToken(tokenOperator, value);
        
    }

    function openForStake(uint256 _startPeriod, uint256 _submissionEndPeriod, uint256 _endPeriod, uint256 _windowRewardAmount, uint256 _maxStake) public onlyOperator {

        // Check Input Parameters
        require(_startPeriod >= now && _startPeriod < _submissionEndPeriod && _submissionEndPeriod < _endPeriod, "Invalid stake period");
        require(_windowRewardAmount > 0 && _maxStake > 0, "Invalid inputs" );

        // Check Stake in Progress
        require(currentStakeMapIndex == 0 || (now > stakeMap[currentStakeMapIndex].submissionEndPeriod && _startPeriod >= stakeMap[currentStakeMapIndex].endPeriod), "Cannot have more than one stake request at a time");

        // Move the staking period to next one
        currentStakeMapIndex = currentStakeMapIndex + 1;
        StakePeriod memory stakePeriod;

        // Set Staking attributes
        stakePeriod.startPeriod = _startPeriod;
        stakePeriod.submissionEndPeriod = _submissionEndPeriod;
        stakePeriod.endPeriod = _endPeriod;
        stakePeriod.windowRewardAmount = _windowRewardAmount;
        stakePeriod.maxStake = _maxStake;

        stakeMap[currentStakeMapIndex] = stakePeriod;

        // Add the current window reward to the window total stake 
        windowTotalStake = windowTotalStake.add(_windowRewardAmount);

        emit OpenForStake(currentStakeMapIndex, msg.sender, _startPeriod, _endPeriod, _windowRewardAmount);

    }

    // To add the Stake Holder
    function _createStake(address staker, uint256 stakeAmount) internal returns(bool) {

        StakeInfo storage stakeInfo = stakeHolderInfo[staker];

        // Check if the user already staked in the past
        if(stakeInfo.exist) {

            stakeInfo.approvedAmount = stakeInfo.approvedAmount.add(stakeAmount);

        } else {

            StakeInfo memory req;

            // Create a new stake request
            req.exist = true;
            req.approvedAmount = stakeAmount;
            req.rewardComputeIndex = 0;

            // Add to the Stake Holders List
            stakeHolderInfo[staker] = req;

            // Add to the Stake Holders List
            stakeHolders.push(staker);

        }

        return true;

    }


    // To submit a new stake for the current window
    function submitStake(uint256 stakeAmount) public allowSubmission validStakeLimit(msg.sender, stakeAmount) {

        // Transfer the Tokens to Contract
        require(token.transferFrom(msg.sender, address(this), stakeAmount), "Unable to transfer token to the contract");

        _createStake(msg.sender, stakeAmount);

        // Update the User balance
        balances[msg.sender] = balances[msg.sender].add(stakeAmount);

        // Update current stake period total stake - For Auto Approvals
        windowTotalStake = windowTotalStake.add(stakeAmount); 
       
        emit SubmitStake(currentStakeMapIndex, msg.sender, stakeAmount);

    }


    // SRIDHAR -- Check for the common modifier for Claim & withdraw stake functions....

    // To withdraw stake during submission phase
    function withdrawStake(uint256 stakeMapIndex, uint256 stakeAmount) public {

        require(
            (now >= stakeMap[stakeMapIndex].startPeriod && now <= stakeMap[stakeMapIndex].submissionEndPeriod),
            "Stake withdraw at this point is not allowed"
        );

        StakeInfo storage stakeInfo = stakeHolderInfo[msg.sender];

        // Validate the input Stake Amount
        require(stakeAmount > 0 && stakeInfo.approvedAmount >= stakeAmount, "Cannot withdraw beyond stake amount");

        // Update the staker balance in the staking window
        stakeInfo.approvedAmount = stakeInfo.approvedAmount.sub(stakeAmount);

        // Update the User balance
        balances[msg.sender] = balances[msg.sender].sub(stakeAmount);

        // Update current stake period total stake - For Auto Approvals
        windowTotalStake = windowTotalStake.sub(stakeAmount); 

        // Return to User Wallet
        require(token.transfer(msg.sender, stakeAmount), "Unable to transfer token to the account");

        emit WithdrawStake(stakeMapIndex, msg.sender, stakeAmount);
    }


    function _calculateRewardAmount(uint256 stakeMapIndex, uint256 stakeAmount) internal view returns(uint256) {

        uint256 calcRewardAmount;
        calcRewardAmount = stakeAmount.mul(stakeMap[stakeMapIndex].windowRewardAmount).div(windowTotalStake.sub(stakeMap[stakeMapIndex].windowRewardAmount));
        return calcRewardAmount;
    }


    // Update reward for staker in the respective stake window
    function computeAndAddReward(uint256 stakeMapIndex, address staker) 
    public 
    onlyOperator
    returns(bool)
    {

        // Check for the Incubation Period
        require(
            now > stakeMap[stakeMapIndex].submissionEndPeriod && 
            now < stakeMap[stakeMapIndex].endPeriod, 
            "Reward cannot be added now"
        );

        StakeInfo storage stakeInfo = stakeHolderInfo[staker];

        // Check if reward already computed
        require(stakeInfo.approvedAmount > 0 && stakeInfo.rewardComputeIndex != stakeMapIndex, "Invalid reward request");

        // Calculate the totalAmount
        uint256 totalAmount;
        uint256 rewardAmount;

        // Calculate the reward amount for the current window
        totalAmount = stakeInfo.approvedAmount;
        rewardAmount = _calculateRewardAmount(stakeMapIndex, totalAmount);
        totalAmount = totalAmount.add(rewardAmount);

        // Add the reward amount
        stakeInfo.approvedAmount = totalAmount;

        // Update the reward compute index to avoid mulitple addition
        stakeInfo.rewardComputeIndex = stakeMapIndex;

        // Update the User Balance
        balances[staker] = balances[staker].add(rewardAmount);

        emit AddReward(staker, stakeMapIndex, tokenOperator, totalAmount, rewardAmount, windowTotalStake);

        return true;
    }

    function updateRewards(uint256 stakeMapIndex, address[] calldata staker) 
    external 
    onlyOperator
    {
        for(uint256 indx = 0; indx < staker.length; indx++) {
            require(computeAndAddReward(stakeMapIndex, staker[indx]));
        }
    }

    // To claim from the stake window
    function claimStake(uint256 stakeMapIndex) public allowClaimStake(stakeMapIndex) {

        StakeInfo storage stakeInfo = stakeHolderInfo[msg.sender];

        uint256 stakeAmount;

        // No more stake windows or in submission phase
        stakeAmount = stakeInfo.approvedAmount;
        stakeInfo.approvedAmount = 0;

        // Update current stake period total stake
        windowTotalStake = windowTotalStake.sub(stakeAmount);

        // Check for balance in the contract
        require(token.balanceOf(address(this)) >= stakeAmount, "Not enough balance in the contract");

        // Update the User Balance
        balances[msg.sender] = balances[msg.sender].sub(stakeAmount);

        // Call the transfer function
        require(token.transfer(msg.sender, stakeAmount), "Unable to transfer token back to the account");

        emit ClaimStake(stakeMapIndex, msg.sender, stakeAmount);

    }

    // AirDrop to Stake - Load existing stakes from Air Drop
    function airDropStakes(uint256 stakeMapIndex, address[] calldata staker, uint256[] calldata stakeAmount) external onlyOperator {

        // Add check for Block Number to restrict air drop auto stake phase after certain block number
        require(block.number < maxAirDropStakeBlocks, "Exceeds airdrop auto stake phase");

        // Check Input Parameters
        require(staker.length == stakeAmount.length, "Invalid Input Arrays");

        // Stakers should be for current window
        require(currentStakeMapIndex == stakeMapIndex, "Invalid Stake Window Index");

        for(uint256 indx = 0; indx < staker.length; indx++) {

            StakeInfo memory req;

            // Create a stake request with approvedAmount
            req.exist = true;
            req.approvedAmount = stakeAmount[indx];
            req.rewardComputeIndex = stakeMapIndex;

            // Add to the Stake Holders List
            stakeHolderInfo[staker[indx]] = req;

            // Add to the Stake Holders List
            stakeHolders.push(staker[indx]);

            // Update the User balance
            balances[staker[indx]] = stakeAmount[indx];

            // Update current stake period total stake - Along with Reward
            windowTotalStake = windowTotalStake.add(stakeAmount[indx]);

        }

    }


    // Getter Functions    
    function getStakeHolders() public view returns(address[] memory) {
        return stakeHolders;
    }


    // SRIDHAR --- Storage can be changed to Memory

    function getStakeInfo(address staker) 
    public 
    view
    returns (bool found, uint256 approvedAmount, uint256 rewardComputeIndex) 
    {

        StakeInfo storage stakeInfo = stakeHolderInfo[staker];
        
        found = false;
        if(stakeInfo.exist) {
            found = true;
        }

        approvedAmount = stakeInfo.approvedAmount;
        rewardComputeIndex = stakeInfo.rewardComputeIndex;

    }


}