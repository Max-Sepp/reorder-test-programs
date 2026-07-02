#!/usr/bin/env bash
# Dump the memory layout of an ELF file as JSON: per section and per function,
# the runtime virtual-address range and the pages of memory it occupies when
# the binary is run under valgrind with ASLR disabled.
#
# The memory-access traces produced by measure_initial_startup_and_request.sh
# are just raw runtime addresses. This script is the "layout key" that maps
# those addresses back to sections and functions: valgrind loads a PIE client
# executable at a fixed base (0x04000000 on linux-amd64) when ASLR is off, so
# the layout is reproducible run-to-run. A non-PIE ET_EXEC keeps its link-time
# addresses (load bias 0).
#
# For every function the output includes BOTH the mangled name exactly as it
# appears in the binary's symbol table (the key a trace/nm/BOLT lookup uses) and
# the demangled name for readability.
#
# Output is JSON on stdout (or the given file); progress goes to stderr, so the
# JSON stream stays clean and pipeable into jq.
#
# Args:
#   $1: Path to the ELF file to analyse.
#   $2: Output JSON file (optional; defaults to stdout).
#
# Env:
#   VG_LOAD_BASE  Hex load base to use (e.g. 0x4000000), skipping auto-detection.
#   PAGE_SIZE     Page size in bytes (default 4096).
#
# Example:
#   # Build the Axum server, then dump its layout.
#   ( cd rust && cargo build -p axum-server )
#   scripts/analyse/elf_page_layout.sh rust/target/debug/axum_server | jq .
#
#   # Find which function a traced runtime address lives in (jq has no hex
#   # parser, so a small "hex" helper converts the 0x.. address strings):
#   scripts/analyse/elf_page_layout.sh rust/target/debug/axum_server > layout.json
#   jq -r --arg a 0x410eaaa '
#     def hex: ltrimstr("0x")
#       | reduce (explode[]) as $c (0; .*16 + (if $c<58 then $c-48 else $c-87 end));
#     ($a|hex) as $t
#     | .functions[]
#     | select(.runtime_end!=null and ($t >= (.runtime_start|hex))
#                                  and ($t <  (.runtime_end|hex)))
#     | "\(.name)  \(.runtime_start)..\(.runtime_end)"' layout.json

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <elf-file> [output-json-file]" >&2
    exit 2
fi

ELF="$1"
OUTPUT="${2:-}"
PAGE_SIZE="${PAGE_SIZE:-4096}"

if [ ! -r "$ELF" ] || ! readelf -h "$ELF" >/dev/null 2>&1; then
    echo "error: not a readable ELF file: $ELF" >&2
    exit 2
fi

# --- Determine ELF type and load bias (auto-detect by running valgrind) ------

# ELF type word: "DYN" (PIE) or "EXEC".
ELF_TYPE="$(readelf -h "$ELF" | awk '/^[[:space:]]*Type:/ {print $2; exit}')"

if [ -n "${VG_LOAD_BASE:-}" ]; then
    BIAS=$(( VG_LOAD_BASE ))
    BIAS_SOURCE="override (VG_LOAD_BASE)"
elif [ "$ELF_TYPE" = "DYN" ]; then
    # Valgrind places every PIE client executable at the same aspacem base, so
    # probing with a trivial PIE (cat) under the same valgrind, ASLR off, yields
    # the identical base the target will get. This avoids running the (long-lived,
    # port-binding) server just to read a base.
    echo "==> Auto-detecting valgrind PIE load base (ASLR off)" >&2
    base_hex="$(setarch -R valgrind -q --tool=none cat /proc/self/maps 2>/dev/null \
        | awk '/\/cat$/ {split($1, a, "-"); print a[1]; exit}')" || true
    if [ -n "$base_hex" ]; then
        BIAS=$(( 16#$base_hex ))
        BIAS_SOURCE="auto-detected (setarch -R valgrind --tool=none probe)"
    else
        BIAS=$(( 16#04000000 ))
        BIAS_SOURCE="fallback default 0x04000000 (valgrind probe unavailable)"
        echo "warning: valgrind probe failed; assuming base 0x04000000" >&2
    fi
else
    BIAS=0
    BIAS_SOURCE="ET_EXEC (no load bias)"
fi

echo "==> ELF type $ELF_TYPE, load bias $(printf '0x%x' "$BIAS")" >&2

# --- Build the JSON ----------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Sections: strip the "[Nr]" column to a bare leading index, then parse. The
# optional flags column is disambiguated by field count (11 tokens with flags,
# 10 without) -- section and type names never contain spaces. The NULL section
# (index 0) has an empty name, so it is skipped. Emits one JSON object per
# section and, as a side effect, an "ndx<TAB>name" map for function attribution.
readelf -SW "$ELF" \
    | sed -E 's/\[[[:space:]]*([0-9]+)\]/\1/' \
    | gawk -v bias="$BIAS" -v ps="$PAGE_SIZE" -v mapfile="$WORK/ndx2name" '
            flags = (NF >= 11) ? $8 : "";
            print idx "\t" name > mapfile;
            mapped = (index(flags, "A") > 0) ? "true" : "false";
            printf "%s{\"name\":\"%s\",\"type\":\"%s\",\"flags\":\"%s\",\"mapped\":%s,",
                   (seen++ ? "," : ""), jesc(name), jesc(type), jesc(flags), mapped;
            printf "\"link_addr\":\"0x%x\",\"size\":%d,", addr, size;
            if (mapped == "true") {
                rt = addr + bias;
                if (size > 0) {
                    pstart = int(rt / ps) * ps;
                    pend   = int((rt + size - 1) / ps) * ps;
                    npages = (pend - pstart) / ps + 1;
                    printf "\"runtime_addr\":\"0x%x\",\"page_start\":\"0x%x\",\"page_end\":\"0x%x\",\"num_pages\":%d}",
                           rt, pstart, pend, npages;
                } else {
                    printf "\"runtime_addr\":\"0x%x\",\"page_start\":null,\"page_end\":null,\"num_pages\":0}", rt;
                }
            } else {
                printf "\"runtime_addr\":null,\"page_start\":null,\"page_end\":null,\"num_pages\":0}";
            }
        }
    ' > "$WORK/sections.json"

# Functions: defined FUNC symbols (numeric Ndx, non-zero value) from .symtab or
# .dynsym, deduplicated by (value,name) while preserving order. Columns from
# `readelf -sW`: $2=value, $3=size, $4=type, $7=ndx, $8=mangled name.
readelf -sW "$ELF" 2>/dev/null \
    | awk '$1 ~ /:$/ && $4 == "FUNC" && $7 ~ /^[0-9]+$/ && $2 !~ /^0+$/ {
        key = $2 "\t" $8;
        if (!seen[key]++) print $2 "\t" $3 "\t" $7 "\t" $8;
    }' > "$WORK/funcs.tsv"

# Demangle the mangled names in one batch (order preserved), then re-join.
cut -f4 "$WORK/funcs.tsv" | c++filt > "$WORK/demangled.txt" 2>/dev/null \
    || cut -f4 "$WORK/funcs.tsv" > "$WORK/demangled.txt"

paste "$WORK/funcs.tsv" "$WORK/demangled.txt" \
    | gawk -F'\t' -v bias="$BIAS" -v ps="$PAGE_SIZE" -v mapfile="$WORK/ndx2name" '
        function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
        BEGIN {
            while ((getline line < mapfile) > 0) {
                split(line, m, "\t"); ndx2name[m[1]] = m[2];
            }
        }
        {
            value = strtonum("0x" $1); size = $2 + 0; ndx = $3;
            mangled = $4; demangled = $5;
            section = (ndx in ndx2name) ? ndx2name[ndx] : "";
            rt = value + bias;
            printf "%s{\"mangled_name\":\"%s\",\"name\":\"%s\",\"section\":\"%s\",",
                   (seen++ ? "," : ""), jesc(mangled), jesc(demangled), jesc(section);
            printf "\"link_addr\":\"0x%x\",\"runtime_start\":\"0x%x\",\"size\":%d,",
                   value, rt, size;
            if (size > 0) {
                rend = rt + size;
                pstart = int(rt / ps) * ps;
                pend   = int((rt + size - 1) / ps) * ps;
                npages = (pend - pstart) / ps + 1;
                printf "\"runtime_end\":\"0x%x\",\"page_start\":\"0x%x\",\"page_end\":\"0x%x\",\"num_pages\":%d}",
                       rend, pstart, pend, npages;
            } else {
                printf "\"runtime_end\":\"0x%x\",\"page_start\":null,\"page_end\":null,\"num_pages\":0}", rt;
            }
        }
    ' > "$WORK/functions.json"

# Assemble the top-level object.
{
    printf '{"file":"%s","elf_type":"%s","page_size":%d,"load_bias":"0x%x","load_bias_source":"%s",' \
        "$ELF" "$ELF_TYPE" "$PAGE_SIZE" "$BIAS" "$BIAS_SOURCE"
    printf '"sections":['
    cat "$WORK/sections.json"
    printf '],"functions":['
    cat "$WORK/functions.json"
    printf ']}'
} > "$WORK/layout.json"

# Pretty-print / validate through jq when available; otherwise emit compact JSON.
echo "==> Writing JSON layout${OUTPUT:+ to $OUTPUT}" >&2
if command -v jq >/dev/null 2>&1; then
    if [ -n "$OUTPUT" ]; then jq . "$WORK/layout.json" > "$OUTPUT"; else jq . "$WORK/layout.json"; fi
else
    if [ -n "$OUTPUT" ]; then cp "$WORK/layout.json" "$OUTPUT"; else cat "$WORK/layout.json"; fi
fi

echo "==> Done" >&2
