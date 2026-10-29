// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChessEngine} from "./ChessEngine.sol";

/// @title Chess4Profit
/// @notice Trustless wagered chess. Anyone locks a stake to open a game; anyone matching the stake
///         can join. Every move is validated on-chain, the winner is computed automatically and
///         takes the pot minus a protocol fee.
///
/// Flow
///   createGame{value: stake}(baseTime, increment, white) -> GameCreated (creator declares colour + clock)
///   joinGame{value: stake}(id)             -> GameStarted (must happen within OPEN_WINDOW)
///   makeMove(id, move) ...                 -> MoveMade, and finally GameFinished
///   resign(id) / claimTimeout(id)          -> alternative endings
///   cancelGame(id)                         -> creator reclaims stake if nobody joined
contract Chess4Profit {
    using ChessEngine for ChessEngine.Position;

    // ------------------------------------------------------------------ config

    /// @dev TODO(release): replace with the real fee address before mainnet deployment.
    ///      script/Deploy.s.sol refuses to deploy to non-local chains while this is still the placeholder.
    address payable public constant FEE_RECIPIENT = payable(0x000000000000000000000000000000000000dEaD);

    /// @notice Fee in basis points of the total pot (both stakes). Charged on every finished game.
    uint256 public constant FEE_BPS = 250;
    /// @notice Smallest allowed stake per player: keeps the fee non-trivial and makes dust-spam pointless.
    uint256 public constant MIN_STAKE = 0.0001 ether;
    /// @notice Fischer clock: each side starts with `baseTime` and gains `increment` after every move.
    ///         A total time bank (not a per-move limit) bounds how long a hostile opponent can hold your funds.
    ///         The bank is capped at MAX_BASE_TIME, so fast moves can't be hoarded into a multi-day stall.
    uint32 public constant MIN_BASE_TIME = 30 seconds;
    uint32 public constant MAX_BASE_TIME = 1 days;
    uint32 public constant MAX_INCREMENT = 10 minutes;
    /// @notice An open game can be joined for this long; afterwards anyone may refund it to its creator.
    uint256 public constant OPEN_WINDOW = 1 hours;
    /// @dev Gas forwarded when pushing a payout; if the push fails the amount is credited for `withdraw`.
    uint256 internal constant PAYOUT_GAS = 50_000;
    /// @notice Bot profile limits. Names: [A-Za-z0-9 _.-], no leading/trailing/double spaces.
    ///         Descriptions: any UTF-8 without control bytes. Names are NOT unique: show the address with them.
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_DESCRIPTION_BYTES = 280;

    // ------------------------------------------------------------------ types

    enum Status {
        None,
        Open,
        Active,
        Finished,
        Cancelled
    }

    enum Result {
        None,
        WhiteWins,
        BlackWins,
        Draw
    }

    enum Reason {
        None,
        Checkmate,
        Resignation,
        Timeout,
        Stalemate,
        InsufficientMaterial,
        FiftyMoveRule,
        ThreefoldRepetition
    }

    /// @dev Laid out for the hot path: a move reads `st`, `board` and the mover's seat, and writes `st` and `board`.
    struct Game {
        address payable white; // slot 0. While Open only the creator's seat (the colour they chose) is filled.
        uint96 stake; // per player
        address payable black; // slot 1
        State st; // slot 2
        uint256 board; // slot 3: ChessEngine.Position.board
    }

    /// @dev Exactly one storage slot (30 bytes): everything a move changes except the board.
    struct State {
        Status status;
        Result result;
        Reason reason;
        uint32 increment;
        uint32 whiteTime; // seconds on white's clock as of lastMoveAt
        uint32 blackTime;
        uint40 lastMoveAt; // creation time while Open
        uint16 plies;
        // the rest of ChessEngine.Position
        bool whiteToMove;
        uint8 castling;
        uint8 epSquare;
        uint8 halfmoveClock;
        uint8 whiteKing;
        uint8 blackKing;
        uint16 fullmove;
    }

    /// @dev Flat view of a game for clients.
    struct GameView {
        uint256 id;
        Status status;
        Result result;
        Reason reason;
        address white;
        address black;
        uint256 stake;
        uint32 increment;
        uint32 whiteTime;
        uint32 blackTime;
        uint40 lastMoveAt;
        /// @dev Open: last moment it can be joined. Active: moment the side to move can be flagged. Else 0.
        uint256 deadline;
        uint16 plies;
        bool whiteToMove;
    }

    // ------------------------------------------------------------------ storage

    uint256 public nextGameId = 1;
    mapping(uint256 => Game) internal games;
    /// @dev gameId => position key => occurrences (for threefold repetition)
    mapping(uint256 => mapping(bytes32 => uint8)) internal positionCount;
    /// @dev table (= keccak(stake, baseTime, increment)) => ids of open games at that table. Matchmaking only
    ///      ever looks at the exact table it wants to sit at, so spam anywhere else can't hide a game, and spam
    ///      AT the table is joinable (and therefore costs the spammer a stake per game somebody joins).
    ///      Swap-and-pop keeps it exact (no stale entries).
    mapping(bytes32 => uint256[]) internal openByTable;
    mapping(uint256 => uint256) internal openPos; // gameId => index + 1 in its bucket
    /// @notice Payouts whose push failed; claim with `withdraw`.
    mapping(address => uint256) public pending;

    struct Profile {
        string name;
        string description;
    }

    mapping(address => Profile) internal profiles;

    /// @dev EIP-1153 transient storage: the same lock as a storage flag, without a cold slot write per call.
    bool private transient _locked;

    // ------------------------------------------------------------------ events

    event GameCreated(
        uint256 indexed gameId,
        address indexed creator,
        uint256 stake,
        uint32 baseTime,
        uint32 increment,
        bool creatorPlaysWhite
    );
    event GameCancelled(uint256 indexed gameId);
    event GameStarted(uint256 indexed gameId, address indexed white, address indexed black);
    /// @param move  from | to << 6 | promotion << 12 (a1 = 0 ... h8 = 63)
    /// @param ply   number of half-moves played so far, including this one
    event MoveMade(uint256 indexed gameId, address indexed player, uint16 move, uint16 ply);
    event GameFinished(
        uint256 indexed gameId, Result result, Reason reason, address indexed winner, uint256 payout, uint256 fee
    );
    event Withdrawn(address indexed account, uint256 amount);
    event ProfileUpdated(address indexed bot, string name, string description);

    // ------------------------------------------------------------------ errors

    error BadStake();
    error BadTimeout();
    error Expired();
    error UnknownGame();
    error NotOpen();
    error NotActive();
    error NotCreator();
    error SelfJoin();
    error NotPlayer();
    error NotYourTurn();
    error TurnTimedOut();
    error NotTimedOut();
    error IllegalMove();
    error NothingToWithdraw();
    error Reentrancy();
    error BadName();
    error BadDescription();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ------------------------------------------------------------------ lobby

    /// @notice Lock `msg.value` as your stake and open a game for anyone who matches it.
    /// @param baseTime seconds each player starts with on the clock
    /// @param increment seconds added to a player's clock after each of their moves
    /// @param creatorPlaysWhite colour is chosen by the creator and visible before anyone joins. There is
    ///        deliberately no on-chain randomness: a contract joiner could read it and revert unless lucky.
    function createGame(uint32 baseTime, uint32 increment, bool creatorPlaysWhite)
        external
        payable
        nonReentrant
        returns (uint256 gameId)
    {
        if (msg.value < MIN_STAKE || msg.value > type(uint96).max) revert BadStake();
        if (baseTime < MIN_BASE_TIME || baseTime > MAX_BASE_TIME || increment > MAX_INCREMENT) revert BadTimeout();

        gameId = nextGameId++;
        Game storage g = games[gameId];
        if (creatorPlaysWhite) g.white = payable(msg.sender);
        else g.black = payable(msg.sender);
        g.stake = uint96(msg.value);
        State storage st = g.st;
        st.status = Status.Open;
        st.increment = increment;
        st.whiteTime = baseTime;
        st.blackTime = baseTime;
        st.lastMoveAt = uint40(block.timestamp);

        uint256[] storage bucket = openByTable[lobbyKey(msg.value, baseTime, increment)];
        bucket.push(gameId);
        openPos[gameId] = bucket.length;
        emit GameCreated(gameId, msg.sender, msg.value, baseTime, increment, creatorPlaysWhite);
    }

    /// @notice Refund an open game's stake to its creator. The creator may do so any time; anyone may once
    ///         the game has expired (this is how abandoned tables get cleaned up).
    function cancelGame(uint256 gameId) external nonReentrant {
        Game storage g = _game(gameId);
        if (g.st.status != Status.Open) revert NotOpen();
        if (msg.sender != _creator(g) && block.timestamp <= uint256(g.st.lastMoveAt) + OPEN_WINDOW) revert NotCreator();
        _cancel(gameId, g);
    }

    /// @notice Permissionless janitor: refund up to `limit` expired open games at a table.
    function sweepExpired(bytes32 table, uint256 limit) external nonReentrant returns (uint256 swept) {
        uint256[] storage bucket = openByTable[table];
        uint256 i;
        for (uint256 scanned; scanned < limit && i < bucket.length; ++scanned) {
            uint256 id = bucket[i];
            Game storage g = games[id];
            if (block.timestamp > uint256(g.st.lastMoveAt) + OPEN_WINDOW) {
                _cancel(id, g); // swap-and-pop moved the last entry into slot i, so don't advance
                ++swept;
            } else {
                ++i;
            }
        }
    }

    /// @notice Join an open game by sending exactly the creator's stake.
    function joinGame(uint256 gameId) external payable nonReentrant {
        Game storage g = _game(gameId);
        State memory st = g.st;
        if (st.status != Status.Open) revert NotOpen();
        if (msg.value != g.stake) revert BadStake();
        if (msg.sender == _creator(g)) revert SelfJoin();
        if (block.timestamp > uint256(st.lastMoveAt) + OPEN_WINDOW) revert Expired();

        _removeOpen(g, gameId);
        if (g.white == address(0)) g.white = payable(msg.sender);
        else g.black = payable(msg.sender);
        st.status = Status.Active;
        st.lastMoveAt = uint40(block.timestamp);

        ChessEngine.Position memory p = ChessEngine.initialPosition();
        _save(g, st, p);
        positionCount[gameId][p.positionKey()] = 1;

        emit GameStarted(gameId, g.white, g.black);
    }

    // ------------------------------------------------------------------ play

    /// @notice Play a move as the side to move. Reverts unless the move is fully legal.
    function makeMove(uint256 gameId, uint16 move) external nonReentrant {
        Game storage g = _game(gameId);
        State memory st = g.st;
        if (st.status != Status.Active) revert NotActive();
        bool white = st.whiteToMove;
        if (msg.sender != (white ? g.white : g.black)) revert NotYourTurn();
        uint256 left = white ? st.whiteTime : st.blackTime;
        uint256 elapsed = block.timestamp - st.lastMoveAt;
        if (elapsed > left) revert TurnTimedOut();

        (bool ok, ChessEngine.Position memory np) = ChessEngine.applyMove(_position(g, st), move);
        if (!ok) revert IllegalMove();

        st.lastMoveAt = uint40(block.timestamp);
        uint256 newLeft = left - elapsed + st.increment;
        if (newLeft > MAX_BASE_TIME) newLeft = MAX_BASE_TIME; // hard bound on how long any one move can take
        if (white) st.whiteTime = uint32(newLeft);
        else st.blackTime = uint32(newLeft);
        uint16 ply = ++st.plies;
        _save(g, st, np);
        emit MoveMade(gameId, msg.sender, move, ply);

        ChessEngine.Outcome o = ChessEngine.outcome(np);
        if (o == ChessEngine.Outcome.Checkmate) {
            _finish(gameId, g, white ? Result.WhiteWins : Result.BlackWins, Reason.Checkmate);
        } else if (o == ChessEngine.Outcome.Stalemate) {
            _finish(gameId, g, Result.Draw, Reason.Stalemate);
        } else if (o == ChessEngine.Outcome.InsufficientMaterial) {
            _finish(gameId, g, Result.Draw, Reason.InsufficientMaterial);
        } else if (o == ChessEngine.Outcome.FiftyMoveRule) {
            _finish(gameId, g, Result.Draw, Reason.FiftyMoveRule);
        } else if (++positionCount[gameId][np.positionKey()] >= 3) {
            _finish(gameId, g, Result.Draw, Reason.ThreefoldRepetition);
        }
    }

    /// @notice Concede the game; the opponent takes the pot.
    function resign(uint256 gameId) external nonReentrant {
        Game storage g = _game(gameId);
        if (g.st.status != Status.Active) revert NotActive();
        if (msg.sender == g.white) _finish(gameId, g, Result.BlackWins, Reason.Resignation);
        else if (msg.sender == g.black) _finish(gameId, g, Result.WhiteWins, Reason.Resignation);
        else revert NotPlayer();
    }

    /// @notice If the side to move let its clock run out, anyone can end the game in the opponent's favour.
    function claimTimeout(uint256 gameId) external nonReentrant {
        Game storage g = _game(gameId);
        State memory st = g.st;
        if (st.status != Status.Active) revert NotActive();
        bool white = st.whiteToMove;
        if (block.timestamp <= uint256(st.lastMoveAt) + (white ? st.whiteTime : st.blackTime)) revert NotTimedOut();
        _finish(gameId, g, white ? Result.BlackWins : Result.WhiteWins, Reason.Timeout);
    }

    /// @notice Pull payouts that could not be pushed.
    function withdraw() external nonReentrant {
        uint256 amount = pending[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pending[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "withdraw failed");
    }

    // ------------------------------------------------------------------ profiles

    /// @notice Set the caller's public name and description (both empty = remove the profile).
    ///         Profiles never touch money or games; they exist so humans can tell bots apart.
    function setProfile(string calldata name, string calldata description) external {
        bytes calldata n = bytes(name);
        bytes calldata d = bytes(description);
        if (n.length > MAX_NAME_BYTES) revert BadName();
        for (uint256 i; i < n.length; ++i) {
            bytes1 c = n[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-"
                || c == "_" || c == ".";
            if (c == " ") {
                // no leading, trailing or double spaces: "Magnus " can't impersonate "Magnus"
                ok = i != 0 && i != n.length - 1 && n[i - 1] != " ";
            }
            if (!ok) revert BadName();
        }
        if (d.length > MAX_DESCRIPTION_BYTES) revert BadDescription();
        for (uint256 i; i < d.length; ++i) {
            // control bytes would let a description rewrite terminals / break one-line layouts
            if (uint8(d[i]) < 0x20 || uint8(d[i]) == 0x7f) revert BadDescription();
        }
        if (n.length == 0 && d.length == 0) {
            delete profiles[msg.sender];
        } else {
            Profile storage p = profiles[msg.sender];
            p.name = name;
            p.description = description;
        }
        emit ProfileUpdated(msg.sender, name, description);
    }

    function profileOf(address bot) external view returns (string memory name, string memory description) {
        Profile storage p = profiles[bot];
        return (p.name, p.description);
    }

    // ------------------------------------------------------------------ views

    function getGame(uint256 gameId) external view returns (GameView memory v) {
        Game storage g = _game(gameId);
        State memory st = g.st;
        v.id = gameId;
        v.status = st.status;
        v.result = st.result;
        v.reason = st.reason;
        if (st.status == Status.Open || st.status == Status.Cancelled) {
            v.white = _creator(g); // colours not assigned yet; creator listed first
        } else {
            v.white = g.white;
            v.black = g.black;
        }
        v.stake = g.stake;
        v.increment = st.increment;
        v.whiteTime = st.whiteTime;
        v.blackTime = st.blackTime;
        v.lastMoveAt = st.lastMoveAt;
        if (st.status == Status.Open) {
            v.deadline = uint256(st.lastMoveAt) + OPEN_WINDOW;
        } else if (st.status == Status.Active) {
            v.deadline = uint256(st.lastMoveAt) + (st.whiteToMove ? st.whiteTime : st.blackTime);
        }
        v.plies = st.plies;
        v.whiteToMove = st.whiteToMove;
    }

    /// @notice Key of a lobby table: games are only matched with identical stake AND clock.
    function lobbyKey(uint256 stake, uint32 baseTime, uint32 increment) public pure returns (bytes32) {
        return keccak256(abi.encode(stake, baseTime, increment));
    }

    /// @notice Joinable (unexpired) games at a table, newest first. Reads at most `scanLimit` entries.
    function openGames(bytes32 table, uint256 maxResults, uint256 scanLimit) external view returns (uint256[] memory ids) {
        uint256[] storage bucket = openByTable[table];
        uint256 n = bucket.length;
        ids = new uint256[](maxResults < n ? maxResults : n);
        uint256 found;
        for (uint256 i = n; i > 0 && found < maxResults && n - i < scanLimit; --i) {
            uint256 id = bucket[i - 1];
            if (block.timestamp <= uint256(games[id].st.lastMoveAt) + OPEN_WINDOW) ids[found++] = id;
        }
        assembly {
            mstore(ids, found)
        }
    }

    function openGameCount(bytes32 table) external view returns (uint256) {
        return openByTable[table].length;
    }

    function getPosition(uint256 gameId) external view returns (ChessEngine.Position memory) {
        Game storage g = _game(gameId);
        return _position(g, g.st);
    }

    /// @notice Every legal move for the side to move (promotions expanded). Heavy: call via eth_call only.
    function legalMoves(uint256 gameId) external view returns (uint16[] memory) {
        Game storage g = _game(gameId);
        if (g.st.status != Status.Active) revert NotActive();
        return ChessEngine.legalMoves(_position(g, g.st));
    }

    function isMoveLegal(uint256 gameId, uint16 move) external view returns (bool) {
        Game storage g = _game(gameId);
        if (g.st.status != Status.Active) revert NotActive();
        return ChessEngine.isLegal(_position(g, g.st), move);
    }

    // ------------------------------------------------------------------ internals

    function _game(uint256 gameId) internal view returns (Game storage g) {
        g = games[gameId];
        if (g.st.status == Status.None) revert UnknownGame();
    }

    /// @dev The creator is whoever holds a seat before anyone joins (Open and Cancelled games have only one).
    function _creator(Game storage g) internal view returns (address payable) {
        address payable w = g.white;
        return w != address(0) ? w : g.black;
    }

    /// @dev The engine's view of the game: the board slot plus the position fields of `st`.
    function _position(Game storage g, State memory st) internal view returns (ChessEngine.Position memory p) {
        p.board = g.board;
        p.whiteToMove = st.whiteToMove;
        p.castling = st.castling;
        p.epSquare = st.epSquare;
        p.halfmoveClock = st.halfmoveClock;
        p.whiteKing = st.whiteKing;
        p.blackKing = st.blackKing;
        p.fullmove = st.fullmove;
    }

    /// @dev Write `st` with the position fields of `p`, and the board: two slots.
    function _save(Game storage g, State memory st, ChessEngine.Position memory p) internal {
        st.whiteToMove = p.whiteToMove;
        st.castling = p.castling;
        st.epSquare = p.epSquare;
        st.halfmoveClock = p.halfmoveClock;
        st.whiteKing = p.whiteKing;
        st.blackKing = p.blackKing;
        st.fullmove = p.fullmove;
        g.st = st;
        g.board = p.board;
    }

    function _cancel(uint256 gameId, Game storage g) internal {
        g.st.status = Status.Cancelled;
        _removeOpen(g, gameId);
        emit GameCancelled(gameId);
        _pay(_creator(g), g.stake);
    }

    /// @dev Only valid while `g` is Open (whiteTime still equals the advertised baseTime).
    function _removeOpen(Game storage g, uint256 gameId) internal {
        uint256[] storage bucket = openByTable[lobbyKey(g.stake, g.st.whiteTime, g.st.increment)];
        uint256 idx = openPos[gameId] - 1;
        uint256 last = bucket[bucket.length - 1];
        bucket[idx] = last;
        openPos[last] = idx + 1;
        bucket.pop();
        delete openPos[gameId];
    }

    function _finish(uint256 gameId, Game storage g, Result result, Reason reason) internal {
        State storage st = g.st;
        st.status = Status.Finished;
        st.result = result;
        st.reason = reason;

        uint256 pot = uint256(g.stake) * 2;
        uint256 fee = pot * FEE_BPS / 10_000;
        uint256 net = pot - fee;

        address winner;
        uint256 payout;
        if (result == Result.Draw) {
            payout = net / 2;
            fee += net - payout * 2; // odd wei goes to the fee
            emit GameFinished(gameId, result, reason, address(0), payout, fee);
            _pay(g.white, payout);
            _pay(g.black, payout);
        } else {
            winner = result == Result.WhiteWins ? g.white : g.black;
            payout = net;
            emit GameFinished(gameId, result, reason, winner, payout, fee);
            _pay(payable(winner), payout);
        }
        _pay(FEE_RECIPIENT, fee);
    }

    /// @dev Push with bounded gas; on failure credit `pending` so a hostile receiver can never block a game's end.
    function _pay(address payable to, uint256 amount) internal {
        if (amount == 0) return;
        bool sent;
        assembly {
            // no return-data copy: a hostile receiver can't make us pay for it
            sent := call(PAYOUT_GAS, to, amount, 0, 0, 0, 0)
        }
        if (!sent) pending[to] += amount;
    }
}
