//! P-code VM debugger component — two-level debugging with p-code semantic
//! layer (primary) and COR24 host implementation layer (secondary drill-down).

use crate::config::VmConfig;
use crate::demos::DEMOS;
use cor24_emulator::{Assembler, EmulatorCore, StopReason};
use gloo::timers::callback::Timeout;
use std::collections::{HashMap, VecDeque};
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

/// P-code opcode names indexed by opcode number.
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
}

pub struct Debugger {
    emulator: EmulatorCore,
    config: VmConfig,
    output: String,
    running: bool,
    halted: bool,
    _tick_handle: Option<Timeout>,
    prev_regs: [u32; 8],
    prev_pc: u32,
    labels: HashMap<String, u32>,
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
    /// UART input field text.
    input: String,
    /// UART receive queue (bytes waiting to be fed to emulator).
    uart_rx_queue: VecDeque<u8>,
}

impl Debugger {
    fn load_binary(&mut self) {
        let mut asm = Assembler::new();
        let result = asm.assemble(self.config.assembly());

        if !result.errors.is_empty() {
            self.output = "Assembly errors:\n".to_string();
            for e in &result.errors {
                self.output.push_str(e);
                self.output.push('\n');
            }
            return;
        }

        self.labels = result.labels.clone();
        self.reverse_labels = result
            .labels
            .iter()
            .map(|(name, &addr)| (addr, name.clone()))
            .collect();
        self.program_end = result.bytes.len() as u32;

        // Resolve key VM addresses from labels.
        self.vm_state_addr = result.labels.get("vm_state").copied().unwrap_or(0);
        self.eval_stack_base = result.labels.get("eval_stack").copied().unwrap_or(0);
        self.call_stack_base = result.labels.get("call_stack").copied().unwrap_or(0);
        self.code_seg_addr = result.labels.get("code_seg").copied().unwrap_or(0);
        self.vm_loop_addr = result.labels.get("vm_loop").copied().unwrap_or(0);

        self.emulator.hard_reset();
        self.emulator.set_uart_tx_busy_cycles(0);
        self.emulator.load_program(0, &result.bytes);
        self.emulator.load_program_extent(result.bytes.len() as u32);
        self.emulator.set_pc(0);
        self.output.clear();
        self.halted = false;
        self.prev_regs = [0; 8];
        self.prev_pc = 0;
        self.prev_pcode_pc = 0;
        self.prev_eval_stack.clear();
        self.prev_pcode_state = None;
        self.instruction_count = 0;

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

        match opcode {
            // 3-byte operand instructions (push, jmp, jz, jnz, call, calln)
            0x01 | 0x30 | 0x31 | 0x32 | 0x33 | 0x35 => {
                let operand = emu.read_word(addr + 1) & 0xFFFFFF;
                (name, Some(operand), 4)
            }
            // 1-byte operand instructions (push_s, trap, enter, loadl, storel, loadg, storeg,
            // addrl, addrg, loada, storea, loadn, storen, sys)
            0x02 | 0x36 | 0x40..=0x4B | 0x60 => {
                let operand = emu.read_byte(addr + 1) as u32;
                (name, Some(operand), 2)
            }
            // No operand
            _ => (name, None, 1),
        }
    }

    /// Disassemble p-code instructions around the current p-code PC.
    fn disassemble_pcode(&self, pstate: &PcodeState, count: usize) -> Vec<PcodeInstr> {
        let mut instrs = Vec::new();
        let mut offset = 0u32;
        let code_limit = self.eval_stack_base.saturating_sub(pstate.code_base);

        // Scan from start of code segment to build instruction list.
        // This handles variable-length instructions correctly.
        while offset < code_limit && instrs.len() < 256 {
            let instr = self.decode_pcode_at(pstate.code_base, offset);
            offset += instr.size;
            instrs.push(instr);
        }

        // Find index of current PC instruction.
        let current_idx = instrs.iter().position(|i| i.addr == pstate.pc).unwrap_or(0);

        // Window around current PC.
        let start = current_idx.saturating_sub(4);
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
        let code_size = self.eval_stack_base.saturating_sub(pstate.code_base);
        let eval_used = pstate.esp.saturating_sub(self.eval_stack_base);
        let eval_cap = self.call_stack_base.saturating_sub(self.eval_stack_base);
        let call_used = pstate.csp.saturating_sub(self.call_stack_base);
        // Globals and heap are after call stack in the memory map.
        let globals_size = if pstate.gp > 0 { 24 } else { 0 }; // 8 words = 24 bytes
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
                let end = self.eval_stack_base;
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
                let end = pstate.gp + 24; // 8 words * 3 bytes
                (start, end)
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

    /// Run p-code instructions until a depth condition is met.
    /// Returns when depth_check(current_depth) is true or on halt/timeout.
    fn run_until_depth<F>(&mut self, depth_check: F)
    where
        F: Fn(usize) -> bool,
    {
        for _ in 0..500_000u32 {
            // Step one p-code instruction
            let mut i = 0u32;
            loop {
                let result = self.emulator.step();
                self.instruction_count += result.instructions_run;
                self.collect_uart();
                i += 1;
                if matches!(result.reason, StopReason::Halted) {
                    self.halted = true;
                    self.running = false;
                    return;
                }
                if self.read_pcode_state().status != 0 {
                    return;
                }
                if i > 1 && self.emulator.snapshot().pc == self.vm_loop_addr {
                    break;
                }
                if i >= 50_000 {
                    return;
                }
            }
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
    fn feed_uart_byte(&mut self) {
        if self.uart_rx_queue.is_empty() {
            return;
        }
        // Check UART status: bit 0 = RX ready (should be 0 = not ready)
        let status = self.emulator.read_byte(0xFF0101);
        if status & 0x01 == 0
            && let Some(byte) = self.uart_rx_queue.pop_front()
        {
            self.emulator.send_uart_byte(byte);
        }
    }

    /// Patch code_seg with demo bytecodes.
    fn patch_demo_bytecode(&mut self, bytecode: &[u8]) {
        if self.code_seg_addr == 0 {
            return;
        }
        for (i, &b) in bytecode.iter().enumerate() {
            self.emulator.write_byte(self.code_seg_addr + i as u32, b);
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
            config: VmConfig::default(),
            output: String::new(),
            running: false,
            halted: false,
            _tick_handle: None,
            prev_regs: [0; 8],
            prev_pc: 0,
            labels: HashMap::new(),
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
            input: String::new(),
            uart_rx_queue: VecDeque::new(),
        }
    }

    fn update(&mut self, ctx: &Context<Self>, msg: Self::Message) -> bool {
        match msg {
            Msg::Init => {
                self.load_binary();
                true
            }
            Msg::Tick => {
                if !self.running || self.halted {
                    return false;
                }

                self.feed_uart_byte();
                self.save_prev_state();
                let result = self.emulator.run_batch(BATCH_SIZE);
                self.instruction_count += result.instructions_run;
                self.collect_uart();
                self.check_halted(result.reason);

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
                self.load_binary();
                true
            }
            Msg::StepPcode => {
                if self.halted {
                    return false;
                }
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
                    // Run COR24 until host PC returns to vm_loop with a
                    // different p-code PC, meaning one full p-code instruction
                    // has completed its fetch-decode-execute cycle.
                    // Run one full p-code fetch-decode-execute cycle:
                    // step COR24 instructions until host PC returns to
                    // vm_loop. Use do-while pattern (check after first step)
                    // because we may already be sitting on vm_loop.
                    let mut i = 0u32;
                    loop {
                        let result = self.emulator.step();
                        self.instruction_count += result.instructions_run;
                        self.collect_uart();
                        i += 1;
                        if matches!(result.reason, StopReason::Halted) {
                            self.halted = true;
                            self.running = false;
                            break;
                        }
                        if self.read_pcode_state().status != 0 {
                            break;
                        }
                        if i > 1 && self.emulator.snapshot().pc == self.vm_loop_addr {
                            break;
                        }
                        if i >= 50_000 {
                            break;
                        }
                    }
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
                self.save_prev_state();
                let pstate = self.read_pcode_state();
                if pstate.code_base == 0 {
                    // Not initialized yet — just do a regular step.
                    ctx.link().send_message(Msg::StepPcode);
                    return false;
                }
                let target_depth = self.call_depth(&pstate);
                // First, step one p-code instruction.
                let mut i = 0u32;
                loop {
                    let result = self.emulator.step();
                    self.instruction_count += result.instructions_run;
                    self.collect_uart();
                    i += 1;
                    if matches!(result.reason, StopReason::Halted) {
                        self.halted = true;
                        self.running = false;
                        return true;
                    }
                    if self.read_pcode_state().status != 0 {
                        return true;
                    }
                    if i > 1 && self.emulator.snapshot().pc == self.vm_loop_addr {
                        break;
                    }
                    if i >= 50_000 {
                        return true;
                    }
                }
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
                    self.load_binary();
                    // Patch code_seg with demo bytecodes
                    self.patch_demo_bytecode(demo.bytecode);
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
                                let line_class = if is_current {
                                    "disasm-line current"
                                } else {
                                    "disasm-line"
                                };
                                let operand_str = match instr.operand {
                                    Some(v) => format!(" {:06X}", v),
                                    None => String::new(),
                                };
                                html! {
                                    <div class={line_class}>
                                        <span class="disasm-marker">
                                            { if is_current { "\u{25b6}" } else { " " } }
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
                                        { for (0..8).map(|i| {
                                            let changed = snap.regs[i] != self.prev_regs[i];
                                            html! {
                                                <tr class={if changed { "changed" } else { "" }}>
                                                    <td class="reg-name">{ format!("r{i}") }</td>
                                                    <td class="reg-val">{ format!("{:06X}", snap.regs[i]) }</td>
                                                </tr>
                                            }
                                        })}
                                        <tr>
                                            <td class="reg-name">{"C"}</td>
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
