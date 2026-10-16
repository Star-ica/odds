// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Simple parimutuel YES/NO markets. Everyone who bet on the winning side shares the whole pool
/// (minus a 2% fee) in proportion to their stake. A designated resolver (an address you trust,
/// a multisig, or an oracle adapter contract) reports the outcome.
/// If nobody bet on the winning side, or the resolver stays silent for 7 days, everyone is refunded.
contract NichePredictionMarket {
    struct Market {
        string question;
        uint64 closeTime;
        address resolver;
        uint256 yesPool;
        uint256 noPool;
        bool resolved;
        bool outcome; // true = YES won
        bool voided;
    }

    uint256 public constant FEE_BPS = 200;
    uint256 public constant VOID_AFTER = 7 days;
    address public immutable owner;
    uint256 public fees;

    Market[] private markets;
    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public claimed;

    event MarketCreated(uint256 indexed id, string question, uint64 closeTime, address resolver);
    event Bet(uint256 indexed id, address indexed user, bool yes, uint256 amount);
    event Resolved(uint256 indexed id, bool outcome, bool voided);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);

    constructor() { owner = msg.sender; }

    function marketCount() external view returns (uint256) { return markets.length; }

    function createMarket(string calldata question, uint64 closeTime, address resolver) external returns (uint256 id) {
        require(closeTime > block.timestamp, "Close time in the past");
        require(resolver != address(0), "No resolver");
        id = markets.length;
        Market storage m = markets.push();
        m.question = question;
        m.closeTime = closeTime;
        m.resolver = resolver;
        emit MarketCreated(id, question, closeTime, resolver);
    }

    function bet(uint256 id, bool yes) external payable {
        Market storage m = markets[id];
        require(block.timestamp < m.closeTime, "Betting closed");
        require(msg.value > 0, "Send some ETH");
        if (yes) { m.yesPool += msg.value; yesStake[id][msg.sender] += msg.value; }
        else { m.noPool += msg.value; noStake[id][msg.sender] += msg.value; }
        emit Bet(id, msg.sender, yes, msg.value);
    }

    /// 0 open, 1 awaiting result, 2 resolved, 3 void (refunds)
    function status(uint256 id) public view returns (uint8) {
        Market storage m = markets[id];
        if (m.voided) return 3;
        if (m.resolved) return 2;
        if (block.timestamp < m.closeTime) return 0;
        if (block.timestamp > m.closeTime + VOID_AFTER) return 3;
        return 1;
    }

    function resolve(uint256 id, bool outcome) external {
        Market storage m = markets[id];
        require(msg.sender == m.resolver, "Only resolver");
        require(status(id) == 1, "Not ready to resolve");
        uint256 winPool = outcome ? m.yesPool : m.noPool;
        if (winPool == 0) {
            m.voided = true;
            emit Resolved(id, outcome, true);
            return;
        }
        m.resolved = true;
        m.outcome = outcome;
        uint256 total = m.yesPool + m.noPool;
        fees += total - (total * (10000 - FEE_BPS)) / 10000;
        emit Resolved(id, outcome, false);
    }

    function claim(uint256 id) external {
        uint8 s = status(id);
        require(s == 2 || s == 3, "Nothing to claim yet");
        require(!claimed[id][msg.sender], "Already claimed");
        Market storage m = markets[id];
        uint256 payout;
        if (s == 3) {
            payout = yesStake[id][msg.sender] + noStake[id][msg.sender];
        } else {
            uint256 stake = m.outcome ? yesStake[id][msg.sender] : noStake[id][msg.sender];
            uint256 winPool = m.outcome ? m.yesPool : m.noPool;
            uint256 pot = ((m.yesPool + m.noPool) * (10000 - FEE_BPS)) / 10000;
            payout = (stake * pot) / winPool;
        }
        require(payout > 0, "Nothing to claim");
        claimed[id][msg.sender] = true;
        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "Transfer failed");
        emit Claimed(id, msg.sender, payout);
    }

    function withdrawFees() external {
        require(msg.sender == owner, "Only owner");
        uint256 amt = fees;
        fees = 0;
        (bool ok, ) = owner.call{value: amt}("");
        require(ok, "Transfer failed");
    }

    function getMarket(uint256 id) external view returns (
        string memory question, uint64 closeTime, address resolver,
        uint256 yesPool, uint256 noPool, uint8 state, bool outcome
    ) {
        Market storage m = markets[id];
        return (m.question, m.closeTime, m.resolver, m.yesPool, m.noPool, status(id), m.outcome);
    }
}
