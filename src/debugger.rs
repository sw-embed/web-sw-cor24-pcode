//! P-code VM debugger component — two-level debugging with p-code semantic
//! layer (primary) and COR24 host implementation layer (secondary drill-down).

use crate::config::VmConfig;
use cor24_emulator::{Assembler, EmulatorCore, StopReason};
use gloo::timers::callback::Timeout;
use std::collections::HashMap;
use yew::prelude::*;

/// Execution batch size per tick (instructions).
const BATCH_SIZE: u64 = 50_000;

/// Tick interval in milliseconds.
const TICK_MS: u32 = 25;

/// Messages driving the debugger state machine.
pub enum Msg {
    /// Load VM assembly and initialize the emulator.
    Init,
    /// Run a batch of instructions.
    Tick,
    /// Reset emulator to initial state.
    Reset,
    /// Step one p-code instruction.
    StepPcode,
    /// Step one COR24 host instruction.
    StepHost,
    /// Toggle run/pause.
    PauseResume,
}

pub struct Debugger {
    emulator: EmulatorCore,
    config: VmConfig,
    output: String,
    running: bool,
    halted: bool,
    /// Pending timeout handle (kept alive to prevent cancel).
    _tick_handle: Option<Timeout>,
    /// Previous register values for change highlighting.
    prev_regs: [u32; 8],
    prev_pc: u32,
    /// Assembler labels: label name -> address.
    labels: HashMap<String, u32>,
    /// Reverse lookup: address -> label name.
    reverse_labels: HashMap<u32, String>,
    /// Program extent (end of assembled code).
    program_end: u32,
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

        self.emulator.hard_reset();
        self.emulator.set_uart_tx_busy_cycles(0);
        self.emulator.load_program(0, &result.bytes);
        self.emulator.load_program_extent(result.bytes.len() as u32);
        self.emulator.set_pc(0);
        self.output.clear();
        self.halted = false;
        self.prev_regs = [0; 8];
        self.prev_pc = 0;

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
}

impl Component for Debugger {
    type Message = Msg;
    type Properties = ();

    fn create(ctx: &Context<Self>) -> Self {
        ctx.link().send_message(Msg::Init);
        let mut emulator = EmulatorCore::new();
        emulator.set_uart_tx_busy_cycles(0); // instant TX in WASM
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

                self.prev_regs = self.emulator.snapshot().regs;
                self.prev_pc = self.emulator.snapshot().pc;

                let result = self.emulator.run_batch(BATCH_SIZE);

                // Collect UART output.
                let uart = self.emulator.get_uart_output();
                if !uart.is_empty() {
                    self.output.push_str(uart);
                    self.emulator.clear_uart_output();
                }

                if matches!(result.reason, StopReason::Halted) {
                    self.halted = true;
                    self.running = false;
                    return true;
                }

                self.schedule_tick(ctx);
                true
            }
            Msg::Reset => {
                self.running = false;
                self._tick_handle = None;
                self.load_binary();
                true
            }
            Msg::StepPcode => {
                if self.halted {
                    return false;
                }
                self.prev_regs = self.emulator.snapshot().regs;
                self.prev_pc = self.emulator.snapshot().pc;
                let result = self.emulator.step();
                let uart = self.emulator.get_uart_output();
                if !uart.is_empty() {
                    self.output.push_str(uart);
                    self.emulator.clear_uart_output();
                }
                if matches!(result.reason, StopReason::Halted) {
                    self.halted = true;
                    self.running = false;
                }
                true
            }
            Msg::StepHost => {
                if self.halted {
                    return false;
                }
                self.prev_regs = self.emulator.snapshot().regs;
                self.prev_pc = self.emulator.snapshot().pc;
                let result = self.emulator.step();
                let uart = self.emulator.get_uart_output();
                if !uart.is_empty() {
                    self.output.push_str(uart);
                    self.emulator.clear_uart_output();
                }
                if matches!(result.reason, StopReason::Halted) {
                    self.halted = true;
                    self.running = false;
                }
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
        }
    }

    fn view(&self, ctx: &Context<Self>) -> Html {
        let link = ctx.link();
        let snap = self.emulator.snapshot();

        html! {
            <div class="debugger">
                // Control bar
                <div class="control-bar">
                    <button onclick={link.callback(|_| Msg::Reset)}
                            class="btn btn-reset">{"Reset"}</button>
                    <button onclick={link.callback(|_| Msg::StepPcode)}
                            class="btn btn-step"
                            disabled={self.halted}>{"Step P-Code"}</button>
                    <button onclick={link.callback(|_| Msg::StepHost)}
                            class="btn btn-step"
                            disabled={self.halted}>{"Step Host"}</button>
                    <button onclick={link.callback(|_| Msg::PauseResume)}
                            class="btn btn-run"
                            disabled={self.halted}>
                        { if self.running { "Pause" } else { "Run" } }
                    </button>
                    <span class="status">
                        { if self.halted {
                            "HALTED"
                        } else if self.running {
                            "RUNNING"
                        } else {
                            "PAUSED"
                        }}
                    </span>
                    <span class="pc-display">
                        { format!("PC: {:06X}", snap.pc) }
                    </span>
                </div>

                // Main panels area
                <div class="panels">
                    // Left: registers
                    <div class="panel panel-registers">
                        <h3>{"Registers"}</h3>
                        <table class="reg-table">
                            { for (0..8).map(|i| {
                                let changed = snap.regs[i] != self.prev_regs[i];
                                html! {
                                    <tr class={if changed { "changed" } else { "" }}>
                                        <td class="reg-name">{ format!("r{i}") }</td>
                                        <td class="reg-val">{ format!("{:06X}", snap.regs[i]) }</td>
                                    </tr>
                                }
                            })}
                        </table>
                    </div>

                    // Center: output
                    <div class="panel panel-output">
                        <h3>{"Output"}</h3>
                        <pre class="output-text">{ &self.output }</pre>
                    </div>
                </div>
            </div>
        }
    }
}
