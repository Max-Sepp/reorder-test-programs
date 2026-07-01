#!/usr/bin/env python3
"""Produce a BOLT-compatible function order from a startup memory trace.

This ties together the two analysis shell tools in ``scripts/analyse``:

  * ``measure_initial_startup_and_request.sh`` runs a server binary under
    valgrind's lackey tool and emits a CSV memory trace ("type,address,size";
    ``type == I`` rows are instruction fetches, in execution order).
  * ``elf_page_layout.sh`` emits JSON mapping every function to its *runtime*
    virtual-address range, computed with the same valgrind load base the trace
    uses -- so trace addresses and layout addresses line up.

Walking the instruction-fetch stream and mapping each fetch to the function it
lands in gives the order functions are first executed during startup. That order
is written one mangled symbol per line -- exactly the format BOLT's
``--function-order`` file wants:

    llvm-bolt <binary> --reorder-functions=user --function-order=<this file>

Functions not listed stay at the end in their original order, so only executed
functions need to appear.

The script orchestrates both shell tools (cache-aware: precomputed trace/layout
files are reused unless --force), then computes the ordering. Progress goes to
stderr; the ordering goes to the --output file (or stdout).

Example:
    ( cd rust && cargo build -p axum-server )
    analyse/venv/bin/python analyse/order_functions_by_execution.py rust/target/debug/axum_server --port 8090 --output axum.bolt-order.txt
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pandas as pd

# The two shell tools live in scripts/analyse relative to the repo root, which is
# the parent of this file's directory (analyse/).
REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts" / "analyse"
LAYOUT_SCRIPT = SCRIPTS_DIR / "elf_page_layout.sh"
TRACE_SCRIPT = SCRIPTS_DIR / "measure_initial_startup_and_request.sh"


def log(msg: str) -> None:
    """Progress/diagnostics to stderr, keeping stdout clean for the ordering."""
    print(msg, file=sys.stderr, flush=True)


# --- Orchestration (cache-aware) --------------------------------------------


def ensure_layout(binary: Path, layout_path: Path, force: bool) -> Path:
    """Return the ELF layout JSON, generating it via elf_page_layout.sh if
    missing (or --force). The script writes JSON to its second argument."""
    if layout_path.exists() and not force:
        log(f"==> Reusing cached layout {layout_path}")
        return layout_path
    log(f"==> Generating layout for {binary} -> {layout_path}")
    subprocess.run(
        [str(LAYOUT_SCRIPT), str(binary), str(layout_path)],
        check=True,
    )
    return layout_path


def ensure_trace(binary: Path, trace_path: Path, port: int, force: bool) -> Path:
    """Return the memory-trace CSV, generating it via
    measure_initial_startup_and_request.sh if missing (or --force). That script
    emits the CSV to stdout, which we capture into trace_path."""
    if trace_path.exists() and not force:
        log(f"==> Reusing cached trace {trace_path}")
        return trace_path
    log(f"==> Tracing startup of {binary} on port {port} -> {trace_path}")
    env = {**os.environ, "PORT": str(port)}
    with open(trace_path, "wb") as out:
        subprocess.run(
            [str(TRACE_SCRIPT), str(binary)],
            stdout=out,
            env=env,
            check=True,
        )
    return trace_path


# --- Layout -> interval arrays ----------------------------------------------


def load_layout(layout_path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Parse the layout JSON into three parallel arrays (starts, ends, names)
    sorted by start address, for vectorised address lookup. Size-0 functions
    (runtime_end == runtime_start) span no addresses and are dropped."""
    with open(layout_path) as f:
        layout = json.load(f)

    funcs = pd.DataFrame(layout["functions"])
    if funcs.empty:
        raise SystemExit(f"error: layout has no functions: {layout_path}")

    # runtime_start / runtime_end are "0x..." hex strings.
    starts = funcs["runtime_start"].apply(lambda s: int(s, 16)).to_numpy(np.int64)
    ends = funcs["runtime_end"].apply(lambda s: int(s, 16)).to_numpy(np.int64)
    names = funcs["mangled_name"].to_numpy()

    keep = ends > starts
    starts, ends, names = starts[keep], ends[keep], names[keep]

    order = np.argsort(starts, kind="stable")
    return starts[order], ends[order], names[order]


# --- Trace -> executed-function sequence (vectorised) -----------------------


def load_instruction_functions(
    trace_path: Path,
    starts: np.ndarray,
    ends: np.ndarray,
    names: np.ndarray,
) -> pd.Series:
    """Read the trace CSV, keep instruction fetches, and map each to the
    function containing it. Returns the mangled names in execution order;
    fetches outside any known function (libc, valgrind, PLT stubs) are dropped."""
    trace = pd.read_csv(trace_path, dtype={"type": str, "address": str})
    fetches = trace.loc[trace["type"] == "I", "address"]
    log(f"==> {len(fetches):,} instruction fetches in trace")

    addrs = fetches.apply(lambda s: int(s, 16)).to_numpy(np.int64)

    # For each address, the candidate function is the last one whose start is
    # <= address; confirm the address also falls before that function's end.
    idx = np.searchsorted(starts, addrs, side="right") - 1
    valid = idx >= 0
    valid[valid] &= addrs[valid] < ends[idx[valid]]

    mapped = pd.Series(names[idx[valid]])
    log(f"==> {len(mapped):,} fetches mapped to {mapped.nunique():,} functions")
    return mapped


# --- Ordering strategies (pluggable) ----------------------------------------
#
# A strategy takes the executed-function names in execution order (a pd.Series)
# and returns the ordered list of mangled symbols to hand to BOLT. Add a new
# ordering by writing a function and registering it in STRATEGIES; the
# trace/layout plumbing above is untouched.


def order_first_touch(names: pd.Series) -> list[str]:
    """Order functions by the first instruction fetch that lands in them."""
    return names.drop_duplicates(keep="first").tolist()


STRATEGIES = {
    "first-touch": order_first_touch,
}


# --- Default artifact paths (shared with reorder_binary.py) -----------------


def default_trace_path(binary: Path) -> Path:
    return binary.with_name(binary.name + ".memtrace.csv")


def default_layout_path(binary: Path) -> Path:
    return binary.with_name(binary.name + ".layout.json")


def default_order_path(binary: Path) -> Path:
    return binary.with_name(binary.name + ".bolt-order.txt")


# --- End-to-end order computation (reusable) --------------------------------


def compute_order(
    binary: Path,
    trace_path: Path,
    layout_path: Path,
    port: int,
    strategy: str,
    force: bool,
) -> list[str]:
    """Run the full trace -> layout -> order pipeline and return the ordered
    mangled symbols. Cache-aware: precomputed trace/layout files are reused
    unless force is set."""
    ensure_layout(binary, layout_path, force)
    ensure_trace(binary, trace_path, port, force)

    starts, ends, names = load_layout(layout_path)
    executed = load_instruction_functions(trace_path, starts, ends, names)

    ordered = STRATEGIES[strategy](executed)
    log(f"==> Ordered {len(ordered):,} functions using '{strategy}'")
    return ordered


# --- CLI --------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Produce a BOLT --function-order file ordering functions by "
        "the order they are first executed during startup.",
    )
    p.add_argument("binary", type=Path, help="Server binary to trace and order.")
    p.add_argument(
        "--trace",
        type=Path,
        help="Memory-trace CSV. Reused if it exists, else generated here "
        "(default: <binary>.memtrace.csv).",
    )
    p.add_argument(
        "--layout",
        type=Path,
        help="ELF layout JSON. Reused if it exists, else generated here "
        "(default: <binary>.layout.json).",
    )
    p.add_argument(
        "--output",
        type=Path,
        help="Where to write the BOLT function-order file "
        "(default: <binary>.bolt-order.txt). Use '-' for stdout.",
    )
    p.add_argument(
        "--port",
        type=int,
        default=8080,
        help="Port the server listens on during tracing (default: 8080).",
    )
    p.add_argument(
        "--strategy",
        choices=sorted(STRATEGIES),
        default="first-touch",
        help="Ordering strategy (default: first-touch).",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="Regenerate the trace and layout even if cached files exist.",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    binary = args.binary
    if not binary.is_file():
        raise SystemExit(f"error: binary not found: {binary}")

    trace_path = args.trace or default_trace_path(binary)
    layout_path = args.layout or default_layout_path(binary)

    ordered = compute_order(
        binary, trace_path, layout_path, args.port, args.strategy, args.force
    )

    text = "".join(name + "\n" for name in ordered)
    if args.output is None:
        out_path = default_order_path(binary)
        out_path.write_text(text)
        log(f"==> Wrote function order to {out_path}")
    elif str(args.output) == "-":
        sys.stdout.write(text)
    else:
        args.output.write_text(text)
        log(f"==> Wrote function order to {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
