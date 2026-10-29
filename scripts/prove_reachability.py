"""Guard against vacuous proofs. Halmos only reports assertion failures; a path that reverts for any other
reason (a failing setup call, contradictory vm.assume) is silently dropped, so a proof whose interesting
paths all revert would "pass" while proving nothing. This injects `assert(false);` at the end of every check_
function and at the end of every try / catch branch inside it, one at a time, and requires Halmos to find a
counterexample each time, i.e. that every branch the proof talks about is actually reached.

    .venv/bin/python scripts/prove_reachability.py      # needs .venv-halmos, see scripts/prove.sh
"""
import os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
FILES = {"test/proofs/EngineProofs.t.sol": "EngineProofs", "test/proofs/ContractProofs.t.sol": "ContractProofs"}
ENV = dict(os.environ, FOUNDRY_DYNAMIC_TEST_LINKING="false")


def close_of(s, open_idx):
    depth = 0
    for i in range(open_idx, len(s)):
        depth += {"{": 1, "}": -1}.get(s[i], 0)
        if depth == 0:
            return i
    raise ValueError("unbalanced")


def sites(s):
    """(function name, label, index of the closing brace to insert before) for every function and branch."""
    out = []
    for m in re.finditer(r"function (check_\w+)\([^)]*\)[^{]*\{", s):
        name, body_open = m.group(1), m.end() - 1
        body_close = close_of(s, body_open)
        out.append((name, "end", body_close))
        # `try f{value: x}(args) {`: the branch opens at the first `{` after a `)`, not at a call-option brace
        for b in re.finditer(r"(try .*?\)\s*\{|catch[^{]*\{)", s[body_open:body_close]):
            o = body_open + b.end() - 1
            out.append((name, "try-branch" if b.group(0).startswith("try") else "catch-branch", close_of(s, o)))
    return out


def run(contract, fn):
    r = subprocess.run([os.path.join(ROOT, ".venv-halmos/bin/halmos"), "--contract", contract,
                        "--match-test", "^" + fn + r"\("], cwd=ROOT, env=ENV, capture_output=True, text=True)
    out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
    if "Running 1 tests" not in out:
        sys.exit(f"halmos did not run {contract}.{fn}:\n{out[-2000:]}")  # never mistake "ran nothing" for a result
    return "[FAIL]" in out and "Counterexample" in out


os.chdir(ROOT)
bad = []
for path, contract in FILES.items():
    orig = open(path).read()
    backup = os.path.join(tempfile.mkdtemp(), os.path.basename(path))
    shutil.copy(path, backup)
    try:
        for name, label, idx in sites(orig):
            # a branch whose body is already `assert(false)` is one the proof claims is unreachable
            branch_start = orig.rfind("{", 0, idx)
            expect_unreached = label == "try-branch" and orig[branch_start:idx].strip("{ \n") == "assert(false);"
            open(path, "w").write(orig[:idx] + "assert(false); " + orig[idx:])
            reached = run(contract, name)
            if expect_unreached:
                print(f"{'UNEXPECTED' if reached else 'unreached'} {name} [{label}] (proved impossible)", flush=True)
                if reached:
                    bad.append(f"{name} [{label}] is reachable but the proof says it is not")
            else:
                print(f"{'reached   ' if reached else 'VACUOUS?  '} {name} [{label}]", flush=True)
                if not reached:
                    bad.append(f"{name} [{label}]")
    finally:
        shutil.copy(backup, path)
if bad:
    sys.exit(f"unreached: {bad}")
print("every proof and branch is reached, except the ones proved impossible")
