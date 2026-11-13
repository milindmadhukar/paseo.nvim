"""Summarise and compare paseo.nvim benchmark runs.

  compare.py --ui OUT run1.json [run2.json ...] [--load load.json]
      Fold the UI bench's per-run files into one summary (OUT) and print it.

  compare.py before.json after.json
      Before/after table for two summaries of the same kind: two micro runs
      (tests/bench/run.sh micro out.json) or two UI summaries.

Standard library only; run it with `python3 -I`.
"""

import json
import re
import statistics
import sys


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def fold_ui(paths):
    """flow -> {paint, ready} medians, split into the first use and the rest."""
    groups = {}
    errors = {}
    for path in paths:
        with open(path) as f:
            data = json.load(f)
        for name, r in data.get("flows", {}).items():
            if "error" in r:
                errors.setdefault(name, r["error"])
                continue
            m = re.match(r"^(.*)\.(\d+)$", name)
            if m:
                base, n = m.group(1), int(m.group(2))
                key = f"{base} (first)" if n == 1 else f"{base} (again)"
            else:
                key = name
            g = groups.setdefault(key, {"paint": [], "ready": [], "timeouts": 0})
            g["paint"].append(r.get("paint"))
            g["ready"].append(r.get("ready"))
            if r.get("timeout"):
                g["timeouts"] += 1
    out = {}
    for key, g in groups.items():
        out[key] = {
            "paint": median(g["paint"]),
            "ready": median(g["ready"]),
            "n": len(g["ready"]),
            "timeouts": g["timeouts"],
        }
    return out, errors


def fold_load(path):
    with open(path) as f:
        data = json.load(f)
    secs = data.get("seconds") or 1
    spans = (data.get("perf") or {}).get("spans", {})
    out = {"seconds": secs}
    for name in (
        "rail.draw",
        "rail.build",
        "transcript.stream",
        "sidebar.header",
        "native.sync",
        "permission.relay",
        "loop.stall",
    ):
        s = spans.get(name)
        if not s:
            continue
        out[name] = {
            "per_sec": s["n"] / secs,
            "ms_per_sec": s["total"] / secs,
            "max": s["max"],
        }
    return out


def fmt(x):
    if x is None:
        return "—"
    if x >= 100:
        return f"{x:.0f}"
    if x >= 10:
        return f"{x:.1f}"
    return f"{x:.2f}"


def print_ui(summary):
    flows = summary["flows"]
    print("| flow | paint ms | ready ms | n |")
    print("|---|---:|---:|---:|")
    for key in sorted(flows):
        r = flows[key]
        t = " ⏱" if r.get("timeouts") else ""
        print(f"| {key} | {fmt(r['paint'])} | {fmt(r['ready'])}{t} | {r['n']} |")
    for name, err in summary.get("errors", {}).items():
        print(f"| {name} | error: {err} | | |")
    load = summary.get("load")
    if load:
        print()
        print(f"load test, {load['seconds']:.0f}s of four agents streaming:")
        print()
        print("| span | calls/s | main-loop ms/s | max ms |")
        print("|---|---:|---:|---:|")
        for name, s in load.items():
            if name == "seconds":
                continue
            print(f"| {name} | {fmt(s['per_sec'])} | {fmt(s['ms_per_sec'])} | {fmt(s['max'])} |")


def ratio(before, after):
    if before is None or after is None or after <= 0:
        return "—"
    return f"{before / after:.1f}×"


def compare(a_path, b_path):
    with open(a_path) as f:
        a = json.load(f)
    with open(b_path) as f:
        b = json.load(f)
    if "flows" in a:
        print("| flow | paint before | paint after | ready before | ready after | ready speedup |")
        print("|---|---:|---:|---:|---:|---:|")
        for key in sorted(set(a["flows"]) | set(b["flows"])):
            x, y = a["flows"].get(key, {}), b["flows"].get(key, {})
            print(
                f"| {key} | {fmt(x.get('paint'))} | {fmt(y.get('paint'))} | "
                f"{fmt(x.get('ready'))} | {fmt(y.get('ready'))} | {ratio(x.get('ready'), y.get('ready'))} |"
            )
        la, lb = a.get("load") or {}, b.get("load") or {}
        if la or lb:
            print()
            print("| load span | ms/s before | ms/s after | calls/s before | calls/s after |")
            print("|---|---:|---:|---:|---:|")
            for name in sorted((set(la) | set(lb)) - {"seconds"}):
                x, y = la.get(name, {}), lb.get(name, {})
                print(
                    f"| {name} | {fmt(x.get('ms_per_sec'))} | {fmt(y.get('ms_per_sec'))} | "
                    f"{fmt(x.get('per_sec'))} | {fmt(y.get('per_sec'))} |"
                )
        return
    print("| case | p50 before | p50 after | p90 before | p90 after | speedup |")
    print("|---|---:|---:|---:|---:|---:|")
    for key in sorted(set(a) | set(b)):
        x, y = a.get(key, {}), b.get(key, {})
        print(
            f"| {key} | {fmt(x.get('p50'))} | {fmt(y.get('p50'))} | "
            f"{fmt(x.get('p90'))} | {fmt(y.get('p90'))} | {ratio(x.get('p50'), y.get('p50'))} |"
        )


def main(argv):
    if argv and argv[0] == "--ui":
        out = argv[1]
        rest = argv[2:]
        load = None
        if "--load" in rest:
            i = rest.index("--load")
            load = rest[i + 1]
            rest = rest[:i] + rest[i + 2 :]
        flows, errors = fold_ui(rest)
        summary = {"flows": flows, "errors": errors}
        if load:
            try:
                summary["load"] = fold_load(load)
            except (OSError, ValueError) as e:
                summary["load_error"] = str(e)
        with open(out, "w") as f:
            json.dump(summary, f, indent=1)
        print_ui(summary)
        print(f"\nsaved {out}")
        return 0
    if len(argv) == 2:
        compare(argv[0], argv[1])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
