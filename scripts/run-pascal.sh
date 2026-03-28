#!/bin/bash
# run-pascal.sh — Compile and run a Pascal program on the COR24 p-code VM
#
# Usage: ./scripts/run-pascal.sh hello.pas
#        ./scripts/run-pascal.sh hello.pas --verbose
#
# Prerequisites: cor24-run, pl24r, pa24r in PATH or built locally
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <file.pas> [--verbose]"
    exit 1
fi

PAS_FILE="$1"
VERBOSE="${2:-}"
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

# Project paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
P24P="$HOME/github/softwarewrighter/p24p/p24p.s"
RUNTIME="$HOME/github/softwarewrighter/pr24p/src/runtime.spc"
PVM_S="$PROJECT_DIR/asm/pvm.s"
PL24R_DIR="$HOME/github/softwarewrighter/pl24r"
PA24R_DIR="$HOME/github/softwarewrighter/pa24r"

# Pre-assembled VM binary (cached)
PVM_BIN="$PROJECT_DIR/.cache/pvm.bin"
PVM_LABELS="$PROJECT_DIR/.cache/pvm_labels.txt"

# Step 0: Ensure pvm.bin is cached
if [ ! -f "$PVM_BIN" ] || [ "$PVM_S" -nt "$PVM_BIN" ]; then
    mkdir -p "$PROJECT_DIR/.cache"
    [ "$VERBOSE" = "--verbose" ] && echo "=== Assembling pvm.s ==="
    cor24-run --assemble "$PVM_S" "$PVM_BIN" /dev/null 2>/dev/null
    # Extract code_ptr address from assembly listing
    cor24-run --assemble "$PVM_S" /dev/null "$WORKDIR/pvm.lst" 2>/dev/null
    CODE_PTR=$(grep "^code_ptr:" "$WORKDIR/pvm.lst" 2>/dev/null | awk '{print $2}' || true)
    if [ -z "$CODE_PTR" ]; then
        # Fall back: assemble in Rust and grep labels
        CODE_PTR=$(cd "$PA24R_DIR" 2>/dev/null && python3 -c "
import subprocess, re
r = subprocess.run(['cargo','run','-q','--','--help'], capture_output=True, text=True)
" 2>/dev/null || echo "0x09DC")
        CODE_PTR="0x09DC"
    fi
    echo "$CODE_PTR" > "$PVM_LABELS"
    [ "$VERBOSE" = "--verbose" ] && echo "  pvm.bin: $(wc -c < "$PVM_BIN") bytes, code_ptr: $CODE_PTR"
fi
CODE_PTR=$(cat "$PVM_LABELS" 2>/dev/null || echo "0x09DC")

# Step 1: Compile Pascal → .spc
[ "$VERBOSE" = "--verbose" ] && echo "=== Compiling $(basename "$PAS_FILE") ==="
SPC_OUTPUT=$(printf '%s\x04' "$(cat "$PAS_FILE")" | \
    cor24-run --run "$P24P" --terminal --speed 0 --time 30 -n 50000000 2>&1)

# Extract .spc (between .module and ; OK)
echo "$SPC_OUTPUT" | sed -n '/^\.module/,/^; OK/p' > "$WORKDIR/program.spc"

if [ ! -s "$WORKDIR/program.spc" ]; then
    echo "COMPILE ERROR:"
    echo "$SPC_OUTPUT"
    exit 1
fi

if echo "$SPC_OUTPUT" | grep -q "; COMPILE ERROR"; then
    echo "COMPILE ERROR:"
    cat "$WORKDIR/program.spc"
    exit 1
fi

[ "$VERBOSE" = "--verbose" ] && echo "  $(wc -l < "$WORKDIR/program.spc") lines of .spc"

# Step 2: Link with runtime
[ "$VERBOSE" = "--verbose" ] && echo "=== Linking with runtime ==="
(cd "$PL24R_DIR" && cargo run -q -- "$RUNTIME" "$WORKDIR/program.spc" -o "$WORKDIR/merged.spc" 2>/dev/null)
[ "$VERBOSE" = "--verbose" ] && echo "  $(wc -l < "$WORKDIR/merged.spc") lines merged"

# Step 3: Assemble → .p24
[ "$VERBOSE" = "--verbose" ] && echo "=== Assembling ==="
(cd "$PA24R_DIR" && cargo run -q -- "$WORKDIR/merged.spc" -o "$WORKDIR/program.p24" 2>/dev/null)
[ "$VERBOSE" = "--verbose" ] && echo "  $(wc -c < "$WORKDIR/program.p24") bytes .p24"

# Step 3.5: Relocate data references for load address 0x010000
LOAD_ADDR=0x010000
python3 - "$WORKDIR/program.p24" "$LOAD_ADDR" << 'PYEOF'
import sys, struct
data = open(sys.argv[1], 'rb').read()
load_addr = int(sys.argv[2], 0)
code_size = int.from_bytes(data[8:11], 'little')
data_size = int.from_bytes(data[11:14], 'little')
body = bytearray(data[18:])
total = code_size + data_size
i = 0
while i < code_size:
    op = body[i]
    if op == 0x01 and i + 4 <= code_size:
        val = int.from_bytes(body[i+1:i+4], 'little')
        if code_size <= val < total:
            val += load_addr
            body[i+1:i+4] = val.to_bytes(3, 'little')
        i += 4
    elif op in (0x30,0x31,0x32,0x33,0x54,0x55,0x56,0x57): i += 4
    elif op in (0x02,0x34,0x35,0x36,0x40,0x42,0x43,0x48,0x49,0x46,0x60): i += 2
    elif op in (0x4A,0x4B): i += 3
    elif op == 0x4C: i += 5
    else: i += 1
# Write back with header stripped (raw binary for --load-binary)
open(sys.argv[1].replace('.p24', '.bin'), 'wb').write(body)
PYEOF
[ "$VERBOSE" = "--verbose" ] && echo "  relocated for $LOAD_ADDR"

# Step 4: Run
[ "$VERBOSE" = "--verbose" ] && echo "=== Running ==="
cor24-run \
    --load-binary "$PVM_BIN@0" \
    --load-binary "$WORKDIR/program.bin@0x010000" \
    --patch "$CODE_PTR=0x010000" \
    --entry 0 \
    --terminal -n 50000000 2>&1 | \
    grep -v "^Loaded\|^Patched\|^Entry\|^Executed\|^\[CPU\|^$"
