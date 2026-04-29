//! P-code VM debugger component — two-level debugging with p-code semantic
//! layer (primary) and COR24 host implementation layer (secondary drill-down).

use crate::config;
use crate::demos::DEMOS;
use cor24_emulator::{EmulatorCore, StopReason};
use gloo::timers::callback::Timeout;
use std::collections::{HashMap, HashSet, VecDeque};
use web_sys::HtmlInputElement;
use yew::prelude::*;

/// Execution batch size per tick (instructions).
const BATCH_SIZE: u64 = 50_000;

/// Tick interval in milliseconds.
const TICK_MS: u32 = 25;

/// Number of COR24 disassembly lines to show before current PC.
const DISASM_BEFORE: usize = 8;

/// Number of COR24 disassembly lines to show after current PC.
const DISASM_AFTER: usize = 16;

/// COR24 register names indexed by 3-bit register number.
/// Slot 5 is the constant `z` (also reads as the carry flag `c`).
const HOST_REG_NAMES: [&str; 8] = ["r0", "r1", "r2", "fp", "sp", "z", "iv", "ir"];

/// P-code opcode names indexed by opcode number.
/// Mirrors pa24r's Opcode enum — keep in sync with
/// `../sw-cor24-pcode/assembler/src/lib.rs`.
const PCODE_NAMES: &[(u8, &str)] = &[
    (0x00, "halt"),
    (0x01, "push"),
    (0x02, "push_s"),
    (0x03, "dup"),
    (0x04, "drop"),
    (0x05, "swap"),
    (0x06, "over"),
    (0x10, "add"),
    (0x11, "sub"),
    (0x12, "mul"),
    (0x13, "div"),
    (0x14, "mod"),
    (0x15, "neg"),
    (0x16, "and"),
    (0x17, "or"),
    (0x18, "xor"),
    (0x19, "not"),
    (0x1A, "shl"),
    (0x1B, "shr"),
    (0x20, "eq"),
    (0x21, "ne"),
    (0x22, "lt"),
    (0x23, "le"),
    (0x24, "gt"),
    (0x25, "ge"),
    (0x30, "jmp"),
    (0x31, "jz"),
    (0x32, "jnz"),
    (0x33, "call"),
    (0x34, "ret"),
    (0x35, "calln"),
    (0x36, "trap"),
    (0x40, "enter"),
    (0x41, "leave"),
    (0x42, "loadl"),
    (0x43, "storel"),
    (0x44, "loadg"),
    (0x45, "storeg"),
    (0x46, "addrl"),
    (0x47, "addrg"),
    (0x48, "loada"),
    (0x49, "storea"),
    (0x4A, "loadn"),
    (0x4B, "storen"),
    (0x50, "load"),
    (0x51, "store"),
    (0x52, "loadb"),
    (0x53, "storeb"),
    (0x60, "sys"),
    (0x70, "memcpy"),
    (0x71, "memset"),
    (0x72, "memcmp"),
    (0x73, "jmp_ind"),
    (0x74, "xcall"),
    (0x75, "xloadg"),
    (0x76, "xstoreg"),
];

/// vm_state struct field offsets (each field is a 24-bit word = 3 bytes).
mod vm_offsets {
    pub const PC: u32 = 0;
    pub const ESP: u32 = 3;
    pub const CSP: u32 = 6;
    pub const FP_VM: u32 = 9;
    pub const GP: u32 = 12;
    pub const HP: u32 = 15;
    pub const CODE: u32 = 18;
    pub const STATUS: u32 = 21;
    pub const TRAP_CODE: u32 = 24;
}

/// Decoded p-code instruction.
struct PcodeInstr {
    addr: u32,
    name: &'static str,
    operand: Option<u32>,
    size: u32,
}

/// A decoded call frame from the call stack.
struct CallFrame {
    /// Return p-code PC.
    return_pc: u32,
    /// Dynamic link (caller's fp_vm).
    dynamic_link: u32,
    /// Static link (for lexical scoping).
    static_link: u32,
    /// Saved eval stack pointer at call time.
    saved_esp: u32,
}

/// A named memory region for the region map.
struct MemRegion {
    name: &'static str,
    css_class: &'static str,
    start: u32,
    size: u32,
}

/// Selectable memory region for hex viewer.
#[derive(Clone, Copy, PartialEq)]
enum HexRegion {
    Code,
    EvalStack,
    CallStack,
    Globals,
    Heap,
}

impl HexRegion {
    fn label(self) -> &'static str {
        match self {
            Self::Code => "Code",
            Self::EvalStack => "Eval Stack",
            Self::CallStack => "Call Stack",
            Self::Globals => "Globals",
            Self::Heap => "Heap",
        }
    }

    const ALL: [HexRegion; 5] = [
        Self::Code,
        Self::EvalStack,
        Self::CallStack,
        Self::Globals,
        Self::Heap,
    ];
}

/// Snapshot of the p-code VM's semantic state (read from emulator memory).
#[derive(Clone)]
struct PcodeState {
    pc: u32,
    esp: u32,
    csp: u32,
    fp_vm: u32,
    gp: u32,
    hp: u32,
    code_base: u32,
    status: u32,
    trap_code: u32,
}

/// Messages driving the debugger state machine.
pub enum Msg {
    /// Load VM assembly and initialize the emulator.
    Init,
    /// Run a batch of instructions.
    Tick,
    /// Reset emulator to initial state.
    Reset,
    /// Step one p-code instruction (run COR24 until VM pc changes).
    StepPcode,
    /// Step over: run until call depth returns to current level.
    StepOver,
    /// Step out: run until call depth decreases by one.
    StepOut,
    /// Step one COR24 host instruction.
    StepHost,
    /// Toggle run/pause.
    PauseResume,
    /// Toggle COR24 drill-down panel visibility.
    ToggleHost,
    /// Select memory region in hex viewer.
    SelectHexRegion(String),
    /// Toggle hex viewer panel visibility.
    ToggleHexViewer,
    /// Load a demo program by index.
    LoadDemo(usize),
    /// Send UART input text.
    SendInput,
    /// Update UART input field value.
    InputChanged(String),
    /// Handle keydown in UART input field.
    InputKeyDown(KeyboardEvent),
    /// Toggle a p-code breakpoint at the given code offset.
    ToggleBreakpoint(u32),
    /// Clear all p-code breakpoints.
    ClearBreakpoints,
}

/// Return the size in bytes of a p-code instruction given its opcode byte.
/// Delegates to pa24r so the table cannot drift out of sync with the
/// canonical p-code encoding.
fn pcode_instr_size(op: u8) -> u32 {
    pa24r::opcode_size(op) as u32
}

pub struct Debugger {
    emulator: EmulatorCore,
    output: String,
    running: bool,
    halted: bool,
    _tick_handle: Option<Timeout>,
    prev_regs: [u32; 8],
    prev_pc: u32,
    reverse_labels: HashMap<u32, String>,
    program_end: u32,
    /// Address of vm_state struct in emulator memory.
    vm_state_addr: u32,
    /// Address of eval_stack base.
    eval_stack_base: u32,
    /// Address of call_stack base.
    call_stack_base: u32,
    /// Address of code_seg.
    code_seg_addr: u32,
    /// Address of vm_loop (top of fetch-decode-execute cycle).
    vm_loop_addr: u32,
    /// Previous p-code PC for change detection.
    prev_pcode_pc: u32,
    /// Previous eval stack for change highlighting.
    prev_eval_stack: Vec<u32>,
    /// Previous VM state for change highlighting.
    prev_pcode_state: Option<PcodeState>,
    /// Total COR24 instructions executed.
    instruction_count: u64,
    /// Show COR24 host drill-down panel.
    show_host: bool,
    /// Show hex memory viewer panel.
    show_hex_viewer: bool,
    /// Currently selected memory region for hex viewer.
    hex_region: HexRegion,
    /// Currently selected demo index.
    selected_demo: Option<usize>,
    /// Pending code_base address to patch after pvm.s init.
    pending_code_base: Option<u32>,
    /// UART input field text.
    input: String,
    /// UART receive queue (bytes waiting to be fed to emulator).
    uart_rx_queue: VecDeque<u8>,
    /// P-code breakpoints (set of p-code code-segment offsets).
    breakpoints: HashSet<u32>,
    /// Byte size of the currently loaded demo's p-code segment (0 if none).
    demo_code_size: u32,
    /// Absolute address where the demo's globals region starts (0 if none).
    demo_globals_base: u32,
    /// Size in bytes of the demo's globals region (0 if none).
    demo_globals_size: u32,
}

impl Debugger {
    /// Load the pre-assembled pvm.s binary into the emulator.
    /// Called once on Init. No COR24 assembler runs in WASM.
    fn load_vm_binary(&mut self) {
        let binary = config::PVM_BINARY;

        // Resolve key VM addresses from build-time labels.
        self.vm_state_addr = config::label_addr("vm_state");
        self.eval_stack_base = config::label_addr("eval_stack");
        self.call_stack_base = config::label_addr("call_stack");
        self.code_seg_addr = config::label_addr("code_seg");
        self.vm_loop_addr = config::label_addr("vm_loop");
        self.program_end = binary.len() as u32;

        self.emulator.hard_reset();
        self.emulator.set_uart_tx_busy_cycles(0);
        self.emulator.load_program(0, binary);
        self.emulator.load_program_extent(binary.len() as u32);
        self.emulator.set_pc(0);
        self.output.clear();
        self.halted = false;
        self.prev_regs = [0; 8];
        self.prev_pc = 0;
        self.prev_pcode_pc = 0;
        self.prev_eval_stack.clear();
        self.prev_pcode_state = None;
        self.instruction_count = 0;

        self.pending_code_base = None;
        self.demo_code_size = 0;
        self.demo_globals_base = 0;
        self.demo_globals_size = 0;
        // Start paused — debugger mode.
        self.running = false;
        self.emulator.pause();
    }

    fn schedule_tick(&mut self, ctx: &Context<Self>) {
        let link = ctx.link().clone();
        self._tick_handle = Some(Timeout::new(TICK_MS, move || {
            link.send_message(Msg::Tick);
        }));
    }

    /// How many code bytes to treat as valid p-code for disassembly /
    /// memory-map purposes. Prefers the explicit demo code size (when a
    /// .p24 is loaded at 0x010000 above pvm.s); falls back to the
    /// distance from code_base to the eval stack (works for the
    /// built-in pvm.s code_seg default).
    fn code_limit(&self, pstate: &PcodeState) -> u32 {
        if self.demo_code_size > 0 {
            self.demo_code_size
        } else {
            self.eval_stack_base.saturating_sub(pstate.code_base)
        }
    }

    /// Read the p-code VM state struct from emulator memory.
    fn read_pcode_state(&self) -> PcodeState {
        let base = self.vm_state_addr;
        PcodeState {
            pc: self.emulator.read_word(base + vm_offsets::PC),
            esp: self.emulator.read_word(base + vm_offsets::ESP),
            csp: self.emulator.read_word(base + vm_offsets::CSP),
            fp_vm: self.emulator.read_word(base + vm_offsets::FP_VM),
            gp: self.emulator.read_word(base + vm_offsets::GP),
            hp: self.emulator.read_word(base + vm_offsets::HP),
            code_base: self.emulator.read_word(base + vm_offsets::CODE),
            status: self.emulator.read_word(base + vm_offsets::STATUS),
            trap_code: self.emulator.read_word(base + vm_offsets::TRAP_CODE),
        }
    }

    /// Decode a p-code instruction at the given offset within code_seg.
    fn decode_pcode_at(&self, code_base: u32, offset: u32) -> PcodeInstr {
        let addr = code_base + offset;
        let opcode = self.emulator.read_byte(addr);
        let (name, operand, size) = Self::decode_pcode_opcode(opcode, addr, &self.emulator);
        PcodeInstr {
            addr: offset,
            name,
            operand,
            size,
        }
    }

    fn decode_pcode_opcode(
        opcode: u8,
        addr: u32,
        emu: &EmulatorCore,
    ) -> (&'static str, Option<u32>, u32) {
        let name = PCODE_NAMES
            .iter()
            .find(|(op, _)| *op == opcode)
            .map(|(_, n)| *n)
            .unwrap_or("???");

        let size = pa24r::opcode_size(opcode) as u32;
        let operand = match opcode {
            // IMM24 (4 bytes): push, jmp, jz, jnz, call, loadg, storeg, addrg
            0x01 | 0x30 | 0x31 | 0x32 | 0x33 | 0x44 | 0x45 | 0x47 => {
                Some(emu.read_word(addr + 1) & 0xFFFFFF)
            }
            // IMM8 (2 bytes): push_s, ret, trap, enter, loadl, storel,
            //                 addrl, loada, storea, sys
            0x02 | 0x34 | 0x36 | 0x40 | 0x42 | 0x43 | 0x46 | 0x48 | 0x49 | 0x60 => {
                Some(emu.read_byte(addr + 1) as u32)
            }
            // IMM16 (3 bytes): xcall
            0x74 => Some(emu.read_byte(addr + 1) as u32 | ((emu.read_byte(addr + 2) as u32) << 8)),
            // D8_O8 (3 bytes): loadn, storen, xloadg, xstoreg
            // Show depth.offset as a packed display (e.g. "01.02")
            0x4A | 0x4B | 0x75 | 0x76 => {
                let d = emu.read_byte(addr + 1) as u32;
                let o = emu.read_byte(addr + 2) as u32;
                Some((d << 8) | o)
            }
            // D8_A24 (5 bytes): calln
            0x35 => {
                let d = emu.read_byte(addr + 1) as u32;
                let a = emu.read_word(addr + 2) & 0xFFFFFF;
                Some((d << 24) | a)
            }
            // NONE (1 byte): all other opcodes have no operand
            _ => None,
        };
        (name, operand, size)
    }

    /// Disassemble p-code instructions around the current p-code PC.
    fn disassemble_pcode(&self, pstate: &PcodeState, count: usize) -> Vec<PcodeInstr> {
        let mut instrs = Vec::new();
        let mut offset = 0u32;
        let code_limit = self.code_limit(pstate);

        // Scan from start of code segment to build instruction list.
        // This handles variable-length instructions correctly.
        while offset < code_limit && instrs.len() < 256 {
            let instr = self.decode_pcode_at(pstate.code_base, offset);
            offset += instr.size;
            instrs.push(instr);
        }

        // Find index of current PC instruction.
        let current_idx = instrs.iter().position(|i| i.addr == pstate.pc).unwrap_or(0);

        // Window around current PC — show generous context so users can
        // see surrounding structure (labels, loop bodies, etc.).
        let before = 10;
        let start = current_idx.saturating_sub(before);
        let end = (current_idx + count).min(instrs.len());
        instrs.into_iter().skip(start).take(end - start).collect()
    }

    /// Read eval stack entries (each 3 bytes / 1 word).
    fn read_eval_stack(&self, pstate: &PcodeState) -> Vec<u32> {
        let mut stack = Vec::new();
        let mut addr = self.eval_stack_base;
        while addr < pstate.esp {
            stack.push(self.emulator.read_word(addr));
            addr += 3;
        }
        stack
    }

    /// Disassemble COR24 instructions around current host PC.
    fn disassemble_host(&self) -> Vec<(u32, String, bool)> {
        let pc = self.emulator.snapshot().pc;
        let forward = self.emulator.disassemble(pc, DISASM_AFTER + 1);

        let mut before = Vec::new();
        if DISASM_BEFORE > 0 && pc > 0 {
            let scan_start = pc.saturating_sub((DISASM_BEFORE as u32) * 4 + 8);
            let all = self.emulator.disassemble(scan_start, 128);
            for &(addr, ref mnemonic, _size) in &all {
                if addr < pc {
                    before.push((addr, mnemonic.clone()));
                } else {
                    break;
                }
            }
            let skip = before.len().saturating_sub(DISASM_BEFORE);
            before = before.into_iter().skip(skip).collect();
        }

        let mut result: Vec<(u32, String, bool)> = Vec::new();
        for (addr, mnemonic) in before {
            result.push((addr, mnemonic, false));
        }
        for (addr, mnemonic, _size) in forward {
            result.push((addr, mnemonic, addr == pc));
        }
        result
    }

    /// Read call frames by walking the dynamic link chain from fp_vm.
    /// Each frame header is 12 bytes: return_pc(3), dynamic_link(3), static_link(3), saved_esp(3).
    /// fp_vm points to first local; frame header is at fp_vm - 12.
    fn read_call_frames(&self, pstate: &PcodeState) -> Vec<CallFrame> {
        let mut frames = Vec::new();
        let mut fp = pstate.fp_vm;
        while fp >= self.call_stack_base + 12 {
            let header = fp - 12;
            if header < self.call_stack_base {
                break;
            }
            frames.push(CallFrame {
                return_pc: self.emulator.read_word(header),
                dynamic_link: self.emulator.read_word(header + 3),
                static_link: self.emulator.read_word(header + 6),
                saved_esp: self.emulator.read_word(header + 9),
            });
            let prev_fp = self.emulator.read_word(header + 3);
            if prev_fp == 0 || prev_fp >= fp {
                break; // End of chain or invalid link.
            }
            fp = prev_fp;
        }
        frames.reverse(); // Oldest frame first.
        frames
    }

    /// Compute memory regions for the visualization bar.
    fn memory_regions(&self, pstate: &PcodeState) -> Vec<MemRegion> {
        if pstate.code_base == 0 {
            return Vec::new();
        }
        let code_size = self.code_limit(pstate);
        let eval_used = pstate.esp.saturating_sub(self.eval_stack_base);
        let eval_cap = self.call_stack_base.saturating_sub(self.eval_stack_base);
        let call_used = pstate.csp.saturating_sub(self.call_stack_base);
        // Globals and heap are after call stack in the memory map.
        let globals_size = if self.demo_globals_size > 0 {
            self.demo_globals_size
        } else if pstate.gp > 0 {
            24 // pvm.s default 8-word pool
        } else {
            0
        };
        let heap_used = pstate.hp.saturating_sub(pstate.gp);

        vec![
            MemRegion {
                name: "Code",
                css_class: "region-code",
                start: pstate.code_base,
                size: code_size,
            },
            MemRegion {
                name: "EStack",
                css_class: "region-estack",
                start: self.eval_stack_base,
                size: eval_used.max(eval_cap),
            },
            MemRegion {
                name: "CStack",
                css_class: "region-cstack",
                start: self.call_stack_base,
                size: call_used.max(1),
            },
            MemRegion {
                name: "Globals",
                css_class: "region-globals",
                start: pstate.gp,
                size: globals_size,
            },
            MemRegion {
                name: "Heap",
                css_class: "region-heap",
                start: pstate.hp.saturating_sub(heap_used),
                size: heap_used.max(1),
            },
        ]
    }

    /// Get the address range for a hex region.
    fn hex_region_range(&self, region: HexRegion, pstate: &PcodeState) -> (u32, u32) {
        match region {
            HexRegion::Code => {
                let start = pstate.code_base;
                let end = start + self.code_limit(pstate);
                (start, end)
            }
            HexRegion::EvalStack => {
                let start = self.eval_stack_base;
                let end = pstate.esp;
                (start, end)
            }
            HexRegion::CallStack => {
                let start = self.call_stack_base;
                let end = pstate.csp;
                (start, end)
            }
            HexRegion::Globals => {
                let start = pstate.gp;
                let size = if self.demo_globals_size > 0 {
                    self.demo_globals_size
                } else {
                    24 // pvm.s default 8-word pool
                };
                (start, start + size)
            }
            HexRegion::Heap => {
                let start = pstate.gp;
                let end = pstate.hp;
                (start, end)
            }
        }
    }

    /// Check if an address should be highlighted in the hex viewer.
    fn hex_highlight_addr(&self, addr: u32, region: HexRegion, pstate: &PcodeState) -> bool {
        match region {
            HexRegion::Code => {
                let abs_pc = pstate.code_base + pstate.pc;
                addr >= abs_pc && addr < abs_pc + 4 // max instruction size
            }
            HexRegion::EvalStack => {
                // Highlight top of stack (last 3 bytes)
                pstate.esp > 3 && addr >= pstate.esp - 3 && addr < pstate.esp
            }
            HexRegion::CallStack => {
                // Highlight current frame pointer area
                pstate.fp_vm >= 12 && addr >= pstate.fp_vm - 12 && addr < pstate.fp_vm
            }
            HexRegion::Globals | HexRegion::Heap => false,
        }
    }

    /// Count current call depth (number of frames).
    fn call_depth(&self, pstate: &PcodeState) -> usize {
        self.read_call_frames(pstate).len()
    }

    /// Step one full p-code fetch-decode-execute cycle.
    /// Returns true if the p-code boundary was reached, false if the emulator
    /// halted, the VM trapped, or the inner COR24 budget was exhausted.
    fn step_one_pcode(&mut self) -> bool {
        let mut i = 0u32;
        loop {
            let result = self.emulator.step();
            self.instruction_count += result.instructions_run;
            i += 1;
            if matches!(result.reason, StopReason::Halted) {
                self.halted = true;
                self.running = false;
                return false;
            }
            if self.read_pcode_state().status != 0 {
                return false;
            }
            if i > 1 && self.emulator.snapshot().pc == self.vm_loop_addr {
                return true;
            }
            if i >= 50_000 {
                return false;
            }
        }
    }

    /// Run p-code instructions until a depth condition is met.
    /// Returns when depth_check(current_depth) is true or on halt/timeout.
    fn run_until_depth<F>(&mut self, depth_check: F)
    where
        F: Fn(usize) -> bool,
    {
        for _ in 0..500_000u32 {
            if !self.step_one_pcode() {
                self.collect_uart();
                return;
            }
            self.collect_uart();
            let pstate = self.read_pcode_state();
            let depth = self.call_depth(&pstate);
            if depth_check(depth) {
                return;
            }
        }
    }

    fn view_vm_state_table(&self, pstate: &PcodeState) -> Html {
        let prev = self.prev_pcode_state.as_ref();
        let changed = |cur: u32, get_prev: fn(&PcodeState) -> u32| -> &str {
            match prev {
                Some(p) if get_prev(p) != cur => "changed",
                _ => "",
            }
        };

        html! {
            <table class="state-table">
                <tr class={changed(pstate.pc, |p| p.pc)}>
                    <td class="state-name">{"PC"}</td>
                    <td class="state-val">{ format!("{:04X}", pstate.pc) }</td>
                </tr>
                <tr class={changed(pstate.esp, |p| p.esp)}>
                    <td class="state-name">{"ESP"}</td>
                    <td class="state-val">{ format!("{:06X}", pstate.esp) }</td>
                </tr>
                <tr class={changed(pstate.csp, |p| p.csp)}>
                    <td class="state-name">{"CSP"}</td>
                    <td class="state-val">{ format!("{:06X}", pstate.csp) }</td>
                </tr>
                <tr class={changed(pstate.fp_vm, |p| p.fp_vm)}>
                    <td class="state-name">{"FP"}</td>
                    <td class="state-val">{ format!("{:06X}", pstate.fp_vm) }</td>
                </tr>
                <tr class={changed(pstate.gp, |p| p.gp)}>
                    <td class="state-name">{"GP"}</td>
                    <td class="state-val">{ format!("{:06X}", pstate.gp) }</td>
                </tr>
                <tr class={changed(pstate.hp, |p| p.hp)}>
                    <td class="state-name">{"HP"}</td>
                    <td class="state-val">{ format!("{:06X}", pstate.hp) }</td>
                </tr>
                { if pstate.status == 2 {
                    html! {
                        <tr class="trap">
                            <td class="state-name">{"TRAP"}</td>
                            <td class="state-val">{ format!("{}", pstate.trap_code) }</td>
                        </tr>
                    }
                } else {
                    html! {}
                }}
            </table>
        }
    }

    fn collect_uart(&mut self) {
        let uart = self.emulator.get_uart_output();
        if !uart.is_empty() {
            self.output.push_str(uart);
            self.emulator.clear_uart_output();
        }
    }

    /// Feed one byte from the UART RX queue if the UART is ready.
    /// Feed as many bytes as possible from the UART RX queue while the
    /// UART is ready to accept them.  Draining per tick avoids wasting
    /// millions of emulated instructions polling in tight UART-wait loops.
    fn feed_uart_bytes(&mut self) {
        while !self.uart_rx_queue.is_empty() {
            let status = self.emulator.read_byte(0xFF0101);
            if status & 0x01 != 0 {
                break; // RX buffer full, try again next tick
            }
            if let Some(byte) = self.uart_rx_queue.pop_front() {
                self.emulator.send_uart_byte(byte);
            }
        }
    }

    /// Load a pre-assembled p-code image into emulator memory.
    /// Places code + data + zero-init globals at a safe address
    /// (0x010000), then relocates `push` operands that reference data
    /// or globals to absolute addresses (pvm.s loadb/load/store use
    /// absolute addresses, not code-relative).
    fn load_p24_image(&mut self, image: &pa24r::LoadedImage) {
        let load_addr = 0x010000_u32;
        let code_size = image.code.len() as u32;
        let data_size = image.data.len() as u32;
        let global_bytes = image.global_count * 3;
        let code_data_end = code_size + data_size;
        let image_end = code_data_end + global_bytes;
        self.demo_code_size = code_size;
        self.demo_globals_base = load_addr + code_data_end;
        self.demo_globals_size = global_bytes;

        // Write code + data contiguously. Globals are zero-initialized;
        // the emulator memory at load_addr + code_data_end is already
        // zero after hard_reset (load_vm_binary runs it before we land
        // here), so we only need to write code/data bytes.
        for (i, &b) in image.code.iter().chain(image.data.iter()).enumerate() {
            self.emulator.write_byte(load_addr + i as u32, b);
        }
        // Explicitly zero the globals region in case memory is dirty
        // (e.g. previous demo left values there).
        for i in 0..global_bytes {
            self.emulator.write_byte(load_addr + code_data_end + i, 0);
        }

        // Relocate: scan for `push` (opcode 0x01, IMM24) instructions
        // whose operand points into the data or globals segment. These
        // need to become absolute addresses (load_addr + offset).
        let mut i: u32 = 0;
        while i < code_size {
            let op = self.emulator.read_byte(load_addr + i);
            let size = pcode_instr_size(op);
            if op == 0x01 && i + 4 <= code_size {
                let lo = self.emulator.read_byte(load_addr + i + 1) as u32;
                let mid = self.emulator.read_byte(load_addr + i + 2) as u32;
                let hi = self.emulator.read_byte(load_addr + i + 3) as u32;
                let val = lo | (mid << 8) | (hi << 16);
                if val >= code_size && val < image_end {
                    let abs = val + load_addr;
                    self.emulator.write_byte(load_addr + i + 1, abs as u8);
                    self.emulator
                        .write_byte(load_addr + i + 2, (abs >> 8) as u8);
                    self.emulator
                        .write_byte(load_addr + i + 3, (abs >> 16) as u8);
                }
            }
            i += size;
        }
        self.pending_code_base = Some(load_addr);
    }

    /// If a demo was loaded, run pvm.s init then set up the VM to
    /// execute the demo's p-code from the load address.
    fn apply_pending_code_base(&mut self) {
        if let Some(load_addr) = self.pending_code_base.take() {
            // Write "sys halt" at code_seg so pvm.s init halts after boot
            let code_seg = self.code_seg_addr;
            self.emulator.write_byte(code_seg, 0x60); // sys
            self.emulator.write_byte(code_seg + 1, 0x00); // halt

            // Run pvm.s init — boots, enters vm_loop, hits sys halt
            self.emulator.resume();
            self.emulator.run_batch(10_000);

            // Discard boot output (PVM banner)
            self.emulator.clear_uart_output();
            self.output.clear();

            // Soft reset: clears halted flag, preserves all memory
            self.emulator.reset();
            self.emulator.set_uart_tx_busy_cycles(0);

            // Set COR24 PC to vm_loop (skip init), fp to vm_state
            self.emulator.set_pc(self.vm_loop_addr);
            self.emulator.set_reg(3, self.vm_state_addr); // fp

            // Patch vm_state for our demo
            let base = self.vm_state_addr;
            // code_base = load_addr
            self.emulator.write_byte(base + 18, load_addr as u8);
            self.emulator.write_byte(base + 19, (load_addr >> 8) as u8);
            self.emulator.write_byte(base + 20, (load_addr >> 16) as u8);
            // pc = 0
            self.emulator.write_byte(base, 0);
            self.emulator.write_byte(base + 1, 0);
            self.emulator.write_byte(base + 2, 0);
            // status = 0 (running)
            self.emulator.write_byte(base + 21, 0);
            self.emulator.write_byte(base + 22, 0);
            self.emulator.write_byte(base + 23, 0);
            // gp = demo globals base (so loadg/storeg hit the demo's
            // globals region, not pvm.s's built-in globals_seg)
            if self.demo_globals_size > 0 {
                let gp = self.demo_globals_base;
                self.emulator.write_byte(base + 12, gp as u8);
                self.emulator.write_byte(base + 13, (gp >> 8) as u8);
                self.emulator.write_byte(base + 14, (gp >> 16) as u8);
            }
        }
    }

    fn save_prev_state(&mut self) {
        let snap = self.emulator.snapshot();
        self.prev_regs = snap.regs;
        self.prev_pc = snap.pc;
        let pstate = self.read_pcode_state();
        self.prev_pcode_pc = pstate.pc;
        self.prev_eval_stack = self.read_eval_stack(&pstate);
        self.prev_pcode_state = Some(pstate);
    }

    fn check_halted(&mut self, reason: StopReason) {
        if matches!(reason, StopReason::Halted) {
            self.halted = true;
            self.running = false;
        }
    }
}

impl Component for Debugger {
    type Message = Msg;
    type Properties = ();

    fn create(ctx: &Context<Self>) -> Self {
        ctx.link().send_message(Msg::Init);
        let mut emulator = EmulatorCore::new();
        emulator.set_uart_tx_busy_cycles(0);
        Self {
            emulator,
            output: String::new(),
            running: false,
            halted: false,
            _tick_handle: None,
            prev_regs: [0; 8],
            prev_pc: 0,
            reverse_labels: HashMap::new(),
            program_end: 0,
            vm_state_addr: 0,
            eval_stack_base: 0,
            call_stack_base: 0,
            code_seg_addr: 0,
            vm_loop_addr: 0,
            prev_pcode_pc: 0,
            prev_eval_stack: Vec::new(),
            prev_pcode_state: None,
            instruction_count: 0,
            show_host: false,
            show_hex_viewer: false,
            hex_region: HexRegion::Code,
            selected_demo: None,
            pending_code_base: None,
            input: String::new(),
            uart_rx_queue: VecDeque::new(),
            breakpoints: HashSet::new(),
            demo_code_size: 0,
            demo_globals_base: 0,
            demo_globals_size: 0,
        }
    }

    fn update(&mut self, ctx: &Context<Self>, msg: Self::Message) -> bool {
        match msg {
            Msg::Init => {
                self.load_vm_binary();
                true
            }
            Msg::Tick => {
                if !self.running || self.halted {
                    return false;
                }

                self.feed_uart_bytes();
                self.save_prev_state();

                let pstate = self.read_pcode_state();
                if pstate.code_base == 0 {
                    // VM still booting — honor batch, no p-code breakpoints
                    // apply yet.
                    let result = self.emulator.run_batch(BATCH_SIZE);
                    self.instruction_count += result.instructions_run;
                    self.collect_uart();
                    self.check_halted(result.reason);
                } else if self.breakpoints.is_empty() {
                    // Fast path: no breakpoints set, use run_batch directly.
                    let result = self.emulator.run_batch(BATCH_SIZE);
                    self.instruction_count += result.instructions_run;
                    self.collect_uart();
                    self.check_halted(result.reason);
                } else {
                    // Breakpoints active: step at p-code granularity and
                    // check after each instruction. Cap per-tick work so
                    // the browser stays responsive.
                    const PCODE_PER_TICK: u32 = 2_000;
                    for _ in 0..PCODE_PER_TICK {
                        if !self.step_one_pcode() {
                            break;
                        }
                        let pc = self.read_pcode_state().pc;
                        if self.breakpoints.contains(&pc) {
                            self.running = false;
                            self._tick_handle = None;
                            break;
                        }
                    }
                    self.collect_uart();
                    self.feed_uart_bytes();
                }

                if self.running && !self.halted {
                    self.schedule_tick(ctx);
                }
                true
            }
            Msg::Reset => {
                self.running = false;
                self._tick_handle = None;
                self.uart_rx_queue.clear();
                self.selected_demo = None;
                self.load_vm_binary();
                true
            }
            Msg::StepPcode => {
                if self.halted {
                    return false;
                }
                self.apply_pending_code_base();
                self.save_prev_state();
                let pstate = self.read_pcode_state();

                if pstate.code_base == 0 {
                    // VM not yet initialized — run COR24 init until host PC
                    // reaches vm_loop (the top of the fetch-decode cycle).
                    for _ in 0..100_000u32 {
                        let result = self.emulator.step();
                        self.instruction_count += result.instructions_run;
                        self.collect_uart();
                        if matches!(result.reason, StopReason::Halted) {
                            self.halted = true;
                            self.running = false;
                            break;
                        }
                        if self.vm_loop_addr != 0
                            && self.emulator.snapshot().pc == self.vm_loop_addr
                        {
                            break;
                        }
                    }
                } else {
                    self.step_one_pcode();
                    self.collect_uart();
                }
                true
            }
            Msg::StepHost => {
                if self.halted {
                    return false;
                }
                self.save_prev_state();
                let result = self.emulator.step();
                self.instruction_count += result.instructions_run;
                self.collect_uart();
                self.check_halted(result.reason);
                true
            }
            Msg::PauseResume => {
                if self.halted {
                    return false;
                }
                self.running = !self.running;
                if self.running {
                    self.apply_pending_code_base();
                    self.emulator.resume();
                    self.schedule_tick(ctx);
                } else {
                    self.emulator.pause();
                    self._tick_handle = None;
                }
                true
            }
            Msg::StepOver => {
                if self.halted {
                    return false;
                }
                self.apply_pending_code_base();
                self.save_prev_state();
                let pstate = self.read_pcode_state();
                if pstate.code_base == 0 {
                    // Not initialized yet — just do a regular step.
                    ctx.link().send_message(Msg::StepPcode);
                    return false;
                }
                let target_depth = self.call_depth(&pstate);
                // First, step one p-code instruction.
                if !self.step_one_pcode() {
                    self.collect_uart();
                    return true;
                }
                self.collect_uart();
                // If we entered a call, keep running until depth <= target.
                let new_depth = self.call_depth(&self.read_pcode_state());
                if new_depth > target_depth {
                    self.run_until_depth(|d| d <= target_depth);
                }
                true
            }
            Msg::StepOut => {
                if self.halted {
                    return false;
                }
                self.apply_pending_code_base();
                self.save_prev_state();
                let pstate = self.read_pcode_state();
                if pstate.code_base == 0 {
                    return false;
                }
                let current_depth = self.call_depth(&pstate);
                if current_depth == 0 {
                    return false;
                }
                let target_depth = current_depth - 1;
                self.run_until_depth(|d| d <= target_depth);
                true
            }
            Msg::ToggleHost => {
                self.show_host = !self.show_host;
                true
            }
            Msg::SelectHexRegion(val) => {
                self.hex_region = match val.as_str() {
                    "code" => HexRegion::Code,
                    "estack" => HexRegion::EvalStack,
                    "cstack" => HexRegion::CallStack,
                    "globals" => HexRegion::Globals,
                    "heap" => HexRegion::Heap,
                    _ => HexRegion::Code,
                };
                true
            }
            Msg::ToggleHexViewer => {
                self.show_hex_viewer = !self.show_hex_viewer;
                true
            }
            Msg::LoadDemo(index) => {
                if let Some(demo) = DEMOS.get(index) {
                    self.selected_demo = Some(index);
                    self.running = false;
                    self._tick_handle = None;
                    self.uart_rx_queue.clear();
                    self.breakpoints.clear();
                    // Soft reset: preserves pvm.s code in memory
                    self.load_vm_binary();
                    // Load pre-assembled .p24 binary into code_seg
                    match pa24r::load_p24(demo.p24) {
                        Ok(image) => {
                            self.load_p24_image(&image);
                            // Boot pvm.s init right away so the P-Code
                            // Disassembly panel populates before the user
                            // takes their first step.
                            self.apply_pending_code_base();
                            // Stay paused — user clicks Run to start
                        }
                        Err(e) => {
                            self.output = format!("Load error: {e}");
                        }
                    }
                }
                true
            }
            Msg::SendInput => {
                let text = std::mem::take(&mut self.input);
                for b in text.bytes() {
                    self.uart_rx_queue.push_back(b);
                }
                self.uart_rx_queue.push_back(b'\n');
                true
            }
            Msg::InputChanged(val) => {
                self.input = val;
                false
            }
            Msg::InputKeyDown(e) => {
                if e.key() == "Enter" {
                    ctx.link().send_message(Msg::SendInput);
                }
                false
            }
            Msg::ToggleBreakpoint(addr) => {
                if !self.breakpoints.insert(addr) {
                    self.breakpoints.remove(&addr);
                }
                true
            }
            Msg::ClearBreakpoints => {
                let changed = !self.breakpoints.is_empty();
                self.breakpoints.clear();
                changed
            }
        }
    }

    fn view(&self, ctx: &Context<Self>) -> Html {
        let link = ctx.link();
        let snap = self.emulator.snapshot();
        let pstate = self.read_pcode_state();
        let vm_initialized = pstate.code_base != 0;
        let pcode_instrs = if vm_initialized {
            self.disassemble_pcode(&pstate, 12)
        } else {
            Vec::new()
        };
        let eval_stack = if vm_initialized {
            self.read_eval_stack(&pstate)
        } else {
            Vec::new()
        };
        let call_frames = if vm_initialized {
            self.read_call_frames(&pstate)
        } else {
            Vec::new()
        };
        let regions = self.memory_regions(&pstate);

        let vm_status = if !vm_initialized {
            "INIT"
        } else {
            match pstate.status {
                0 => "RUNNING",
                1 => "HALTED",
                2 => "TRAPPED",
                _ => "???",
            }
        };

        html! {
            <div class="debugger">
                // Control bar
                <div class="control-bar">
                    <button onclick={link.callback(|_| Msg::Reset)}
                            class="btn btn-reset">{"Reset"}</button>
                    <select class="demo-select" onchange={link.callback(|e: Event| {
                        let target: web_sys::HtmlSelectElement = e.target_unchecked_into();
                        let idx: usize = target.value().parse().unwrap_or(0);
                        Msg::LoadDemo(idx)
                    })}>
                        <option value="" selected={self.selected_demo.is_none()}>
                            {"Demo\u{2026}"}
                        </option>
                        { for DEMOS.iter().enumerate().map(|(i, demo)| {
                            let sel = self.selected_demo == Some(i);
                            html! {
                                <option value={i.to_string()} selected={sel}
                                        title={demo.description}>
                                    { &demo.name }
                                </option>
                            }
                        })}
                    </select>
                    <button onclick={link.callback(|_| Msg::StepPcode)}
                            class="btn btn-step"
                            disabled={self.halted}>{"Step P-Code"}</button>
                    <button onclick={link.callback(|_| Msg::StepOver)}
                            class="btn btn-step"
                            disabled={self.halted}>{"Step Over"}</button>
                    <button onclick={link.callback(|_| Msg::StepOut)}
                            class="btn btn-step"
                            disabled={self.halted}>{"Step Out"}</button>
                    <button onclick={link.callback(|_| Msg::StepHost)}
                            class="btn btn-step-host"
                            disabled={self.halted}>{"Step Host"}</button>
                    <button onclick={link.callback(|_| Msg::PauseResume)}
                            class="btn btn-run"
                            disabled={self.halted}>
                        { if self.running { "Pause" } else { "Run" } }
                    </button>
                    <button onclick={link.callback(|_| Msg::ClearBreakpoints)}
                            class="btn btn-toggle"
                            disabled={self.breakpoints.is_empty()}
                            title="Clear all p-code breakpoints">
                        { format!("Clear BPs ({})", self.breakpoints.len()) }
                    </button>
                    <button onclick={link.callback(|_| Msg::ToggleHexViewer)}
                            class={if self.show_hex_viewer { "btn btn-toggle active" } else { "btn btn-toggle" }}>
                        {"Memory"}
                    </button>
                    <button onclick={link.callback(|_| Msg::ToggleHost)}
                            class={if self.show_host { "btn btn-toggle active" } else { "btn btn-toggle" }}>
                        {"COR24"}
                    </button>
                    <span class="status">{ vm_status }</span>
                    <span class="pc-display">
                        { format!("P-Code PC: {:04X}", pstate.pc) }
                    </span>
                    <span class="pc-display host-pc">
                        { format!("Host PC: {:06X}", snap.pc) }
                    </span>
                    <span class="instr-count">
                        { format!("Instrs: {}", self.instruction_count) }
                    </span>
                </div>

                // Memory region map bar
                { if !regions.is_empty() {
                    let region_total: u32 = regions.iter().map(|r| r.size).sum::<u32>().max(1);
                    html! {
                        <div class="memory-map">
                            <span class="memory-map-label">{"Memory"}</span>
                            <div class="region-bar">
                                { for regions.iter().map(|r| {
                                    let pct = (r.size as f64 / region_total as f64 * 100.0).max(2.0);
                                    let style = format!("width: {}%", pct);
                                    html! {
                                        <div class={classes!("region", r.css_class)} style={style}
                                             title={format!("{}: {:06X}-{:06X} ({} bytes)", r.name, r.start, r.start + r.size, r.size)}>
                                            { if pct > 8.0 { r.name } else { "" } }
                                        </div>
                                    }
                                })}
                            </div>
                        </div>
                    }
                } else {
                    html! {}
                }}

                // Main panels area — 3-column layout
                <div class="panels">
                    // Left: P-code disassembly
                    <div class="panel panel-disasm">
                        <h3>{"P-Code Disassembly"}</h3>
                        { if !vm_initialized {
                            html! { <div class="disasm-init">{"Press Step P-Code to initialize VM"}</div> }
                        } else {
                            html! {}
                        }}
                        <div class="disasm-view">
                            { for pcode_instrs.iter().map(|instr| {
                                let is_current = instr.addr == pstate.pc;
                                let has_bp = self.breakpoints.contains(&instr.addr);
                                let line_class = match (is_current, has_bp) {
                                    (true, true)  => "disasm-line current has-bp",
                                    (true, false) => "disasm-line current",
                                    (false, true) => "disasm-line has-bp",
                                    _             => "disasm-line",
                                };
                                let operand_str = match instr.operand {
                                    Some(v) => format!(" {:06X}", v),
                                    None => String::new(),
                                };
                                let bp_addr = instr.addr;
                                let on_click = link.callback(move |_| Msg::ToggleBreakpoint(bp_addr));
                                let bp_glyph = if has_bp { "\u{25CF}" } else if is_current { "\u{25b6}" } else { " " };
                                html! {
                                    <div class={line_class} onclick={on_click}
                                         title="Click to toggle breakpoint">
                                        <span class="disasm-marker">
                                            { bp_glyph }
                                        </span>
                                        <span class="disasm-addr">
                                            { format!("{:04X}", instr.addr) }
                                        </span>
                                        <span class="disasm-opcode">
                                            { instr.name }
                                        </span>
                                        <span class="disasm-operand">
                                            { operand_str }
                                        </span>
                                    </div>
                                }
                            })}
                        </div>
                    </div>

                    // Center: VM state + eval stack + call frames + output
                    <div class="panel-center">
                        // VM state
                        <div class="panel panel-vm-state">
                            <h3>{"VM State"}</h3>
                            { self.view_vm_state_table(&pstate) }
                        </div>

                        // Eval stack with change highlighting
                        <div class="panel panel-eval-stack">
                            <h3>{ format!("Eval Stack ({})", eval_stack.len()) }</h3>
                            <div class="stack-view">
                                { if eval_stack.is_empty() {
                                    html! { <span class="empty">{"(empty)"}</span> }
                                } else {
                                    let prev = &self.prev_eval_stack;
                                    let prev_len = prev.len();
                                    let cur_len = eval_stack.len();
                                    html! {
                                        <table class="stack-table">
                                            { for eval_stack.iter().rev().enumerate().map(|(i, &val)| {
                                                let depth_from_bottom = cur_len - 1 - i;
                                                let changed = if depth_from_bottom >= prev_len {
                                                    true // new entry
                                                } else {
                                                    prev[depth_from_bottom] != val
                                                };
                                                let label = if i == 0 { "TOS" } else { "" };
                                                let row_class = if changed { "changed" } else { "" };
                                                html! {
                                                    <tr class={row_class}>
                                                        <td class="stack-label">{ label }</td>
                                                        <td class="stack-val">{ format!("{:06X}", val) }</td>
                                                        <td class="stack-dec">{ format!("{}", val as i32) }</td>
                                                    </tr>
                                                }
                                            })}
                                        </table>
                                    }
                                }}
                            </div>
                        </div>

                        // Call frames
                        <div class="panel panel-call-frames">
                            <h3>{ format!("Call Stack ({})", call_frames.len()) }</h3>
                            <div class="frames-view">
                                { if call_frames.is_empty() {
                                    html! { <span class="empty">{"(no frames)"}</span> }
                                } else {
                                    html! {
                                        <table class="frame-table">
                                            <tr class="frame-header">
                                                <td>{"#"}</td>
                                                <td>{"RetPC"}</td>
                                                <td>{"FP"}</td>
                                                <td>{"SLink"}</td>
                                                <td>{"ESP"}</td>
                                            </tr>
                                            { for call_frames.iter().rev().enumerate().map(|(i, f)| {
                                                let is_current = i == 0;
                                                let row_class = if is_current { "frame-current" } else { "" };
                                                html! {
                                                    <tr class={row_class}>
                                                        <td class="frame-idx">{ format!("{}", call_frames.len() - i - 1) }</td>
                                                        <td class="frame-val">{ format!("{:04X}", f.return_pc) }</td>
                                                        <td class="frame-val">{ format!("{:06X}", f.dynamic_link) }</td>
                                                        <td class="frame-val">{ format!("{:06X}", f.static_link) }</td>
                                                        <td class="frame-val">{ format!("{:06X}", f.saved_esp) }</td>
                                                    </tr>
                                                }
                                            })}
                                        </table>
                                    }
                                }}
                            </div>
                        </div>

                        // Output + UART input
                        <div class="panel panel-output">
                            <h3>{"Output"}</h3>
                            <pre class="output-text">{ &self.output }</pre>
                            <div class="uart-input">
                                <input
                                    type="text"
                                    class="uart-field"
                                    value={self.input.clone()}
                                    oninput={link.callback(|e: InputEvent| {
                                        let input: HtmlInputElement = e.target_unchecked_into();
                                        Msg::InputChanged(input.value())
                                    })}
                                    onkeydown={link.callback(Msg::InputKeyDown)}
                                    placeholder="UART input (Enter to send)"
                                />
                            </div>
                        </div>
                    </div>

                    // Hex memory viewer (collapsible)
                    { if self.show_hex_viewer && vm_initialized {
                        let hex_region = self.hex_region;
                        let (start, end) = self.hex_region_range(hex_region, &pstate);
                        let size = end.saturating_sub(start);
                        let max_bytes = 512u32.min(size);
                        html! {
                            <div class="panel panel-hex">
                                <div class="hex-header">
                                    <h3>{"Memory"}</h3>
                                    <select class="hex-select"
                                            onchange={link.callback(|e: Event| {
                                                let target: web_sys::HtmlSelectElement = e.target_unchecked_into();
                                                Msg::SelectHexRegion(target.value())
                                            })}>
                                        { for HexRegion::ALL.iter().map(|&r| {
                                            let val = match r {
                                                HexRegion::Code => "code",
                                                HexRegion::EvalStack => "estack",
                                                HexRegion::CallStack => "cstack",
                                                HexRegion::Globals => "globals",
                                                HexRegion::Heap => "heap",
                                            };
                                            html! {
                                                <option value={val} selected={r == hex_region}>
                                                    { r.label() }
                                                </option>
                                            }
                                        })}
                                    </select>
                                    <span class="hex-info">
                                        { format!("{:06X}-{:06X} ({} bytes)", start, end, size) }
                                    </span>
                                </div>
                                <div class="hex-dump">
                                    { if size == 0 {
                                        html! { <span class="empty">{"(empty)"}</span> }
                                    } else {
                                        html! {
                                            <table class="hex-table">
                                                <tr class="hex-header-row">
                                                    <td class="hex-addr">{"Addr"}</td>
                                                    { for (0..16u8).map(|i| {
                                                        html! { <td class="hex-col-hdr">{ format!("{:X}", i) }</td> }
                                                    })}
                                                    <td class="hex-ascii-hdr">{"ASCII"}</td>
                                                </tr>
                                                { for (0..max_bytes).step_by(16).map(|row_off| {
                                                    let row_addr = start + row_off;
                                                    let row_end = (row_addr + 16).min(start + max_bytes);
                                                    let count = (row_end - row_addr) as usize;
                                                    let mut bytes = Vec::with_capacity(count);
                                                    for i in 0..count as u32 {
                                                        bytes.push(self.emulator.read_byte(row_addr + i));
                                                    }
                                                    html! {
                                                        <tr>
                                                            <td class="hex-addr">{ format!("{:06X}", row_addr) }</td>
                                                            { for (0..16usize).map(|i| {
                                                                if i < count {
                                                                    let addr = row_addr + i as u32;
                                                                    let hl = self.hex_highlight_addr(addr, hex_region, &pstate);
                                                                    let cls = if hl { "hex-byte hex-hl" } else { "hex-byte" };
                                                                    html! { <td class={cls}>{ format!("{:02X}", bytes[i]) }</td> }
                                                                } else {
                                                                    html! { <td class="hex-byte hex-pad">{"  "}</td> }
                                                                }
                                                            })}
                                                            <td class="hex-ascii">
                                                                { bytes.iter().map(|&b| {
                                                                    if (0x20..=0x7E).contains(&b) {
                                                                        b as char
                                                                    } else {
                                                                        '.'
                                                                    }
                                                                }).collect::<String>() }
                                                            </td>
                                                        </tr>
                                                    }
                                                })}
                                            </table>
                                        }
                                    }}
                                </div>
                            </div>
                        }
                    } else {
                        html! {}
                    }}

                    // Right: COR24 host drill-down (collapsible)
                    { if self.show_host {
                        let host_disasm = self.disassemble_host();
                        html! {
                            <div class="panel panel-host">
                                <h3>{"COR24 Host"}</h3>
                                // Registers
                                <div class="host-regs">
                                    <table class="reg-table">
                                        <tr class={if snap.pc != self.prev_pc { "changed" } else { "" }}>
                                            <td class="reg-name">{"PC"}</td>
                                            <td class="reg-val">{ format!("{:06X}", snap.pc) }</td>
                                        </tr>
                                        { for HOST_REG_NAMES.iter().enumerate().map(|(i, name)| {
                                            let changed = snap.regs[i] != self.prev_regs[i];
                                            html! {
                                                <tr class={if changed { "changed" } else { "" }}>
                                                    <td class="reg-name">{ *name }</td>
                                                    <td class="reg-val">{ format!("{:06X}", snap.regs[i]) }</td>
                                                </tr>
                                            }
                                        })}
                                        <tr>
                                            <td class="reg-name">{"c"}</td>
                                            <td class="reg-val">{ if snap.c { "1" } else { "0" } }</td>
                                        </tr>
                                    </table>
                                </div>
                                // Host disassembly
                                <div class="host-disasm">
                                    { for host_disasm.iter().map(|(addr, mnemonic, is_current)| {
                                        let label = self.reverse_labels.get(addr);
                                        let line_class = if *is_current {
                                            "disasm-line current"
                                        } else {
                                            "disasm-line"
                                        };
                                        html! {
                                            <>
                                                { if let Some(lbl) = label {
                                                    html! {
                                                        <div class="disasm-label">
                                                            { format!("{}:", lbl) }
                                                        </div>
                                                    }
                                                } else {
                                                    html! {}
                                                }}
                                                <div class={line_class}>
                                                    <span class="disasm-marker">
                                                        { if *is_current { "\u{25b6}" } else { " " } }
                                                    </span>
                                                    <span class="disasm-addr">
                                                        { format!("{:06X}", addr) }
                                                    </span>
                                                    <span class="disasm-instr">
                                                        { mnemonic }
                                                    </span>
                                                </div>
                                            </>
                                        }
                                    })}
                                </div>
                            </div>
                        }
                    } else {
                        html! {}
                    }}
                </div>
            </div>
        }
    }
}
