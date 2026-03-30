use cor24_emulator::EmulatorCore;

/// Tiny program: print "1", call a proc that prints "2", then print "3"
/// If we see "123" the call/ret works. If "1" only, call breaks.
/// If "12" only, ret breaks.
const TINY_CALL: &str = "\
.proc main 0
    push_s 49
    sys 1
    call foo
    push_s 51
    sys 1
    halt
.end

.proc foo 0
    push_s 50
    sys 1
    ret 0
.end
";

fn run_fast(source: &str) -> String {
    let pvm = web_sw_cor24_pcode::config::PVM_BINARY;
    let vm_state = web_sw_cor24_pcode::config::label_addr("vm_state");
    let code_seg = web_sw_cor24_pcode::config::label_addr("code_seg");
    let vm_loop = web_sw_cor24_pcode::config::label_addr("vm_loop");

    let result = pa24r::assemble(source);
    assert!(result.errors.is_empty(), "errors: {:?}", result.errors);

    let load_addr: u32 = 0x010000;
    let mut code = result.code.clone();
    let code_size = code.len() as u32;
    let data_size = result.data.len() as u32;
    pa24r::relocate_data_refs(&mut code, code_size, data_size, load_addr);

    let mut emu = EmulatorCore::new();
    emu.hard_reset();
    emu.set_uart_tx_busy_cycles(0);
    emu.load_program(0, pvm);
    emu.load_program_extent(pvm.len() as u32);

    // Write demo
    for (i, &b) in code.iter().chain(result.data.iter()).enumerate() {
        emu.write_byte(load_addr + i as u32, b);
    }

    // Halt at code_seg
    emu.write_byte(code_seg, 0x60);
    emu.write_byte(code_seg + 1, 0x00);

    // Boot pvm.s
    emu.set_pc(0);
    emu.resume();
    emu.run_batch(10_000);

    // Reset, set up for demo
    emu.reset();
    emu.set_uart_tx_busy_cycles(0);
    emu.clear_uart_output();
    emu.set_pc(vm_loop);
    emu.set_reg(3, vm_state);

    // Patch vm_state
    emu.write_byte(vm_state + 18, load_addr as u8);
    emu.write_byte(vm_state + 19, (load_addr >> 8) as u8);
    emu.write_byte(vm_state + 20, (load_addr >> 16) as u8);
    emu.write_byte(vm_state, 0);
    emu.write_byte(vm_state + 1, 0);
    emu.write_byte(vm_state + 2, 0);
    emu.write_byte(vm_state + 21, 0);
    emu.write_byte(vm_state + 22, 0);
    emu.write_byte(vm_state + 23, 0);

    emu.resume();
    emu.run_batch(500_000);
    emu.get_uart_output().to_string()
}

#[test]
fn test_no_call() {
    // Simplest possible: just print "A"
    let output = run_fast(".proc main 0\n    push_s 65\n    sys 1\n    halt\n.end\n");
    println!("no_call output: {:?}", output);
    assert!(output.contains("A"), "got: {:?}", output);
}

#[test]
fn test_call_and_ret() {
    let output = run_fast(TINY_CALL);
    println!("call_ret output: {:?}", output);
    assert!(output.starts_with("123"), "got: {:?}", output);
}

#[test]
fn test_call_with_arg() {
    // Pass argument 42, callee prints it as '*'
    let output = run_fast(
        "\
.proc main 0
    push_s 49
    sys 1
    push_s 42
    call star
    push_s 51
    sys 1
    halt
.end

.proc star 1
    loada 0
    sys 1
    ret 1
.end
",
    );
    println!("call_with_arg output: {:?}", output);

    // Detailed trace of the call_with_arg program
    let result2 = pa24r::assemble(
        "\
.proc main 0
    push_s 49
    sys 1
    push_s 42
    call star
    push_s 51
    sys 1
    halt
.end

.proc star 1
    loada 0
    sys 1
    ret 1
.end
",
    );
    print!("code: ");
    for b in &result2.code {
        print!("{:02X} ", b);
    }
    println!();

    // Disassemble
    let ops: Vec<(&str, usize)> = vec![
        ("enter", 2),
        ("push_s", 2),
        ("sys", 2),
        ("push_s", 2),
        ("call", 4),
        ("push_s", 2),
        ("sys", 2),
        ("halt", 1),
        ("leave", 1),
        ("enter", 2),
        ("loada", 2),
        ("sys", 2),
        ("ret", 2),
        ("leave", 1),
    ];
    let mut off = 0;
    for (name, size) in &ops {
        if off + size <= result2.code.len() {
            if *size == 4 {
                let val = result2.code[off + 1] as u32
                    | (result2.code[off + 2] as u32) << 8
                    | (result2.code[off + 3] as u32) << 16;
                println!("  {:04X}: {} 0x{:06X}", off, name, val);
            } else if *size == 2 {
                println!("  {:04X}: {} {}", off, name, result2.code[off + 1]);
            } else {
                println!("  {:04X}: {}", off, name);
            }
        }
        off += size;
    }

    assert!(output.starts_with("1*3"), "got: {:?}", output);
}
