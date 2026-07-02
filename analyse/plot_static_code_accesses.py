#!/usr/bin/env python3
"""Plot static-code instruction-fetch addresses over time for two binaries.

Given two binaries -- typically an original and its BOLT-reordered version --
this collects each one's startup memory trace and plots, for every instruction
fetch that lands in the binary's *own* statically-linked code (excluding
dynamically-linked libc/ld), a point:

    x = time  (the running index of the instruction fetch in the trace)
    y = virtual address of that fetch (offset from the load base)

Before reordering the points are scattered across the whole code range as
startup jumps around; after reordering they collapse into a tight rising band
(functions laid out in execution order) -- the locality win, made visible.

The two binaries are shown as stacked subplots sharing the time axis. Every
point is drawn (no downsampling); the window is interactive (zoom/pan) via the
matplotlib QtAgg backend.

The analysis (trace + layout) is collected with the same cache-aware pipeline as
order_functions_by_execution.py (same directory), reused by import.

Example:
    analyse/venv/bin/python analyse/plot_static_code_accesses.py \\
        tmp/actix_server tmp/actix_optimised_server --port 8096
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import matplotlib

# Use a real GUI backend for the interactive window, but let an explicit
# MPLBACKEND override win (e.g. MPLBACKEND=Agg for a headless --save run, where
# plt.show() becomes a no-op).
if "MPLBACKEND" not in os.environ:
    import importlib.util
    if any(importlib.util.find_spec(m) for m in ("PyQt6", "PySide6", "PyQt5", "PySide2")):
        matplotlib.use("QtAgg")

import matplotlib.pyplot as plt  # noqa: E402  (after backend selection)
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

import order_functions_by_execution as order  # noqa: E402


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def code_fetches(
    binary: Path,
    port: int,
    force: bool,
    method: str = "GET",
    endpoint: str = "/log",
    body: str = "",
    trace_suffix: str = "",
) -> tuple[np.ndarray, np.ndarray]:
    """Collect the binary's startup trace + layout, then return (x, y) for every
    instruction fetch landing in the binary's own statically-linked code:
    x = the fetch's index in the instruction stream (time), y = its virtual
    address as an offset from the load base.

    method/endpoint/body pick which request the trace covers (default GET /log);
    trace_suffix is inserted into the trace filename (e.g. ".post") so a
    cross-request trace lives alongside the default one instead of clobbering
    it."""
    # e.g. actix_server + ".post" -> actix_server.post.memtrace.csv
    trace_path = binary.with_name(binary.name + trace_suffix + ".memtrace.csv")
    layout_path = order.default_layout_path(binary)

    order.ensure_layout(binary, layout_path, force)
    order.ensure_trace(
        binary, trace_path, port, force,
        method=method, endpoint=endpoint, body=body,
    )

    starts, ends, _names = order.load_layout(layout_path)
    with open(layout_path) as f:
        load_bias = int(json.load(f)["load_bias"], 16)

    df = pd.read_csv(trace_path, dtype={"type": str, "address": str})
    fetches = df.loc[df["type"] == "I", "address"]
    addr = fetches.apply(lambda s: int(s, 16)).to_numpy(np.int64)
    time = np.arange(addr.size, dtype=np.int64)  # position in the fetch stream

    # Keep only fetches inside a known function = the binary's static code.
    # Anything in libc/ld (or otherwise outside every interval) is dropped.
    idx = np.searchsorted(starts, addr, side="right") - 1
    mask = idx >= 0
    mask[mask] &= addr[mask] < ends[idx[mask]]

    log(
        f"==> {binary.name}: {mask.sum():,} of {addr.size:,} instruction "
        f"fetches are in static code"
    )
    return time[mask], addr[mask] - load_bias


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Plot static-code instruction-fetch addresses over time for "
        "two binaries (e.g. original vs BOLT-reordered).",
    )
    p.add_argument("before", type=Path, help="First binary (top panel).")
    p.add_argument("after", type=Path, help="Second binary (bottom panel).")
    p.add_argument(
        "--port",
        type=int,
        default=8080,
        help="Port the servers listen on while tracing (default: 8080).",
    )
    p.add_argument(
        "--save",
        type=Path,
        help="Also write the figure to this PNG (useful for headless runs).",
    )
    p.add_argument(
        "--method",
        default="GET",
        help="HTTP method of the traced request (default: GET). Use POST to "
        "trace a cross-request footprint against a binary ordered on GET.",
    )
    p.add_argument(
        "--endpoint",
        default="/log",
        help="Endpoint of the traced request (default: /log).",
    )
    p.add_argument(
        "--body",
        default="",
        help="Request body for non-GET methods (default: empty).",
    )
    p.add_argument(
        "--trace-suffix",
        default="",
        help="Suffix inserted into the trace filename so a cross-request trace "
        "does not clobber the default one, e.g. '.post' -> "
        "<binary>.post.memtrace.csv.",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    for b in (args.before, args.after):
        if not b.is_file():
            raise SystemExit(f"error: binary not found: {b}")

    panels = [
        (args.before, "tab:red"),
        (args.after, "tab:blue"),
    ]

    fig, axes = plt.subplots(2, 1, sharex=True, figsize=(14, 9))
    for ax, (binary, colour) in zip(axes, panels):
        x, y = code_fetches(
            binary, args.port, force=False,
            method=args.method, endpoint=args.endpoint, body=args.body,
            trace_suffix=args.trace_suffix,
        )
        # ",": 1-pixel marker, no line -> a single Line2D, fast enough to draw
        # every one of ~2M points with no downsampling.
        ax.plot(x, y, ",", color=colour, alpha=0.3)
        ax.set_title(binary.name)
        ax.set_ylabel("static code address\n(offset from load base)")
        ax.margins(x=0)

    axes[-1].set_xlabel("instruction fetch index (time)")
    fig.suptitle(
        f"Static-code instruction fetches over startup + {args.method} "
        f"{args.endpoint}: before vs after"
    )
    fig.tight_layout()

    if args.save:
        fig.savefig(args.save, dpi=150)
        log(f"==> Saved figure to {args.save}")

    plt.show()
    return 0


if __name__ == "__main__":
    sys.exit(main())
