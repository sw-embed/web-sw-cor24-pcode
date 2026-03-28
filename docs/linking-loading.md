# Linking and Loading: P-Code Toolchain Architecture

## Overview

The p-code toolchain compiles Pascal source to executable p-code binaries
that run on the pv24a virtual machine (hosted on the COR24 emulator).
The toolchain is designed around text-based `.spc` (symbolic p-code)
as the interchange format. All linking happens at the .spc text level —
there is no binary linker. A single merged .spc file is assembled into
a `.p24` binary, which is the input to the loader.

## Toolchain Pipeline

```
Pascal source (.pas)
    |
    v
p24p (Pascal compiler, C, runs on COR24 via tc24r)
    |  emits .spc files (one per module/unit)
    v
.spc files (app)  +  .spc files (user libs)  +  .spc files (runtime/pr24p)
    |                      |                          |
    +----------------------+--------------------------+
    |
    v
pl24r (text-level linker, Rust)         <-- exists, awaiting .<meta> support
    |  concatenates + resolves cross-module references
    |  all symbol resolution happens here, at the text level
    v
one merged .spc file (all symbols resolved)
    |
    v
pa24r (assembler, Rust)                 <-- to be created
    |  two-pass assembly, resolves all offsets
    |  library crate with thin CLI wrapper
    v
.p24 (p-code binary, self-contained)
    |
    v
loader → pvm (VM) → COR24 emulator
```

### Key Design Principle: No Binary Linker

All linking is text-level concatenation and symbol resolution in .spc
format. By the time pa24r sees the merged .spc, every symbol reference
is resolvable — forward references are handled by two-pass assembly.
The .p24 output is a fully-resolved, self-contained binary. The loader's
job is simply to place bytes in memory and initialize VM state.

### Existing Projects

| Project | Language | Location | Status |
|---------|----------|----------|--------|
| p24p    | C (compiled by tc24r) | `~/github/softwarewrighter/p24p` | Pascal compiler emitting .spc |
| pr24p   | Pascal + hand-written .spc | `~/github/softwarewrighter/pr24p` | Runtime library source files |
| pl24r   | Rust | `~/github/softwarewrighter/pl24r` | Text-level linker, awaiting .<meta> producers/consumers |
| pv24a   | COR24 assembly | `~/github/sw-vibe-coding/pv24a` | VM + assembler (pvm.s, pasm.s, pvmasm.s) |
| cor24-rs | Rust | `~/github/sw-embed/cor24-rs` | COR24 assembler + emulator |
| tc24r   | Rust | `~/github/sw-vibe-coding/tc24r` | C compiler for COR24 |

### To Be Created

| Project | Language | Purpose |
|---------|----------|---------|
| pa24r   | Rust | P-code assembler: .spc -> .p24 binary (library + CLI) |

## The Runtime Library (pr24p)

The Pascal runtime (pr24p) is a collection of source files:

- **Pascal modules** compiled by p24p to .spc (e.g., string handling,
  I/O formatting)
- **Hand-coded .spc files** for low-level primitives that can't be
  expressed in Pascal (e.g., `writeln` in early bootstrap, syscall
  wrappers)

These are *not* a pre-built binary. They are source-level inputs to the
toolchain, just like user code. The pipeline treats them identically:

1. Pascal runtime sources → p24p → .spc files
2. Hand-coded .spc files pass through as-is
3. pl24r concatenates all .spc files (app + user libs + runtime) into
   one merged .spc
4. pa24r assembles the merged .spc into one .p24 binary

The runtime is statically included in every binary. For the COR24's
constrained memory, this is appropriate — the runtime is small, and
there is no OS to provide shared libraries.

## The .spc Format (Evolving)

The `.spc` (symbolic p-code) format is the human-readable assembly language
for the p-code VM. It currently supports:

```
; Comments
.data <name> <byte>, <byte>, ...     ; data blocks
.global <name> <count>               ; global variables
.proc <name> <nargs>                 ; procedure definition
.end                                 ; end of procedure
<label>:                             ; code labels
<mnemonic> [operand]                 ; instructions
```

### Planned Metadata Extensions

The `.spc` format is evolving to support modular compilation and
text-level linking. Planned directives (being worked on) include:

- `.module <name>` -- declares the module name for this compilation unit
- `.extern <symbol>` -- references a symbol defined in another module
- `.export <symbol>` -- makes a symbol visible to other modules
- `.import <module>` -- declares a module dependency

These metadata directives enable `pl24r` to validate and resolve
cross-module references during text-level concatenation. By the time
the merged .spc reaches pa24r, all `.extern` references have been
matched to their `.export` definitions and the assembler sees a flat
symbol namespace with no unresolved references.

## The .p24 Binary Format (Proposed)

A simple binary container with a header, designed to be minimal now but
extensible as the toolchain matures.

```
Offset  Size   Field
0x00    4      magic: "P24\0"
0x04    1      version (currently 1)
0x05    3      entry_point (offset into code segment)
0x08    3      code_size (bytes)
0x0B    3      data_size (bytes)
0x0E    3      global_count (number of 3-byte words)
0x11    1      flags (bit 0: has_debug)
0x12    ...    code bytes
0x12+C  ...    data bytes
              --- future sections ---
              debug info (see Debug Information section)
```

The 3-byte (24-bit) fields match the COR24 word size. All multi-byte
values are little-endian.

Since all linking and symbol resolution happens at the .spc text level,
the .p24 format does not need relocation tables or import tables. Every
address in the binary is a fully-resolved segment-relative offset.

## Loading Strategies

### Why Loading Matters

The current approach (pvmasm.s) runs the p-code assembler *inside* the
COR24 emulator, parsing .spc text at emulated instruction speed. Hello
World takes ~14M COR24 instructions just to assemble and start executing.
The assembler is valuable as a self-hosted test of the COR24 platform,
but for interactive debugging, a fast loading path is essential.

### Current: COR24-Hosted Assembler (pvmasm.s)

- Feeds .spc source via UART to the integrated assembler+VM
- Assembler runs inside the emulator (~14M instructions for Hello World)
- **Keep as a feature**: useful for testing the COR24 platform and the
  assembler itself; the web debugger can offer this as a "run from source"
  mode

### Proposed: Rust-Side Loader

The Rust toolchain (pa24r) assembles .spc to .p24 at native speed.
A loader module reads the .p24 header and writes code+data segments
directly into the emulator's memory, initializes VM state registers
(PC, ESP, CSP, GP, HP), and the VM begins executing immediately.
Zero emulated instructions wasted on loading.

For the web debugger:
- Demos carry `include_bytes!("../demos/hello.p24")` pre-assembled binaries
- The loader patches emulator memory and initializes VM state
- Uses `pvm.s` (simple VM, no assembler) as the host program
- pvmasm.s remains available as a "run from source" mode

## Code Addressing

P-code instructions encode addresses as segment-relative offsets:

- **`jmp`, `jz`, `jnz`, `call`** — offsets into the code segment.
  The VM adds `code_base` at runtime when fetching.
- **`push <data-label>`** — offsets relative to the data segment base.
- **`push <global-label>`** — offsets relative to GP (globals pointer).

All addresses are segment-relative, making p-code effectively
position-independent at the segment level. The loader places each
segment anywhere in memory and sets the VM's base registers. No
relocation table is needed in .p24.

Since all cross-module symbol resolution happens at the .spc text level
(in pl24r), and pa24r assembles the fully-merged result, all offsets in
the .p24 binary are final. Relocation is a concern for the linker and
assembler, not the loader or binary format.

## Dependency Architecture

The loader needs to write into emulator memory, but the emulator should
not depend directly on the p-code loader. The cleanest approach avoids
circular dependencies entirely.

### Preferred Approach: Loader as Independent Crate

The loader crate (`p24-loader` or similar) depends on the .p24 format
definition but does *not* depend on cor24-rs. Instead, it exposes a
loaded image struct:

```rust
pub struct LoadedImage {
    pub entry_point: u32,
    pub code: Vec<u8>,
    pub data: Vec<u8>,
    pub global_count: u32,
}
```

The *consumer* (web-dv24r, cor24-run, or a test harness) depends on both
the loader crate and cor24-rs, and handles the actual memory patching:

```
p24-format   (format definitions, no dependencies)
    ^
    |
p24-loader   (parses .p24, produces LoadedImage)
    ^
    |
web-dv24r    (depends on p24-loader + cor24-rs, patches memory)
cor24-run    (same pattern)
```

This avoids any circular dependency. The emulator never knows about p-code.
The loader never knows about the emulator. The application (web-dv24r)
is the integration point that knows both.

### Alternative: Trait-Based Injection

If deeper integration is needed later (e.g., the loader needs to call
emulator APIs during loading), a trait-based approach decouples the
interface from the implementation:

```rust
// In p24-loader crate
pub trait MemoryTarget {
    fn write_bytes(&mut self, addr: u32, data: &[u8]);
    fn write_word(&mut self, addr: u32, value: u32);
}

// In web-dv24r (or cor24-rs)
impl MemoryTarget for EmulatorCore { ... }
```

This is likely unnecessary given that all symbol resolution happens at
the .spc level and the .p24 binary is self-contained, but remains an
option if future requirements introduce load-time complexity.

## Implementation Order

1. **pa24r**: Create Rust p-code assembler (.spc -> .p24)
   - Library crate with thin CLI wrapper
   - Reuse or reference pasm.s opcode/mnemonic tables
   - Two-pass assembly (same algorithm as pasm.s, but at native speed)
   - Emit .p24 binary format

2. **p24-loader**: Create loader crate (or module within pa24r)
   - Parse .p24 header, extract segments
   - Return LoadedImage struct

3. **web-dv24r integration**: Add fast loading path
   - Build demos with pa24r at build time (build.rs or pre-built)
   - Loader patches emulator memory, initializes VM state
   - Switch to pvm.s for fast-load demos
   - Keep pvmasm.s as "run from source" option

4. **.<meta> support**: When p24p and pl24r implement module metadata
   - Extend .spc with .module/.extern/.export/.import
   - pl24r resolves cross-module references during text-level merge
   - pa24r and .p24 format unchanged — they see only resolved symbols

## Resolved Design Decisions

### 1. pa24r: Library with Thin CLI

Library-first design. The library is the core value — web-dv24r calls
it from build.rs to pre-assemble demos, tests call it directly, and
the CLI is a one-file wrapper for command-line use. This matches the
pattern established by tc24r and cor24-rs.

### 2. Code Addressing: Segment-Relative (Already PIC)

P-code addresses are segment-relative offsets, not absolute memory
addresses. The VM resolves them at runtime using base registers
(code_base, GP, HP). This makes p-code effectively position-independent
at the segment level. No relocation table needed in .p24.

All "relocation" work (adjusting offsets when merging modules) happens
at the .spc text level in pl24r, or during assembly in pa24r's two-pass
resolution. By the time .p24 is emitted, all offsets are final.

### 3. Extern Resolution: Text-Level, Not Binary-Level

Cross-module symbol resolution is entirely a text-level concern handled
by pl24r. The linker concatenates .spc files and resolves `.extern`
references against `.export` definitions. The assembled result is one
flat .spc with no unresolved symbols. pa24r assembles it into a
self-contained .p24 with no import tables.

There is no binary linker in this design. The loader's only job is to
place bytes in memory and initialize VM state. If a future use case
requires load-time symbol resolution (e.g., dynamically loaded plugins),
it could be added then, but it is not part of the current architecture.

### 4. Runtime Library: Source-Level Input

The runtime (pr24p) is a set of Pascal source files and hand-coded .spc
files. These are compiled/collected into .spc files and concatenated
with application code by pl24r, just like any other module. The
assembler (pa24r) produces one binary containing everything. The loader
doesn't distinguish runtime code from application code.

## Future: Debug Information

The .p24 format should support optional debug information for the web
debugger. This enables source-level debugging of Pascal programs:
viewing Pascal source alongside p-code disassembly, inspecting named
variables, and setting breakpoints by source line.

### Proposed Debug Section Format

When the `has_debug` flag (bit 0) is set in the .p24 header, a debug
section follows the data segment:

```
Debug Section Header:
    3 bytes    debug_size (total size of debug section)
    1 byte     debug_version

Source File Table:
    3 bytes    file_count
    For each file:
        1 byte     filename_length
        N bytes    filename (UTF-8)

Line Number Table:
    3 bytes    entry_count
    For each entry:
        3 bytes    code_offset (byte offset into code segment)
        2 bytes    file_index (index into source file table)
        2 bytes    line_number

Symbol Table (local variables, parameters):
    3 bytes    symbol_count
    For each symbol:
        1 byte     name_length
        N bytes    name (UTF-8)
        1 byte     kind (0=parameter, 1=local, 2=global)
        3 bytes    scope_start (code offset where symbol is in scope)
        3 bytes    scope_end
        1 byte     slot (frame offset for locals/params, global index)
```

### Debug Information Pipeline

Debug info flows through the toolchain:

1. **p24p (compiler)** emits `.debug_line` and `.debug_sym` directives
   in .spc output, annotating code with source locations and variable
   bindings
2. **pl24r (linker)** preserves debug directives during concatenation,
   adjusting file references as needed
3. **pa24r (assembler)** collects debug directives during assembly and
   emits the debug section in .p24, mapping source locations to final
   code offsets
4. **p24-loader** extracts the debug section from .p24 and provides it
   alongside the LoadedImage
5. **web-dv24r** uses the debug info to show source lines, variable
   names, and support source-level breakpoints

### Debugger Integration

With debug info available, the web debugger can offer:

- **Source panel**: show Pascal source with current line highlighted
- **Variable inspector**: display named locals and parameters with
  current values, instead of raw frame offsets
- **Source breakpoints**: click a Pascal source line to set a breakpoint
  at the corresponding p-code offset
- **Step-by-source-line**: step one Pascal statement at a time (may
  span multiple p-code instructions)

Debug info is optional — the debugger falls back to p-code disassembly
with raw offsets when no debug section is present. This keeps the
debugger useful for hand-coded .spc programs and release builds that
strip debug info.
