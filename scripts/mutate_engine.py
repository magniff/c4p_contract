"""Mutation test of the engine's candidate generator (`_pieceHasLegalMove` / `_try`).

    .venv/bin/python scripts/mutate_engine.py        # ~2 min; run after any change to the generator

Each mutant drops one class of candidate moves. Every mutant must make the equivalence suite fail, except the
castling one, which is provably harmless (castling is never the only legal move: the rook's own step towards
the king is legal whenever castling is). The engine source is restored byte-for-byte afterwards, even on error.
"""
import hashlib, os, shutil, subprocess, sys, tempfile
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = "src/ChessEngine.sol"
BACKUP = os.path.join(tempfile.mkdtemp(), "ChessEngine.sol.bak")
shutil.copy(SRC, BACKUP)
orig = open(SRC).read()
sha = hashlib.sha256(orig.encode()).hexdigest()
PAWN = "            return _try(p, from, r + dir, f) || _try(p, from, r + dir, f - 1) || _try(p, from, r + dir, f + 1)\n                || _try(p, from, r + 2 * dir, f);"
KN = "            for (uint256 i; i < 8; ++i) {\n                int256 a = (i & 4) == 0 ? int256(1) : int256(2);"
KG = "                if (i != 4 && _try(p, from, r + int256(i / 3) - 1, f + int256(i % 3) - 1)) return true;"
SL = "            if (i == 4) continue;\n            int256 dr = int256(i / 3) - 1;"
muts = [
    ("pawn: no single push", PAWN, PAWN.replace("_try(p, from, r + dir, f) || ", "", 1)),
    ("pawn: no double push", PAWN, PAWN.replace("\n                || _try(p, from, r + 2 * dir, f)", "")),
    ("pawn: no capture to file-1", PAWN, PAWN.replace(" || _try(p, from, r + dir, f - 1)", "")),
    ("pawn: no capture to file+1", PAWN, PAWN.replace(" || _try(p, from, r + dir, f + 1)", "")),
    ("promotion never probed", "return _legal(p, from, to, _probePromo(p.board, from, to, p.whiteToMove));", "return _legal(p, from, to, 0);"),
    ("slider: no captures", "                if (_legal(p, from, uint8(uint256(rr * 8 + ff)), 0)) return true;\n                if (q != 0) break;",
                            "                if (q != 0) break;\n                if (_legal(p, from, uint8(uint256(rr * 8 + ff)), 0)) return true;"),
    ("slider: adjacent squares only", "                rr += dr;\n                ff += df;\n            }", "                break;\n            }"),
    ("castling candidates dropped (expected harmless)", "            return _try(p, from, r, f + 2) || _try(p, from, r, f - 2);", "            return false;"),
]
for k in range(8):
    muts.append((f"knight: jump #{k} dropped", KN, KN.replace("{\n", "{\n                if (i == %d) continue;\n" % k, 1)))
for k in [0, 1, 2, 3, 5, 6, 7, 8]:
    muts.append((f"king: step #{k} dropped", KG, KG.replace("i != 4 &&", f"i != 4 && i != {k} &&")))
    muts.append((f"slider: direction #{k} dropped", SL, SL.replace("if (i == 4) continue;", f"if (i == 4 || i == {k}) continue;")))
results = []
try:
    for name, old, new in muts:
        assert orig.count(old) == 1 and new != old, name
        open(SRC, "w").write(orig.replace(old, new))
        r = subprocess.run(["forge", "test", "--mc", "EngineEquivalence", "--mt", "test_onlyLegalMove|test_corpus_matches"],
                           capture_output=True, text=True)
        if "Compiler run failed" in r.stdout + r.stderr:
            status = "COMPILE ERROR"
        else:
            status = "caught" if "[FAIL" in r.stdout else "SURVIVED"
        results.append((name, status))
        print(f"{status:14} {name}", flush=True)
finally:
    shutil.copy(BACKUP, SRC)
    assert hashlib.sha256(open(SRC).read().encode()).hexdigest() == sha, "restore failed!"
    print("engine restored byte-for-byte", flush=True)
bad = [n for n, st in results if st != "caught" and "expected harmless" not in n]
if bad:
    sys.exit(f"{len(bad)} mutant(s) not caught: {bad}")
print(f"all {len(results) - 1} harmful mutants caught")
