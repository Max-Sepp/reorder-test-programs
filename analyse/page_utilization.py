#!/usr/bin/env python3
"""Per-page utilization of startup code pages, before vs after reordering.

For every 4 KB page of the binary's own static code that startup touches, what
fraction of the page's bytes are *actually executed*? That fraction is the
hypothesis made measurable: before reordering, startup should touch many pages
but only sparsely (low utilization); after, the executed code should be packed
into fewer, near-full pages (high utilization).

Executed bytes per page are computed from the instruction fetches' address+size:
each unique static instruction covers ``[address, address+size)``; those byte
ranges are unioned and bucketed by page, and utilization = executed bytes / 4096.

Works directly off existing trace + layout files -- no re-tracing:

    analyse/venv/bin/python analyse/page_utilization.py \\
        tmp/actix_experiment_1/actix_server \\
        tmp/actix_experiment_1/actix_optimised_server \\
        --save tmp/actix_experiment_1/page_utilization.png
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd

import matplotlib

# Use a real GUI backend for the interactive window (checkboxes to toggle each
# histogram), but let an explicit MPLBACKEND override win -- e.g.
# MPLBACKEND=Agg for a headless --save run, where plt.show() becomes a no-op.
if "MPLBACKEND" not in os.environ:
    matplotlib.use("QtAgg")
import matplotlib.pyplot as plt  # noqa: E402  (after backend selection)
from matplotlib.widgets import CheckButtons  # noqa: E402

# Categorical hues from the dataviz reference palette; before=red, after=blue to
# match the existing scatter plot (plot_static_code_accesses.py).
COLOR_BEFORE = "#e34948"
COLOR_AFTER = "#2a78d6"
PAGE_BYTES = 4096


def page_utilization(binary: Path) -> np.ndarray:
    """Return an array with one entry per touched static-code page: the fraction
    (0..1) of that page's 4096 bytes that are executed during startup."""
    layout_path = Path(str(binary) + ".layout.json")
    trace_path = Path(str(binary) + ".memtrace.csv")

    layout = json.loads(layout_path.read_text())
    page_size = layout["page_size"]
    shift = page_size.bit_length() - 1  # 4096 -> 12

    # Function [start, end) intervals = the binary's own static code (same filter
    # as count_startup_pages.py / the scatter plot).
    funcs = pd.DataFrame(layout["functions"])
    starts = funcs["runtime_start"].apply(lambda s: int(s, 16)).to_numpy(np.int64)
    ends = funcs["runtime_end"].apply(lambda s: int(s, 16)).to_numpy(np.int64)
    keep = ends > starts
    starts, ends = starts[keep], ends[keep]
    order = np.argsort(starts, kind="stable")
    starts, ends = starts[order], ends[order]

    # Instruction fetches, keeping the size column this time (byte width of the
    # instruction) so we know how many bytes each fetch actually executes.
    df = pd.read_csv(trace_path, dtype={"type": str, "address": str, "size": int})
    fetch = df.loc[df["type"] == "I", ["address", "size"]]
    addr = fetch["address"].apply(lambda s: int(s, 16)).to_numpy(np.int64)
    size = fetch["size"].to_numpy(np.int64)

    # Restrict to fetches inside a known function (static code).
    idx = np.searchsorted(starts, addr, side="right") - 1
    mask = idx >= 0
    mask[mask] &= addr[mask] < ends[idx[mask]]
    addr, size = addr[mask], size[mask]

    # The trace revisits the same instructions many times; utilization only cares
    # about which bytes are *ever* executed, so collapse to unique instructions
    # (a given address always has the same size).
    inst = pd.DataFrame({"addr": addr, "size": size}).drop_duplicates("addr")
    uaddr = inst["addr"].to_numpy(np.int64)
    usize = inst["size"].to_numpy(np.int64)

    # Expand each instruction [addr, addr+size) into its individual byte
    # addresses: total bytes = sum(usize); each byte is addr + its offset within
    # the instruction. np.repeat(uaddr, usize) gives the base per byte; the
    # offset is arange(total) minus each instruction's exclusive-prefix start.
    total = int(usize.sum())
    prefix = np.repeat(np.cumsum(usize) - usize, usize)
    within = np.arange(total, dtype=np.int64) - prefix
    byte_addr = np.repeat(uaddr, usize) + within

    # Dedup bytes (guards against any overlapping instruction decodings), then
    # count executed bytes per page and divide by the page size.
    byte_addr = np.unique(byte_addr)
    page_of_byte = byte_addr >> shift
    _pages, exec_bytes = np.unique(page_of_byte, return_counts=True)
    return exec_bytes / PAGE_BYTES


def summarize(name: str, util: np.ndarray) -> None:
    print(
        f"{name:<26} pages={util.size:>4}  "
        f"mean={util.mean() * 100:5.1f}%  median={np.median(util) * 100:5.1f}%  "
        f"under-25%={(util < 0.25).mean() * 100:4.1f}%"
    )


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("before", type=Path, help="Original binary")
    p.add_argument("after", type=Path, help="Reordered binary")
    p.add_argument("--save", type=Path, help="Write the histogram PNG here")
    args = p.parse_args()

    before = page_utilization(args.before)
    after = page_utilization(args.after)
    summarize(args.before.name, before)
    summarize(args.after.name, after)

    bins = np.linspace(0, 1, 21)  # 5%-wide buckets
    fig, ax = plt.subplots(figsize=(10, 6))
    labels = [
        f"{args.before.name} ({before.size} pages)",
        f"{args.after.name} ({after.size} pages)",
    ]
    # hist returns (counts, edges, patches); keep the patch containers so the
    # checkboxes can toggle each histogram's visibility.
    _, _, patches_before = ax.hist(
        before, bins=bins, color=COLOR_BEFORE, alpha=0.6, label=labels[0],
    )
    _, _, patches_after = ax.hist(
        after, bins=bins, color=COLOR_AFTER, alpha=0.6, label=labels[1],
    )
    ax.set_xlabel("page utilization (executed bytes / 4096)")
    ax.set_ylabel("number of code pages")
    ax.set_title("Startup code-page utilization: before vs after reordering")
    ax.xaxis.set_major_formatter(lambda x, _: f"{x:.0%}")
    ax.grid(axis="y", color="#e1e0d9", linewidth=0.8)
    ax.set_axisbelow(True)
    ax.legend(loc="upper left")
    fig.tight_layout()

    if args.save:
        fig.savefig(args.save, dpi=150)
        print(f"==> saved {args.save}")

    # Checkboxes (top-right, inside the axes) to show before / after / both.
    groups = [patches_before, patches_after]
    rax = fig.add_axes([0.62, 0.72, 0.26, 0.13])
    rax.set_facecolor("none")
    check = CheckButtons(rax, labels, [True, True])
    # Tint each checkbox label with its histogram colour for quick association.
    for text, colour in zip(check.labels, (COLOR_BEFORE, COLOR_AFTER)):
        text.set_color(colour)

    def toggle(clicked_label: str) -> None:
        i = labels.index(clicked_label)
        visible = not groups[i][0].get_visible()
        for patch in groups[i]:
            patch.set_visible(visible)
        fig.canvas.draw_idle()

    check.on_clicked(toggle)
    plt.show()


if __name__ == "__main__":
    main()
