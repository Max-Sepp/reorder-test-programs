#!/usr/bin/env python3
"""Reorder a binary's functions into startup-execution order with LLVM BOLT.

This is the end-to-end driver: given a binary already linked with the
relocations BOLT needs (``-Wl,--emit-relocs``), it runs the whole flow --

    trace startup  ->  map fetches to functions  ->  order by first execution
                    ->  llvm-bolt --reorder-functions=user

-- and writes out a reordered binary whose functions are laid out in the order
they are first executed during startup (so the pages touched at startup are
packed together).

The analysis half is reused wholesale from order_functions_by_execution.py
(same directory); this script adds the relocation check and the BOLT call.

Example:
    # Build a reloc-enabled binary, then reorder it.
    ( cd rust && RUSTFLAGS="-C link-arg=-Wl,--emit-relocs" cargo build -p axum-server )
    analyse/venv/bin/python analyse/reorder_binary.py \\
        rust/target/debug/axum_server --port 8090 -o axum_server.bolt
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import order_functions_by_execution as order


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


# --- Relocation pre-check ---------------------------------------------------


def has_emit_relocs(binary: Path) -> bool:
    """True if the binary was linked with -Wl,--emit-relocs, which BOLT needs to
    rewrite code. That flag keeps per-section relocations like ``.rela.text``; a
    normal linked binary only carries ``.rela.dyn`` / ``.rela.plt``."""
    sections = subprocess.run(
        ["readelf", "-SW", str(binary)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return ".rela.text" in sections


# --- BOLT --------------------------------------------------------------------


def run_bolt(
    bolt: str,
    binary: Path,
    output: Path,
    order_path: Path,
    extra_args: list[str],
) -> None:
    """Invoke llvm-bolt to reorder functions according to order_path."""
    cmd = [
        bolt,
        str(binary),
        "-o",
        str(output),
        "--reorder-functions=user",
        f"--function-order={order_path}",
        *extra_args,
    ]
    log(f"==> Running BOLT: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)


# --- CLI --------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Trace a binary's startup and reorder its functions into "
        "first-execution order with LLVM BOLT.",
    )
    p.add_argument(
        "binary",
        type=Path,
        help="Binary to reorder. Must be linked with -Wl,--emit-relocs.",
    )
    p.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Reordered binary to write (default: <binary>.bolt).",
    )
    p.add_argument(
        "--order",
        type=Path,
        help="BOLT function-order file. Reused if it exists, else generated "
        "here (default: <binary>.bolt-order.txt).",
    )
    p.add_argument(
        "--trace",
        type=Path,
        help="Memory-trace CSV, forwarded to the analysis pipeline "
        "(default: <binary>.memtrace.csv).",
    )
    p.add_argument(
        "--layout",
        type=Path,
        help="ELF layout JSON, forwarded to the analysis pipeline "
        "(default: <binary>.layout.json).",
    )
    p.add_argument(
        "--port",
        type=int,
        default=8080,
        help="Port the server listens on during tracing (default: 8080).",
    )
    p.add_argument(
        "--strategy",
        choices=sorted(order.STRATEGIES),
        default="first-touch",
        help="Ordering strategy (default: first-touch).",
    )
    p.add_argument(
        "--bolt",
        default="llvm-bolt",
        help="llvm-bolt executable to use (default: llvm-bolt on PATH).",
    )
    p.add_argument(
        "--bolt-arg",
        action="append",
        default=[],
        metavar="ARG",
        help="Extra argument passed through to llvm-bolt (repeatable).",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="Regenerate the trace, layout and order even if cached.",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    binary = args.binary
    if not binary.is_file():
        raise SystemExit(f"error: binary not found: {binary}")

    if not has_emit_relocs(binary):
        raise SystemExit(
            f"error: {binary} has no code relocations; BOLT needs the binary "
            "linked with -Wl,--emit-relocs.\n"
            "  Rust: RUSTFLAGS=\"-C link-arg=-Wl,--emit-relocs\" cargo build ...\n"
            "  C/C++: add LDFLAGS=-Wl,--emit-relocs"
        )

    output = args.output or binary.with_name(binary.name + ".bolt")
    order_path = args.order or order.default_order_path(binary)
    trace_path = args.trace or order.default_trace_path(binary)
    layout_path = args.layout or order.default_layout_path(binary)

    # Reuse the existing order file unless we're forcing a fresh run.
    if order_path.exists() and not args.force:
        log(f"==> Reusing cached function order {order_path}")
    else:
        ordered = order.compute_order(
            binary, trace_path, layout_path, args.port, args.strategy, args.force
        )
        order_path.write_text("".join(name + "\n" for name in ordered))
        log(f"==> Wrote function order to {order_path}")

    run_bolt(args.bolt, binary, output, order_path, args.bolt_arg)

    log(
        f"==> Reordered {binary} ({binary.stat().st_size:,} B) "
        f"-> {output} ({output.stat().st_size:,} B)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
