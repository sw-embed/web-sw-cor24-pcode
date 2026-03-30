use cor24_emulator::EmulatorCore;

#[test]
fn test_hello_world_loads_and_runs() {
    let pvm_binary = web_sw_cor24_pcode::config::PVM_BINARY;
    let hello_p24 = include_bytes!(concat!(env!("OUT_DIR"), "/hello.p24"));
    let image = pa24r::load_p24(hello_p24).unwrap();

    let mut emu = EmulatorCore::new();
    emu.hard_reset();
    emu.set_uart_tx_busy_cycles(0);
    emu.load_program(0, pvm_binary);
    emu.load_program_extent(pvm_binary.len() as u32);

    // Load demo at safe address with data relocation
    let load_addr: u32 = 0x010000;
    let code_size = image.code.len() as u32;
    let total = code_size + image.data.len() as u32;

    // Write code + data contiguously
    for (i, &b) in image.code.iter().chain(image.data.iter()).enumerate() {
        emu.write_byte(load_addr + i as u32, b);
    }

    // Relocate push instructions with data references
    let mut i: u32 = 0;
    while i < code_size {
        let op = emu.read_byte(load_addr + i);
        let size = match op {
            0x01 | 0x30..=0x33 | 0x54..=0x56 => 4, // IMM24
            0x02 | 0x34..=0x36 | 0x40 | 0x42..=0x45 | 0x57 | 0x60 => 2, // IMM8
            0x58 | 0x59 => 3,                      // D8_O8
            0x5A => 5,                             // D8_A24
            _ => 1,                                // NONE
        };
        if op == 0x01 && i + 4 <= code_size {
            let lo = emu.read_byte(load_addr + i + 1) as u32;
            let mid = emu.read_byte(load_addr + i + 2) as u32;
            let hi = emu.read_byte(load_addr + i + 3) as u32;
            let val = lo | (mid << 8) | (hi << 16);
            if val >= code_size && val < total {
                let abs = val + load_addr;
                emu.write_byte(load_addr + i + 1, abs as u8);
                emu.write_byte(load_addr + i + 2, (abs >> 8) as u8);
                emu.write_byte(load_addr + i + 3, (abs >> 16) as u8);
            }
        }
        i += size;
    }

    // Put halt at code_seg so pvm.s init halts cleanly
    let code_seg = web_sw_cor24_pcode::config::label_addr("code_seg");
    emu.write_byte(code_seg, 0x60); // sys
    emu.write_byte(code_seg + 1, 0x00); // halt

    // Run pvm.s init
    emu.set_pc(0);
    emu.resume();
    emu.run_batch(10_000);

    // Soft reset (clears halted, preserves memory)
    emu.reset();
    emu.set_uart_tx_busy_cycles(0);
    emu.clear_uart_output();

    // Set up for demo execution
    let vm_state = web_sw_cor24_pcode::config::label_addr("vm_state");
    let vm_loop = web_sw_cor24_pcode::config::label_addr("vm_loop");
    emu.set_pc(vm_loop);
    emu.set_reg(3, vm_state); // fp = &vm_state

    // Patch vm_state
    // code = load_addr
    emu.write_byte(vm_state + 18, load_addr as u8);
    emu.write_byte(vm_state + 19, (load_addr >> 8) as u8);
    emu.write_byte(vm_state + 20, (load_addr >> 16) as u8);
    // pc = 0
    emu.write_byte(vm_state, 0);
    emu.write_byte(vm_state + 1, 0);
    emu.write_byte(vm_state + 2, 0);
    // status = 0
    emu.write_byte(vm_state + 21, 0);
    emu.write_byte(vm_state + 22, 0);
    emu.write_byte(vm_state + 23, 0);

    // Run
    emu.resume();
    let result = emu.run_batch(500_000);
    let output = emu.get_uart_output();
    println!(
        "demo: {} instrs, {:?}",
        result.instructions_run, result.reason
    );
    println!("output: {output:?}");

    assert!(result.instructions_run > 0);
    assert!(output.contains("Hello"), "got: {output:?}");
}
