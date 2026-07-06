#!/usr/bin/env python3
"""Which functions are *never* executed during startup? The cold-code footprint.

The rest of the pipeline measures what startup touches (pages, utilization,
first-touch order). This is the complement: functions in the binary's own code
with zero instruction fetches during the startup + first-request trace(s). For a
managed-runtime binary that is the bulk of it -- Scala Native http4s has ~23k
functions but startup runs only ~3.6k -- and attributing the dead bytes to
subsystems (scala.scalanative.*, cats.effect.*, java.*, org.http4s.*) shows *what*
the tight startup working set leaves behind.

Reuses the same layout parser + fetch->function mapper as the ordering pipeline
(analyse/order_functions_by_execution.py), so "touched" here is identical to the
set that feeds BOLT's --function-order; untouched is exactly its complement.

Works off existing trace + layout files -- no re-tracing:

    analyse/venv/bin/python analyse/untouched_functions.py \\
        tmp/qemu_experiment_2_release/http4s_server

Union several requests into the touched set (so untouched is conservative) by
passing --trace repeatedly:

    ... http4s_server --trace .../http4s_server.memtrace.csv \\
                      --trace .../http4s_server.post.memtrace.csv
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import numpy as np
import pandas as pd

# Reuse the layout parser and the vectorised fetch->function mapper rather than
# re-deriving them; "touched" is then identical to the ordering pipeline's set.
from order_functions_by_execution import (
    default_layout_path,
    default_trace_path,
    load_instruction_functions,
    load_layout,
)

# Executable sections whose functions count as the binary's own static code (same
# spirit as the [start,end) function filter used elsewhere).
CODE_SECTIONS = {".text", ".init", ".fini"}

# Scala Native mangles symbols as _SM<len><readable.dotted.path>...; strip the
# prefix to recover the dotted path we bucket on.
_SN_PREFIX = re.compile(r"^_S[A-Z]\d+")


def _rust_components(mangled: str) -> list[str] | None:
    """Legacy Rust (_ZN) names are length-prefixed component lists ending in E,
    e.g. _ZN12regex_syntax3ast6ParserE -> [regex_syntax, ast, Parser]. Return the
    components, or None if this isn't a legacy Rust symbol."""
    if not mangled.startswith("_ZN"):
        return None
    s, parts = mangled[3:], []
    while s and s[0].isdigit():
        m = re.match(r"\d+", s)
        n = int(m.group())
        s = s[m.end():]
        comp = s[:n]
        s = s[n:]
        # Skip the trailing disambiguating hash component (17h<hex>).
        if not re.fullmatch(r"h[0-9a-f]+", comp):
            parts.append(comp)
    return parts or None


def subsystem(mangled: str, depth: int = 2) -> str:
    """Coarse owning-subsystem bucket for a symbol, e.g. 'scala.scalanative',
    'cats.effect', 'regex_syntax::ast'. Handles Scala Native (_SM, dotted) and
    legacy Rust (_ZN, length-prefixed) manglings; anything else falls back to its
    leading token. Keeps the first `depth` components."""
    rust = _rust_components(mangled)
    if rust is not None:
        return "::".join(rust[:depth]) if rust else "<other>"
    name = _SN_PREFIX.sub("", mangled)
    # Cut at the first component separator that isn't part of the package path.
    name = re.split(r"[($<]", name, maxsplit=1)[0]
    parts = [p for p in name.split(".") if p]
    if not parts:
        return "<other>"
    return ".".join(parts[:depth])


def load_universe(layout_path: Path) -> pd.DataFrame:
    """All own-code functions with size > 0, keyed by mangled_name."""
    layout = json.loads(layout_path.read_text())
    funcs = pd.DataFrame(layout["functions"])
    funcs = funcs[(funcs["size"] > 0) & funcs["section"].isin(CODE_SECTIONS)]
    # A symbol can appear once; guard against duplicate names collapsing bytes.
    funcs = funcs.drop_duplicates("mangled_name").reset_index(drop=True)
    return funcs[["mangled_name", "name", "size", "section"]]


def touched_names(traces: list[Path], layout_path: Path) -> set[str]:
    """Union of mangled function names hit by an I fetch across all traces."""
    starts, ends, names = load_layout(layout_path)
    touched: set[str] = set()
    for trace in traces:
        mapped = load_instruction_functions(trace, starts, ends, names)
        touched |= set(mapped.unique())
    return touched


def fmt_mb(nbytes: int) -> str:
    return f"{nbytes / 1_048_576:.2f} MB"


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("binary", type=Path, help="Binary to analyse.")
    p.add_argument("--trace", type=Path, action="append", dest="traces",
                   help="Memory-trace CSV (repeatable; union). "
                        "Default: <binary>.memtrace.csv.")
    p.add_argument("--layout", type=Path,
                   help="ELF layout JSON (default: <binary>.layout.json).")
    p.add_argument("--top", type=int, default=20,
                   help="How many subsystems to list (default: 20).")
    p.add_argument("--depth", type=int, default=2,
                   help="Dotted components per subsystem bucket (default: 2).")
    p.add_argument("--list-file", type=Path,
                   help="Write the untouched mangled names here, one per line.")
    args = p.parse_args()

    layout_path = args.layout or default_layout_path(args.binary)
    traces = args.traces or [default_trace_path(args.binary)]

    for path in [layout_path, *traces]:
        if not path.exists():
            raise SystemExit(
                f"error: required file missing: {path}\n"
                "  layout  <- scripts/analyse/elf_page_layout.sh <binary> <out>.layout.json\n"
                "  trace   <- scripts/analyse/measure_qemu_startup_and_request.sh (Scala Native)\n"
                "             or measure_valgrind_startup_and_request.sh (Rust), reduced to\n"
                "             the compact I-only memtrace the analysis scripts read."
            )

    universe = load_universe(layout_path)
    touched = touched_names(traces, layout_path)

    is_touched = universe["mangled_name"].isin(touched)
    hot = universe[is_touched]
    cold = universe[~is_touched]

    total_n, total_b = len(universe), int(universe["size"].sum())
    hot_n, hot_b = len(hot), int(hot["size"].sum())
    cold_n, cold_b = len(cold), int(cold["size"].sum())

    print(f"{args.binary.name}   functions {total_n:,}   code {fmt_mb(total_b)}")
    print(f"  touched at startup: {hot_n:>7,}  ({hot_n/total_n*100:5.1f}%)   "
          f"{fmt_mb(hot_b)}  ({hot_b/total_b*100:.1f}% of code bytes)")
    print(f"  UNTOUCHED:          {cold_n:>7,}  ({cold_n/total_n*100:5.1f}%)   "
          f"{fmt_mb(cold_b)}  ({cold_b/total_b*100:.1f}% of code bytes)")
    # Invariant: the two partitions must exactly reconstruct the universe.
    assert hot_n + cold_n == total_n and hot_b + cold_b == total_b

    # --- by subsystem (ranked by untouched bytes) ---
    sub = universe.assign(
        sub=universe["mangled_name"].map(lambda m: subsystem(m, args.depth)),
        cold=~is_touched,
    )
    grp = sub.groupby("sub").agg(
        total_bytes=("size", "sum"),
        dead_bytes=("size", lambda s: int(s[sub.loc[s.index, "cold"]].sum())),
        dead_funcs=("cold", "sum"),
        total_funcs=("cold", "size"),
    )
    grp = grp.sort_values("dead_bytes", ascending=False)

    print(f"\nuntouched bytes by subsystem (top {args.top}):")
    print(f"  {'subsystem':<28}{'dead bytes':>12}{'dead funcs':>12}"
          f"{'% subsys dead':>15}")
    for name, r in grp.head(args.top).iterrows():
        pct = r.dead_bytes / r.total_bytes * 100 if r.total_bytes else 0.0
        print(f"  {name:<28}{fmt_mb(int(r.dead_bytes)):>12}"
              f"{int(r.dead_funcs):>12,}{pct:>14.1f}%")

    # --- by section ---
    print("\nuntouched by section:")
    sec = cold.groupby("section")["size"].agg(["count", "sum"])
    for name, r in sec.iterrows():
        print(f"  {name:<8} {int(r['count']):>7,} funcs   {fmt_mb(int(r['sum']))}")

    if args.list_file:
        args.list_file.write_text(
            "".join(n + "\n" for n in cold["mangled_name"])
        )
        print(f"\n==> wrote {cold_n:,} untouched names to {args.list_file}")


if __name__ == "__main__":
    main()
