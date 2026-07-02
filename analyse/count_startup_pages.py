#!/usr/bin/env python3
"""Count distinct code pages touched at startup, before vs after reordering.

The headline number for the reordering experiment: how many 4 KB pages of the
binary's *own* static code are touched during startup, and how much reordering
shrinks that. Uses the same static-code filter as plot_static_code_accesses.py
(an instruction fetch counts if it lands inside a known function; libc/ld and
PLT stubs are dropped).

Works directly off existing trace + layout files -- no re-tracing:

    analyse/venv/bin/python analyse/count_startup_pages.py \\
        tmp/actix_experiment_1/actix_server \\
        tmp/actix_experiment_1/actix_optimised_server
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd


def distinct_code_pages(binary: Path) -> tuple[int, int, int]:
    """Return (distinct static-code pages touched, static-code fetches,
    total fetches) for a binary's startup trace."""
    layout_path = binary.with_suffix(binary.suffix + ".layout.json")
    if not layout_path.exists():
        layout_path = Path(str(binary) + ".layout.json")
    trace_path = Path(str(binary) + ".memtrace.csv")

    layout = json.loads(layout_path.read_text())
    page_size = layout["page_size"]
    shift = page_size.bit_length() - 1  # 4096 -> 12

    funcs = pd.DataFrame(layout["functions"])
    starts = funcs["runtime_start"].apply(lambda s: int(s, 16)).to_numpy(np.int64)
    ends = funcs["runtime_end"].apply(lambda s: int(s, 16)).to_numpy(np.int64)
    # Drop zero-width functions (end == start) -- they span no addresses, so no
    # fetch can land in them, and they'd only confuse the interval lookup.
    keep = ends > starts
    starts, ends = starts[keep], ends[keep]
    # searchsorted (below) needs the intervals sorted by start address. Sort
    # starts and reorder ends the same way so the two arrays stay paired.
    order = np.argsort(starts, kind="stable")
    starts, ends = starts[order], ends[order]

    # Pull just the instruction-fetch addresses (type == "I") from the trace and
    # convert the hex strings to ints. Store rows (type == "S") are ignored.
    df = pd.read_csv(trace_path, dtype={"type": str, "address": str})
    addr = (
        df.loc[df["type"] == "I", "address"]
        .apply(lambda s: int(s, 16))
        .to_numpy(np.int64)
    )

    # Keep only fetches inside a known function = the binary's own static code.
    # For each address, searchsorted(side="right")-1 finds the index of the last
    # interval whose start is <= address -- i.e. the only interval that could
    # possibly contain it. idx == -1 means the address is below every start.
    idx = np.searchsorted(starts, addr, side="right") - 1
    mask = idx >= 0  # has a candidate interval at all
    # For the addresses that have a candidate, confirm they're actually below
    # that interval's end (otherwise they fall in a gap, e.g. libc/ld or a PLT
    # stub between functions). mask[mask] &= ... updates only those entries.
    mask[mask] &= addr[mask] < ends[idx[mask]]
    static = addr[mask]

    # Collapse each surviving address to its page number and count the distinct
    # pages -- that's how many 4 KB code pages startup actually touches.
    pages = np.unique(static >> shift)
    return pages.size, static.size, addr.size


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("before", type=Path, help="Original binary")
    p.add_argument("after", type=Path, help="Reordered binary")
    args = p.parse_args()

    b_pages, b_static, b_total = distinct_code_pages(args.before)
    a_pages, a_static, a_total = distinct_code_pages(args.after)

    print(f"{'binary':<28} {'code pages':>10} {'static fetches':>15} {'total fetches':>15}")
    print(f"{args.before.name:<28} {b_pages:>10,} {b_static:>15,} {b_total:>15,}")
    print(f"{args.after.name:<28} {a_pages:>10,} {a_static:>15,} {a_total:>15,}")
    reduction = (b_pages - a_pages) / b_pages * 100 if b_pages else 0.0
    print(
        f"\ncode pages: {b_pages:,} -> {a_pages:,} "
        f"({b_pages - a_pages:,} fewer, {reduction:.1f}% reduction)"
    )


if __name__ == "__main__":
    main()
