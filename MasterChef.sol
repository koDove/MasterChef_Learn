//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./CakeToken.sol";

contract MasterChef is Ownable {
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accCakePerShare;
    }

    //거버넌스 토큰(케이크 토큰)
    CakeToken public cake;
    PoolInfo[] public poolInfo;

    //케이크 토큰이 발행(mint)될 때 일부 운용 비용을 개발자 계정으로 발행하기 위함.
    address public devaddr;

    //하나의 블록마다 몇개의 cake토큰을 줄것인가.
    uint256 public cakePerBlock;

    //UserInfo를 저장할 변수
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    //Pool마다 다른 Alloc포인트를 통합해서 관리하는 변수(풀이 증가할때마다 증가)
    uint256 public totalAllocPoint = 0;

    //언제 마스터셰프 컨트랙트가 동작을 하고 민팅을 할것인지 지정하는 변수
    uint256 public startBlock;

    //이벤트 정의
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    ); //긴급상황(해킹 상황 등과 같은 긴급상황 시 호출)

    constructor(
        CakeToken _cake,
        address _devaddr,
        uint256 _cakePerBlock, //블록당 몇개의 토큰?
        uint256 _startBlock
    ) {
        cake = _cake;
        devaddr = _devaddr;
        cakePerBlock = _cakePerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    } //마스터셰프에 존재하는 풀 갯수를 리턴한다.

    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        } //대부분의 경우 호출하지 않는 것이 좋을 것(대규모 가스 소모)

        //해당 풀에서 해당 풀에서 마지막으로 받아간 리워드를 계산한다.
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;

        //여기서 전달하는 _allocPoint가 높을수록 전체풀이 받아가는 cake토큰이 분산되기 때문에 중요하다.
        totalAllocPoint = totalAllocPoint + _allocPoint;

        //실제로 풀을 추가한다.
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accCakePerShare: 0
            })
        );
    } //마스트셰프 컨트랙트에 추가될 LP 토큰의 스테이킹 풀이 이 함수를 통해 수행된다.

    //TotalAllocPoint가 증가할수록 풀이 받아가는 cake토큰의 갯수가 줄어든다.
    //때문에 함부로 풀이 추가되는 것을 방지하도록 onlyOwner를 적용한다.

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        //통합 풀에서 해당 풀의 기존 allocPoint를 빼야하기 때문에 가져온다.
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;

        //해당 풀의 allocPoint를 업데이트한다.
        poolInfo[_pid].allocPoint = _allocPoint;

        //이를 통합풀에 반영한다.
        if (prevAllocPoint != _allocPoint) {
            //변경하는 값이 똑같으면 연산을 수행할 필요가 없다.(근데 이걸 왜 여기서 해줄까? 93줄도 묶을수있을텐데)
            totalAllocPoint = totalAllocPoint - prevAllocPoint + _allocPoint;
        }
    } //풀의 allocPoint를 변경한다.

    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public pure returns (uint256) {
        return _to - _from;
    } //현재 블록에서 lastReward블록을 뺀 값을 반환한다.

    //매개변수로 풀의 pid와 user Account를 받아온다.
    function pendingCake(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        //이전 구간까지의 accCakePerShare를 구한다.
        uint256 accCakePerShare = pool.accCakePerShare;

        //마스터셰프에 Staking된 LP토큰(cake)의 개수를 가져온다.
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            //멀티파이어를 구한다.
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 cakeReward = (multiplier * cakePerBlock * pool.allocPoint) /
                totalAllocPoint;

            //바로 전 구간에 저장된 값 + (현재 리워드 / 전체스테이킹량)
            //즉 토큰 당 받게되는 Cake토큰의 양을 구한다.
            accCakePerShare =
                accCakePerShare +
                ((cakeReward * 1e12) / lpSupply);
        }
        // (현재 스테이킹한 유저의 잔액 * 전체 발행된 토큰당 리워드 토큰)-유저가 이전 구간에서 수령한 리워드
        return (user.amount * accCakePerShare) / 1e12 - user.rewardDebt;
    } //프론트엔드에서 유저가 아직 수령하지 않은 Cake토큰을 확인한다.

    //이게 젤 중요한 함수라고 친다.

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    } //전체 풀 업데이트(가스소모 극심)

    function updatePool(uint256 _pid) public {
        //어떤 풀을 업데이트할지 정보를 가져옴.
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        //현재 스테이킹된 LP토큰의 개수를 가져온다.
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        //몇개의 블록이 지났는지 계산하고 몇개의 보상토큰을 나눠줄것인지 계산한다.(PendingCake와 비슷한 로직)
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 cakeReward = (multiplier * cakePerBlock * pool.allocPoint) /
            totalAllocPoint;

        cake.mint(devaddr, cakeReward / 10); //수수료
        cake.mint(address(this), cakeReward);

        pool.accCakePerShare =
            pool.accCakePerShare +
            ((cakeReward * 1e12) / lpSupply);
    } //accCakePerShare를 업데이트한다.

    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        if (user.amount > 0) {
            //전체 토큰 중 기존에 받아간 보상 토큰을 제외하고 pending 토큰으로 저장한다.
            uint256 pending = (user.amount * pool.accCakePerShare) /
                1e12 -
                user.rewardDebt;

            //저장된 pending 토큰을 유저가 수령해간다.
            if (pending > 0) {
                cake.transfer(msg.sender, pending);
            }
        }

        if (_amount > 0) {
            pool.lpToken.transferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
        }

        //유저가 받아간 토큰을 최신화한다.
        user.rewardDebt = (user.amount * pool.accCakePerShare) / 1e12;
    } //deposit(staking)을 할때 거버넌스 토큰이 발행된다.

    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = (user.amount * pool.accCakePerShare) /
            1e12 -
            user.rewardDebt;
        if (pending > 0) {
            cake.transfer(msg.sender, pending);
        }

        if (_amount > 0) {
            user.amount = user.amount - _amount;
            pool.lpToken.transfer(address(msg.sender), _amount);
        }

        user.rewardDebt = (user.amount * pool.accCakePerShare) / 1e12;
        emit Withdraw(msg.sender, _pid, _amount);
    } //unstake 기능을 수행함

    function energencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.transfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    } //긴급 상황 발생 시 수행되는 긴급 unstake기능이다. 유저가 각자 stake한 토큰을 가져간다.

    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    } //수수료를 받을 개발자
}
