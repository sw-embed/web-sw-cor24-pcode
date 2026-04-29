# Changes

## 2026-04-29

- **ac9d423** feat: add Blog/Discord/YouTube/Demos footer links to match
  web-sw-cor24-basic
- **7f9426e** chore: rebuild pages/ for deploy (host reg names + new opcodes)
- **f6d5c76** feat: new pcode opcodes, p-code breakpoints, COR24 reg names
  - Added memcpy/memset/memcmp/jmp_ind/xcall/xloadg/xstoreg pcode opcodes
    in pvm.s + pvmasm.s, plus three demos (t11-memcpy, t14-memcmp,
    t15-jmp_ind)
  - VM bootstrap detects .p24m magic, supports IRT base + multiple units,
    LED/switch port remapped to 0xFF0000
  - Clickable disasm lines toggle p-code breakpoints (Clear BPs button,
    red-tinted breakpoint marker)
  - COR24 Host panel uses canonical register names
    (r0, r1, r2, fp, sp, z, iv, ir) instead of r0..r7; carry shown as
    lowercase `c`
  - pcode instruction sizing now delegates to pa24r so the size table
    cannot drift from the canonical encoding
- **58e6588** chore: rebuild pages/ for GitHub Pages deploy + README epilog
  (Blog/Discord/YouTube links, split Copyright/License sections)

## 2026-03-30

- **20f9460** refactor: rename cross-tools with x- prefix

## 2026-03-29

- **9da9f67** chore: fork web-dv24r to web-sw-cor24-pcode under sw-embed
  - Renamed package, updated path deps to ../sw-cor24-pcode and
    ../sw-cor24-emulator
  - Updated Trunk.toml public_url, GitHub links, tests, and documentation
  - Removed stale pages/ build artifacts

## 2026-03-28

- **9e07656** feat: fast .p24 loading, CLI pipeline, GitHub Pages deployment
  - Replaced in-WASM COR24 assembler with build-time pre-assembly via pa24r
    (Hello World: 4,447x speedup, 14.4M → 3,040 COR24 instructions)
  - Loader: load_p24_image() with data relocation, two-phase VM init
  - Added run-pascal.sh CLI (compile → link → assemble → run)
  - Added GitHub Pages: pages/ dir, .nojekyll, pages.yml workflow,
    build-pages.sh
  - Added regression tests: call_trace.rs, loader_test.rs

## 2026-03-26

- **9f25c04** feat: add demo registry with 6 p-code programs and UART input

## 2026-03-25

- **c2fda6d** feat: add hex memory viewer panel and step-over/step-out modes
- **82c9203** feat: add call frame panel, memory map, instruction count, and
  change highlighting
- **650ef8c** feat: add p-code disassembly panel and two-level debugging
- **f7c267f** docs(project): add README, COPYRIGHT, and LICENSE
- **1892fd9** feat: scaffold Yew/WASM debugger project with Trunk build
- **4fbe3d7** chore(project): initialize web-dv24r with design docs and
  agentrail saga
- **9a9b560** initial commit
