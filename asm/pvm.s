; pvm.s — P-Code Virtual Machine for COR24
;
; Register allocation:
;   r0 = W (work/scratch, opcode dispatch)
;   r1 = scratch / return address for jal calls
;   r2 = scratch
;   sp = COR24 hardware stack (EBR, used sparingly)
;   fp = memory base for indexed loads/stores
;
; VM state lives in memory struct (vm_state) because COR24 has only 3 GPRs.
;
; UART: data at -65280 (0xFF0100), status at -65279 (0xFF0101)
;   TX busy = status bit 7 (sign bit via lb sign-extend)
;   RX ready = status bit 0
; LED/Switch: port at -65536 (0xFF0000), write bit 0 = LED D2, read bit 0 = button S2
;
; COR24 ISA notes:
;   lbu = load byte zero-extend, lb = load byte sign-extend
;   ceq ra, rb sets C if ra == rb; cls ra, rb sets C if ra < rb (signed)
;   clu ra, rb sets C if ra < rb (unsigned)
;   brt/brf = branch if C true/false; bra = branch always
;   jal r1, (r2) = r1 = PC+1, PC = r2 (call convention)
;   jmp (r1) = return from jal call
;   Valid load/store base registers: r0, r1, r2, fp (NOT sp)
;   Can push/pop: r0, r1, r2, fp

; ============================================================
; Entry point
; ============================================================
_start:
    ; Initialize VM state struct (fp = &vm_state)
    la r0, vm_state
    push r0
    pop fp

    ; pc = 0
    lc r0, 0
    sw r0, 0(fp)

    ; esp = eval_stack base
    la r0, eval_stack
    sw r0, 3(fp)

    ; csp = call_stack base
    la r0, call_stack
    sw r0, 6(fp)

    ; fp_vm = 0 (no frame yet)
    lc r0, 0
    sw r0, 9(fp)

    ; gp = globals base
    la r0, globals_seg
    sw r0, 12(fp)

    ; hp = heap base
    la r0, heap_seg
    sw r0, 15(fp)

    ; code = indirect via code_ptr (patchable for external .p24 loading)
    la r0, code_ptr
    lw r0, 0(r0)
    ; r0 = address pointed to by code_ptr
    ; Save it — we'll check for .p24m magic
    push r0

    ; status = 0 (running)
    lc r0, 0
    sw r0, 21(fp)

    ; trap_code = 0
    lc r0, 0
    sw r0, 24(fp)

    ; irt_base = 0 (default: no IRT)
    lc r0, 0
    sw r0, 27(fp)

    ; unit_count = 0
    lc r0, 0
    sw r0, 30(fp)

    ; current_unit = 0
    lc r0, 0
    sw r0, 33(fp)

    ; unit_table_ptr = 0
    lc r0, 0
    sw r0, 36(fp)

    ; p24m_base = 0
    lc r0, 0
    sw r0, 39(fp)

    ; Print boot message
    la r0, msg_boot
    la r2, uart_puts
    jal r1, (r2)

    ; Check if code_ptr points to a .p24m image
    ; Magic bytes: 0x50 0x32 0x34 0x4D ("P24M")
    pop r0
    ; r0 = load address
    push r0                  ; save load_addr
    push r0                  ; save again for byte reads
    lbu r0, 0(r0)
    lc r2, 0x50              ; 'P'
    ceq r0, r2
    brf init_raw_code_pop
    pop r0
    push r0
    lbu r0, 1(r0)
    lc r2, 0x32              ; '2'
    ceq r0, r2
    brf init_raw_code_pop
    pop r0
    push r0
    lbu r0, 2(r0)
    lc r2, 0x34              ; '4'
    ceq r0, r2
    brf init_raw_code_pop
    pop r0
    push r0
    lbu r0, 3(r0)
    lc r2, 0x4D              ; 'M'
    ceq r0, r2
    brf init_raw_code_pop
    pop r0                   ; discard extra copy
    la r0, init_p24m
    jmp (r0)

init_raw_code_pop:
    pop r0                   ; discard extra load_addr copy
    la r0, init_raw_code
    jmp (r0)

    ; ── .p24m detected: parse header ──
init_p24m:
    ; r0 = base address of .p24m image
    ; Header layout:
    ;   [0..4]  magic "P24M"
    ;   [4]     version
    ;   [5..8]  entry_point (LE24)
    ;   [8]     unit_count
    ;   [9..12] total_code (LE24)
    ;   [12..15] total_globals (LE24)
    ;   [15..18] unit_table_off (LE24)
    ;   [18..21] irt_off (LE24)
    ;   [21..24] code_off (LE24)
    ;   [24..27] globals_off (LE24)
    pop r0                   ; r0 = load_addr (base)
    sw r0, 39(fp)            ; vm_state.p24m_base = base

    ; Use p24m_temps as scratch for base addr
    la r2, p24m_temps
    sw r0, 3(r2)             ; p24m_temps[3] = base

    ; Read entry_point from offset 5
    push fp
    push r0
    pop fp
    lw r2, 5(fp)             ; r2 = entry_point (LE24)
    pop fp
    la r0, p24m_temps
    sw r2, 0(r0)             ; p24m_temps[0] = entry_point

    ; Read unit_count from offset 8
    la r0, p24m_temps
    lw r0, 3(r0)             ; r0 = base
    lbu r2, 8(r0)            ; r2 = unit_count
    sb r2, 30(fp)            ; vm_state.unit_count = unit_count

    ; Read unit_table_off from offset 15
    push fp
    push r0
    pop fp
    lw r2, 15(fp)            ; r2 = unit_table_off
    pop fp
    la r0, p24m_temps
    lw r0, 3(r0)             ; r0 = base
    add r2, r0               ; r2 = base + unit_table_off
    sw r2, 36(fp)            ; vm_state.unit_table_ptr = abs unit table addr

    ; Read unit 0's IRT offset from unit_table[0] + 6
    ; Unit table entry: base_addr(3) + global_base(3) + irt_off(3)
    ; unit_table_ptr already set; read irt_off at +6
    push fp
    lw r0, 36(fp)            ; r0 = unit_table_ptr
    push r0
    pop fp
    lw r2, 6(fp)             ; r2 = unit 0's irt_off (file-relative)
    pop fp
    la r0, p24m_temps
    lw r0, 3(r0)             ; r0 = base
    add r2, r0               ; r2 = base + irt_off = abs IRT section addr
    ; Skip 2-byte import_count prefix → actual IRT entries
    add r2, 2
    sw r2, 27(fp)            ; vm_state.irt_base = abs addr of unit 0's IRT entries

    ; Read code_off from offset 21
    la r0, p24m_temps
    lw r0, 3(r0)             ; r0 = base
    push fp
    push r0
    pop fp
    lw r2, 21(fp)            ; r2 = code_off
    pop fp
    la r0, p24m_temps
    lw r0, 3(r0)             ; r0 = base
    add r2, r0               ; r2 = base + code_off = absolute code addr
    sw r2, 18(fp)            ; vm_state.code = abs code addr

    ; Read globals_off from offset 24
    la r0, p24m_temps
    lw r0, 3(r0)             ; r0 = base
    push fp
    push r0
    pop fp
    lw r2, 24(fp)            ; r2 = globals_off
    pop fp
    la r0, p24m_temps
    lw r0, 3(r0)             ; r0 = base
    add r2, r0               ; r2 = base + globals_off = absolute globals addr
    sw r2, 12(fp)            ; vm_state.gp = abs globals addr

    ; Set pc = entry_point
    la r0, p24m_temps
    lw r0, 0(r0)
    sw r0, 0(fp)             ; vm_state.pc = entry_point

    ; Check boot flags
    la r0, init_done
    jmp (r0)

init_raw_code:
    ; Not .p24m — check for .p24 header ("P24\0" magic)
    pop r0                   ; r0 = load_addr
    push r0
    lbu r0, 0(r0)
    lc r2, 0x50              ; 'P'
    ceq r0, r2
    brf init_raw_bytecode
    pop r0
    push r0
    lbu r0, 1(r0)
    lc r2, 0x32              ; '2'
    ceq r0, r2
    brf init_raw_bytecode
    pop r0
    push r0
    lbu r0, 2(r0)
    lc r2, 0x34              ; '4'
    ceq r0, r2
    brf init_raw_bytecode
    pop r0
    push r0
    lbu r0, 3(r0)
    ceq r0, z                ; '\0'
    brf init_raw_bytecode

    ; ── .p24 v1 header detected ──
    ; Parse header: skip 18-byte header, set code/pc/gp
    ; Header: magic(4) ver(1) entry(3) code_size(3) data_size(3)
    ;         global_count(3) flags(1)
    pop r0                   ; r0 = base
    push r0

    ; Read entry_point from offset 5
    push fp
    push r0
    pop fp
    lw r2, 5(fp)             ; r2 = entry_point
    pop fp
    sw r2, 0(fp)             ; vm_state.pc = entry_point

    ; Read code_size from offset 8
    pop r0                   ; r0 = base
    push r0
    push fp
    push r0
    pop fp
    lw r2, 8(fp)             ; r2 = code_size
    pop fp
    la r0, p24m_temps
    sw r2, 0(r0)             ; p24m_temps[0] = code_size

    ; Read data_size from offset 11
    pop r0                   ; r0 = base
    push r0
    push fp
    push r0
    pop fp
    lw r2, 11(fp)            ; r2 = data_size
    pop fp
    la r0, p24m_temps
    sw r2, 3(r0)             ; p24m_temps[3] = data_size

    ; Set code = base + 18 (skip header)
    pop r0                   ; r0 = base
    push r0
    add r0, 18
    sw r0, 18(fp)            ; vm_state.code = base + 18

    ; Set gp = base + 18 + code_size + data_size
    ; (globals follow code+data in the loaded image)
    ; But the .p24 file doesn't include globals bytes, so use globals_seg
    ; gp stays as globals_seg (set during init above)

    pop r0                   ; clean stack
    la r0, init_done
    jmp (r0)

init_raw_bytecode:
    ; No header — treat code_ptr as raw bytecode (pvmasm.s embedded code)
    pop r0                   ; r0 = load_addr
    sw r0, 18(fp)            ; vm_state.code = load_addr
    ; pc already 0, gp already set to globals_seg

    ; Fall through to init_done

; ── Check boot flags and optionally print memory map ──
init_done:
    la r0, vm_state
    push r0
    pop fp
    ; Read vm_flags
    la r0, vm_flags
    lbu r0, 0(r0)
    ; Bit 0 = verbose boot?
    lc r2, 1
    and r0, r2
    ceq r0, z
    brt init_run             ; not set → skip verbose
    ; ── Verbose boot: print memory map ──
    ; Use sys_dump_state to print vm_state (reuses the existing handler)
    la r0, sys_dump_state
    jmp (r0)
    ; Note: sys_dump_state jumps to vm_loop when done, which is correct —
    ; it prints the state and then starts execution.

init_run:
    la r0, vm_loop
    jmp (r0)

; ============================================================
; UART helpers
; ============================================================

; uart_put_hex24 — print 24-bit value in r0 as 6 hex digits
; Call via: jal r1, (r2) with r2 = uart_put_hex24, r0 = value
; Non-leaf. Clobbers: r0, r1, r2.
uart_put_hex24:
    push r1
    ; Save value
    la r2, hex_temp
    sw r0, 0(r2)
    ; Print high byte (bits 23-16)
    lc r2, 16
    sra r0, r2
    lcu r2, 0xFF
    and r0, r2
    la r2, uart_put_hex8
    jal r1, (r2)
    ; Print mid byte (bits 15-8)
    la r0, hex_temp
    lw r0, 0(r0)
    lc r2, 8
    sra r0, r2
    lcu r2, 0xFF
    and r0, r2
    la r2, uart_put_hex8
    jal r1, (r2)
    ; Print low byte (bits 7-0)
    la r0, hex_temp
    lw r0, 0(r0)
    lcu r2, 0xFF
    and r0, r2
    la r2, uart_put_hex8
    jal r1, (r2)
    pop r1
    jmp (r1)

; uart_put_hex8 — print byte in r0 as 2 hex digits
; Non-leaf. Clobbers: r0, r1, r2.
uart_put_hex8:
    push r1
    push r0
    ; High nybble
    lc r2, 4
    sra r0, r2
    lc r2, 0x0F
    and r0, r2
    la r2, uart_put_nybble
    jal r1, (r2)
    ; Low nybble
    pop r0
    lc r2, 0x0F
    and r0, r2
    la r2, uart_put_nybble
    jal r1, (r2)
    pop r1
    jmp (r1)

; uart_put_nybble — print low 4 bits of r0 as hex digit
; Leaf. Clobbers: r0, r2.
uart_put_nybble:
    lc r2, 10
    clu r0, r2              ; r0 < 10?
    brt hex_digit_num
    ; A-F: r0 - 10 + 'A'
    add r0, -10
    add r0, 65              ; 'A' = 65
    bra hex_digit_out
hex_digit_num:
    ; 0-9: r0 + '0'
    add r0, 48              ; '0' = 48
hex_digit_out:
    la r2, -65280
hex_nybble_tx:
    push r0
    lb r0, 1(r2)
    cls r0, z
    brt hex_nybble_tx
    pop r0
    sb r0, 0(r2)
    jmp (r1)

hex_temp:
    .word 0

; uart_putc — send byte in r0 to UART
; Call via: jal r1, (r2) with r2 = uart_putc
; Clobbers: r0, r2 (r1 = return address, preserved)
uart_putc:
    push r0
    la r2, -65280
uart_putc_wait:
    lb r0, 1(r2)
    cls r0, z
    brt uart_putc_wait
    pop r0
    sb r0, 0(r2)
    jmp (r1)

; uart_puts — print null-terminated string at address in r0
; Call via: jal r1, (r2) with r2 = uart_puts, r0 = string addr
; Clobbers: r0, r1, r2
uart_puts:
    push r1
    mov r1, r0
uart_puts_loop:
    lbu r0, 0(r1)
    ceq r0, z
    brt uart_puts_done
    push r1
    push r0
    la r2, -65280
uart_puts_tx:
    lb r0, 1(r2)
    cls r0, z
    brt uart_puts_tx
    pop r0
    sb r0, 0(r2)
    pop r1
    add r1, 1
    bra uart_puts_loop
uart_puts_done:
    pop r1
    jmp (r1)

; ============================================================
; VM fetch-decode-execute loop
; ============================================================
vm_loop:
    ; Check status: if not running (0), stop
    la r0, vm_state
    push r0
    pop fp
    lw r0, 21(fp)
    ceq r0, z
    brf vm_halted

    ; Fetch opcode byte from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    ; r0 = code_base + pc, use r0 as base register
    lbu r2, 0(r0)
    ; r2 = opcode byte (zero-extended)

    ; Increment pc
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)

    ; Bounds check: opcode must be < 116 (0x00..0x73)
    mov r0, r2
    lc r2, 119
    clu r0, r2
    brt opcode_ok
    la r0, op_invalid
    jmp (r0)
opcode_ok:

    ; Dispatch: compute dispatch_table[opcode * 3]
    mov r2, r0
    add r0, r0
    add r0, r2
    ; r0 = 3 * opcode
    la r2, dispatch_table
    add r2, r0
    ; r2 = &dispatch_table[opcode * 3]
    lw r0, 0(r2)
    ; r0 = handler address
    jmp (r0)

; ============================================================
; VM halt / trap exit
; ============================================================
vm_halted:
    ; r0 = status (nonzero)
    ; Check if trapped (status == 2)
    lc r2, 2
    ceq r0, r2
    brt vm_trapped
    ; Normal halt
    la r0, msg_halted
    la r2, uart_puts_final
    jal r1, (r2)
vm_trapped:
    ; Print "TRAP " prefix (uart_puts preserves r1)
    la r0, msg_trap_prefix
    la r2, uart_puts
    jal r1, (r2)
    ; Load trap_code from vm_state
    la r0, vm_state
    push r0
    pop fp
    lw r0, 24(fp)
    ; Convert to ASCII digit (codes 0-7)
    add r0, 48
    ; Print digit via uart_putc
    la r2, uart_putc
    jal r1, (r2)
    ; Print newline
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    ; Halt
    la r0, halt_loop
    jmp (r0)

; uart_puts_final — print string then enter halt loop
; r0 = string address. Does not return.
uart_puts_final:
    mov r1, r0
uart_puts_final_loop:
    lbu r0, 0(r1)
    ceq r0, z
    brt halt_loop
    push r1
    push r0
    la r2, -65280
uart_puts_final_tx:
    lb r0, 1(r2)
    cls r0, z
    brt uart_puts_final_tx
    pop r0
    sb r0, 0(r2)
    pop r1
    add r1, 1
    bra uart_puts_final_loop

halt_loop:
    bra halt_loop

; ============================================================
; vm_trap — centralized trap handler
; r0 = trap code (0-7). Sets status=2, trap_code=r0, returns to vm_loop.
; ============================================================
vm_trap:
    push r0
    la r0, vm_state
    push r0
    pop fp
    lc r0, 2
    sw r0, 21(fp)
    pop r0
    sw r0, 24(fp)
    la r0, vm_loop
    jmp (r0)

; ============================================================
; Opcode handlers
; ============================================================

; 0x00 — halt: set status=1, return to vm_loop
op_halt:
    la r0, vm_state
    push r0
    pop fp
    lc r0, 1
    sw r0, 21(fp)
    la r0, vm_loop
    jmp (r0)

; 0x01 — push imm24: fetch 3-byte operand, push onto eval stack
op_push:
    ; fp = &vm_state from dispatch
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    ; r0 = &code[pc]
    lw r2, 0(r0)
    ; r2 = 24-bit immediate
    push r2
    ; Increment pc by 3
    lw r0, 0(fp)
    add r0, 3
    sw r0, 0(fp)
    ; Check eval stack overflow before push
    lw r2, 3(fp)
    la r0, heap_seg
    clu r2, r0
    brt push_no_overflow
    pop r0
    lc r0, 2
    la r2, vm_trap
    jmp (r2)
push_no_overflow:
    ; r2 = esp
    pop r0
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x02 — push_s imm8: fetch 1-byte sign-extended operand, push onto eval stack
op_push_s:
    ; fp = &vm_state from dispatch
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    ; r0 = &code[pc]
    lb r2, 0(r0)
    ; r2 = sign-extended byte operand
    push r2
    ; Increment pc by 1
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; Check eval stack overflow before push
    lw r2, 3(fp)
    la r0, heap_seg
    clu r2, r0
    brt push_s_no_overflow
    pop r0
    lc r0, 2
    la r2, vm_trap
    jmp (r2)
push_s_no_overflow:
    pop r0
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x03 — dup: duplicate top of eval stack
op_dup:
    ; fp = &vm_state from dispatch
    lw r2, 3(fp)
    ; r2 = esp
    lw r0, -3(r2)
    ; r0 = TOS value
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x04 — drop: discard top of eval stack
op_drop:
    ; fp = &vm_state from dispatch
    ; Check eval stack underflow: esp must be > eval_stack base
    lw r2, 3(fp)
    la r0, eval_stack
    clu r0, r2
    brt drop_no_underflow
    lc r0, 3
    la r2, vm_trap
    jmp (r2)
drop_no_underflow:
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x05 — swap: ( a b -- b a )
op_swap:
    ; fp = &vm_state from dispatch
    lw r0, 3(fp)
    ; r0 = esp
    add r0, -3
    ; r0 = &b (TOS)
    lw r2, 0(r0)
    ; r2 = b
    push r2
    add r0, -3
    ; r0 = &a (NOS)
    lw r2, 0(r0)
    ; r2 = a, hw stack top = b
    ; Store a where b was
    sw r2, 3(r0)
    ; Store b where a was
    pop r2
    sw r2, 0(r0)
    la r0, vm_loop
    jmp (r0)

; 0x06 — over: ( a b -- a b a )
op_over:
    ; fp = &vm_state from dispatch
    lw r2, 3(fp)
    ; r2 = esp
    lw r0, -6(r2)
    ; r0 = a (NOS)
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; ============================================================
; Arithmetic / Logic opcode handlers (0x10-0x1B)
; ============================================================

; 0x10 — add: ( a b -- a+b )
op_add:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    add r1, r2
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x11 — sub: ( a b -- a-b )
op_sub:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    sub r1, r2
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x12 — mul: ( a b -- a*b )
op_mul:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    mul r1, r2
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x13 — div: ( a b -- a/b ) signed, traps on b=0
op_div:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    push r0
    ceq r2, z
    brf div_ok
    pop r0
    lc r0, 1
    la r2, vm_trap
    jmp (r2)
div_ok:
    ; Compute sign of result: xor sign bits of a and b
    mov r0, r1
    xor r0, r2
    push r0
    ; Take |a|
    cls r1, z
    brf div_abs_a
    lc r0, 0
    sub r0, r1
    mov r1, r0
div_abs_a:
    ; Take |b|
    cls r2, z
    brf div_abs_b
    push r1
    lc r1, 0
    sub r1, r2
    mov r2, r1
    pop r1
div_abs_b:
    ; Unsigned divide: |a| / |b| by repeated subtraction
    lc r0, 0
div_loop:
    clu r1, r2
    brt div_done
    sub r1, r2
    add r0, 1
    bra div_loop
div_done:
    ; r0 = quotient
    mov r1, r0
    ; Apply sign: negate if sign indicator < 0
    pop r0
    cls r0, z
    brf div_pos
    lc r0, 0
    sub r0, r1
    mov r1, r0
div_pos:
    pop r0
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x14 — mod: ( a b -- a%b ) signed, remainder sign = dividend sign
op_mod:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    push r0
    ceq r2, z
    brf mod_ok
    pop r0
    lc r0, 1
    la r2, vm_trap
    jmp (r2)
mod_ok:
    ; Save sign of dividend (remainder sign = dividend sign)
    cls r1, z
    brf mod_sign_pos
    lc r0, 1
    push r0
    bra mod_sign_set
mod_sign_pos:
    lc r0, 0
    push r0
mod_sign_set:
    ; Take |a|
    cls r1, z
    brf mod_abs_a
    lc r0, 0
    sub r0, r1
    mov r1, r0
mod_abs_a:
    ; Take |b|
    cls r2, z
    brf mod_abs_b
    push r1
    lc r1, 0
    sub r1, r2
    mov r2, r1
    pop r1
mod_abs_b:
    ; Unsigned mod: |a| % |b|
mod_loop:
    clu r1, r2
    brt mod_done
    sub r1, r2
    bra mod_loop
mod_done:
    ; r1 = |remainder|
    pop r0
    ceq r0, z
    brt mod_pos
    lc r0, 0
    sub r0, r1
    mov r1, r0
mod_pos:
    pop r0
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x15 — neg: ( a -- -a )
op_neg:
    lw r0, 3(fp)
    lw r1, -3(r0)
    lc r0, 0
    sub r0, r1
    lw r2, 3(fp)
    sw r0, -3(r2)
    la r0, vm_loop
    jmp (r0)

; 0x16 — and: ( a b -- a&b )
op_and:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    and r1, r2
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x17 — or: ( a b -- a|b )
op_or:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    or r1, r2
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x18 — xor: ( a b -- a^b )
op_xor:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    xor r1, r2
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x19 — not: ( a -- ~a ) bitwise complement via xor with -1
op_not:
    lw r0, 3(fp)
    lw r1, -3(r0)
    la r0, -1
    xor r0, r1
    lw r2, 3(fp)
    sw r0, -3(r2)
    la r0, vm_loop
    jmp (r0)

; 0x1A — shl: ( a n -- a<<n )
op_shl:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    shl r1, r2
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x1B — shr: ( a n -- a>>n ) arithmetic shift right
op_shr:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    sra r1, r2
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; ============================================================
; Comparison opcode handlers (0x20-0x25)
; All pop two values, push 1 (true) or 0 (false)
; ============================================================

; 0x20 — eq: ( a b -- flag ) a == b
op_eq:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    ceq r1, r2
    brt eq_true
    lc r1, 0
    bra eq_done
eq_true:
    lc r1, 1
eq_done:
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x21 — ne: ( a b -- flag ) a != b
op_ne:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    ceq r1, r2
    brf ne_true
    lc r1, 0
    bra ne_done
ne_true:
    lc r1, 1
ne_done:
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x22 — lt: ( a b -- flag ) a < b (signed)
op_lt:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    cls r1, r2
    brt lt_true
    lc r1, 0
    bra lt_done
lt_true:
    lc r1, 1
lt_done:
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x23 — le: ( a b -- flag ) a <= b (signed) = !(b < a)
op_le:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    cls r2, r1
    brf le_true
    lc r1, 0
    bra le_done
le_true:
    lc r1, 1
le_done:
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x24 — gt: ( a b -- flag ) a > b (signed) = b < a
op_gt:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    cls r2, r1
    brt gt_true
    lc r1, 0
    bra gt_done
gt_true:
    lc r1, 1
gt_done:
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x25 — ge: ( a b -- flag ) a >= b (signed) = !(a < b)
op_ge:
    lw r0, 3(fp)
    lw r1, -6(r0)
    lw r2, -3(r0)
    cls r1, r2
    brf ge_true
    lc r1, 0
    bra ge_done
ge_true:
    lc r1, 1
ge_done:
    sw r1, -6(r0)
    add r0, -3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; ============================================================
; Control flow opcode handlers (0x30-0x32)
; ============================================================

; 0x30 — jmp addr24: unconditional jump (pc = addr24)
op_jmp:
    ; fp = &vm_state
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    ; r0 = &code[pc]
    lw r2, 0(r0)
    ; r2 = addr24 (target)
    sw r2, 0(fp)
    ; pc = addr24
    la r0, vm_loop
    jmp (r0)

; 0x31 — jz addr24: pop flag, jump if zero
op_jz:
    ; fp = &vm_state
    ; Fetch addr24 from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lw r2, 0(r0)
    ; r2 = addr24
    push r2
    ; Advance pc past 3-byte operand
    lw r0, 0(fp)
    add r0, 3
    sw r0, 0(fp)
    ; Pop flag from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = flag
    ceq r0, z
    brf jz_skip
    ; flag == 0: jump (pc = addr24)
    pop r0
    sw r0, 0(fp)
    la r0, vm_loop
    jmp (r0)
jz_skip:
    pop r0
    la r0, vm_loop
    jmp (r0)

; 0x32 — jnz addr24: pop flag, jump if nonzero
op_jnz:
    ; fp = &vm_state
    ; Fetch addr24 from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lw r2, 0(r0)
    ; r2 = addr24
    push r2
    ; Advance pc past 3-byte operand
    lw r0, 0(fp)
    add r0, 3
    sw r0, 0(fp)
    ; Pop flag from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = flag
    ceq r0, z
    brt jnz_skip
    ; flag != 0: jump (pc = addr24)
    pop r0
    sw r0, 0(fp)
    la r0, vm_loop
    jmp (r0)
jnz_skip:
    pop r0
    la r0, vm_loop
    jmp (r0)

; ============================================================
; Frame management opcode handlers (0x33, 0x34, 0x40, 0x41)
; ============================================================

; 0x33 — call addr24: save frame header on call stack, jump to procedure
; Frame header layout (4 words, 12 bytes):
;   csp+0  = return PC
;   csp+3  = dynamic link (caller's fp_vm)
;   csp+6  = static link (0 for now)
;   csp+9  = saved esp (for arg access)
op_call:
    ; fp = &vm_state
    ; Fetch addr24 (target) from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lw r2, 0(r0)
    ; r2 = target address
    push r2
    ; Return PC = pc + 3 (skip past addr24 operand)
    lw r0, 0(fp)
    add r0, 3
    ; Build frame header on call stack
    lw r2, 6(fp)
    ; r2 = csp
    sw r0, 0(r2)
    ; frame[0] = return PC
    lw r0, 9(fp)
    sw r0, 3(r2)
    ; frame[3] = dynamic link (current fp_vm)
    lc r0, 0
    sw r0, 6(r2)
    ; frame[6] = static link (0, step 007 adds chain)
    lw r0, 3(fp)
    sw r0, 9(r2)
    ; frame[9] = saved esp
    ; Advance csp by 12 (frame header size)
    add r2, 12
    sw r2, 6(fp)
    ; Set pc = target
    pop r0
    sw r0, 0(fp)
    la r0, vm_loop
    jmp (r0)

; 0x34 — ret nargs8: return from procedure, clean args, handle return value
; Detects return value by comparing esp to saved_esp
op_ret:
    ; fp = &vm_state
    ; Fetch nargs byte, compute nargs * 3
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = nargs
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = nargs * 3
    la r2, ret_temps
    sw r0, 0(r2)
    ; ret_temps[0] = nargs * 3
    ; Get saved_esp from frame header (fp_vm - 3)
    lw r0, 9(fp)
    lw r1, -3(r0)
    ; r1 = saved_esp
    la r2, ret_temps
    sw r1, 3(r2)
    ; ret_temps[3] = saved_esp
    ; Check for return value: esp > saved_esp?
    lw r0, 3(fp)
    ; r0 = current esp
    cls r1, r0
    brf ret_no_rv
    ; Has return value: save TOS
    lw r0, -3(r0)
    ; r0 = retval (eval stack TOS)
    la r2, ret_temps
    sw r0, 6(r2)
    ; ret_temps[6] = retval
    lc r0, 1
    sw r0, 9(r2)
    ; ret_temps[9] = has_rv = 1
    bra ret_restore
ret_no_rv:
    la r2, ret_temps
    lc r0, 0
    sw r0, 9(r2)
    ; ret_temps[9] = has_rv = 0
ret_restore:
    ; Check for cross-unit return: read static_link from frame
    ; static_link is at fp_vm - 6
    lw r0, 9(fp)
    lw r2, -6(r0)           ; r2 = static_link
    ; Save it for post-restore check
    la r0, ret_temps
    sw r2, 12(r0)           ; ret_temps[12] = static_link
    ; Restore pc from frame header (fp_vm - 12)
    lw r0, 9(fp)
    lw r2, -12(r0)
    sw r2, 0(fp)
    ; pc = return PC
    ; Set csp = fp_vm - 12 (pop entire frame)
    add r0, -12
    sw r0, 6(fp)
    ; Restore fp_vm from dynamic link (fp_vm - 9)
    lw r0, 9(fp)
    lw r2, -9(r0)
    sw r2, 9(fp)
    ; fp_vm = caller's fp_vm
    ; Clean args: esp = saved_esp - nargs * 3
    la r0, ret_temps
    lw r1, 3(r0)
    ; r1 = saved_esp
    lw r2, 0(r0)
    ; r2 = nargs * 3
    sub r1, r2
    sw r1, 3(fp)
    ; esp = saved_esp - nargs * 3
    ; Push return value if present
    la r0, ret_temps
    lw r2, 9(r0)
    ceq r2, z
    brt ret_done
    ; Push retval onto eval stack
    lw r2, 6(r0)
    ; r2 = retval
    lw r0, 3(fp)
    ; r0 = esp
    sw r2, 0(r0)
    add r0, 3
    sw r0, 3(fp)
ret_done:
    ; Check if this was a cross-unit return
    ; static_link high byte nonzero => xcall frame
    la r0, ret_temps
    lw r0, 12(r0)           ; r0 = saved static_link
    ; Extract high byte: shift right by 16
    lc r2, 16
    sra r0, r2              ; r0 = high byte of static_link
    ceq r0, z
    brt ret_no_xunit
    ; Cross-unit return: restore current_unit = high_byte - 1
    add r0, -1              ; r0 = caller's unit_id
    sb r0, 33(fp)           ; current_unit = caller's unit_id
ret_no_xunit:
    la r0, vm_loop
    jmp (r0)

; 0x35 — calln depth8 addr24: call with static link chain
; Like call, but sets the static link based on depth:
;   depth=0: static link = current fp_vm (calling nested proc)
;   depth=1: static link = current frame's static link (calling sibling)
;   depth=N: follow static link chain N-1 times from current static link
op_calln:
    ; fp = &vm_state
    ; Fetch depth8 from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = depth
    la r0, nonlocal_temps
    sw r2, 0(r0)
    ; nonlocal_temps[0] = depth
    ; Fetch addr24 from code[pc+1]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r2, 1
    add r0, r2
    lw r2, 0(r0)
    ; r2 = target address
    push r2
    ; Return PC = pc + 4 (1 byte depth + 3 bytes addr24)
    lw r0, 0(fp)
    add r0, 4
    ; Compute static link based on depth
    ; If depth == 0: static link = current fp_vm
    la r2, nonlocal_temps
    lw r1, 0(r2)
    ; r1 = depth
    ceq r1, z
    brt calln_depth_zero
    ; depth > 0: start from current frame's static link
    lw r2, 9(fp)
    lw r2, -6(r2)
    ; r2 = current frame's static link (one level up)
    add r1, -1
    ; Follow chain depth-1 more times
calln_chain:
    ceq r1, z
    brt calln_chain_done
    lw r2, -6(r2)
    add r1, -1
    bra calln_chain
calln_depth_zero:
    lw r2, 9(fp)
    ; r2 = current fp_vm (static link for nested call)
calln_chain_done:
    ; r2 = computed static link
    ; r0 = return PC
    la r1, nonlocal_temps
    sw r2, 3(r1)
    ; nonlocal_temps[3] = static link
    ; Build frame header on call stack
    lw r2, 6(fp)
    ; r2 = csp
    sw r0, 0(r2)
    ; frame[0] = return PC
    lw r0, 9(fp)
    sw r0, 3(r2)
    ; frame[3] = dynamic link (current fp_vm)
    la r0, nonlocal_temps
    lw r0, 3(r0)
    sw r0, 6(r2)
    ; frame[6] = static link
    lw r0, 3(fp)
    sw r0, 9(r2)
    ; frame[9] = saved esp
    ; Advance csp by 12 (frame header size)
    add r2, 12
    sw r2, 6(fp)
    ; Set pc = target
    pop r0
    sw r0, 0(fp)
    la r0, vm_loop
    jmp (r0)

; 0x40 — enter nlocals8: set fp_vm = csp, reserve local slots
op_enter:
    ; fp = &vm_state
    ; Fetch nlocals byte
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = nlocals
    push r2
    ; Advance pc by 1
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; fp_vm = csp
    lw r0, 6(fp)
    sw r0, 9(fp)
    ; csp += nlocals * 3
    pop r2
    ; r2 = nlocals
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = nlocals * 3
    lw r2, 6(fp)
    add r2, r0
    sw r2, 6(fp)
    la r0, vm_loop
    jmp (r0)

; 0x41 — leave: discard locals (csp = fp_vm)
op_leave:
    ; fp = &vm_state
    lw r0, 9(fp)
    sw r0, 6(fp)
    ; csp = fp_vm
    la r0, vm_loop
    jmp (r0)

; ============================================================
; Local / Argument access opcode handlers (0x42, 0x43, 0x48, 0x49)
; ============================================================

; 0x42 — loadl off8: push local variable onto eval stack
; Address = fp_vm + offset * 3
op_loadl:
    ; fp = &vm_state
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = offset
    ; Advance pc by 1
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; Compute fp_vm + offset * 3
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = offset * 3
    lw r2, 9(fp)
    add r0, r2
    ; r0 = fp_vm + offset * 3
    lw r2, 0(r0)
    ; r2 = local value
    ; Push onto eval stack
    lw r0, 3(fp)
    sw r2, 0(r0)
    add r0, 3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x43 — storel off8: pop eval stack into local variable
op_storel:
    ; fp = &vm_state
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = offset
    ; Compute target: fp_vm + offset * 3
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = offset * 3
    lw r2, 9(fp)
    add r0, r2
    ; r0 = target address
    push r0
    ; Advance pc by 1
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; Pop value from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = value
    pop r2
    ; r2 = target address
    sw r0, 0(r2)
    la r0, vm_loop
    jmp (r0)

; 0x44 — loadg off24: load global at word offset, push onto eval stack
op_loadg:
    ; fp = &vm_state
    ; Read 3-byte offset from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lw r2, 0(r0)
    ; r2 = off24 (word index)
    ; Advance pc by 3
    lw r0, 0(fp)
    add r0, 3
    sw r0, 0(fp)
    ; Compute gp + offset * 3
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = offset * 3
    lw r2, 12(fp)
    add r0, r2
    ; r0 = gp + offset * 3
    lw r2, 0(r0)
    ; r2 = global value
    ; Push onto eval stack
    lw r0, 3(fp)
    sw r2, 0(r0)
    add r0, 3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x45 — storeg off24: pop eval stack, store to global at word offset
op_storeg:
    ; fp = &vm_state
    ; Read 3-byte offset from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lw r2, 0(r0)
    ; r2 = off24 (word index)
    ; Compute target: gp + offset * 3
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = offset * 3
    lw r2, 12(fp)
    add r0, r2
    ; r0 = target address
    push r0
    ; Advance pc by 3
    lw r0, 0(fp)
    add r0, 3
    sw r0, 0(fp)
    ; Pop value from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = value
    pop r2
    ; r2 = target address
    sw r0, 0(r2)
    la r0, vm_loop
    jmp (r0)

; 0x46 — addrl off8: push address of local onto eval stack
op_addrl:
    ; fp = &vm_state
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = offset
    ; Advance pc by 1
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; Compute fp_vm + offset * 3
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = offset * 3
    lw r2, 9(fp)
    add r0, r2
    ; r0 = address of local
    ; Push onto eval stack
    mov r2, r0
    lw r0, 3(fp)
    sw r2, 0(r0)
    add r0, 3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x47 — addrg off24: push address of global onto eval stack
op_addrg:
    ; fp = &vm_state
    ; Read 3-byte offset from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lw r2, 0(r0)
    ; r2 = off24 (word index)
    ; Advance pc by 3
    lw r0, 0(fp)
    add r0, 3
    sw r0, 0(fp)
    ; Compute gp + offset * 3
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = offset * 3
    lw r2, 12(fp)
    add r0, r2
    ; r0 = address of global
    ; Push onto eval stack
    mov r2, r0
    lw r0, 3(fp)
    sw r2, 0(r0)
    add r0, 3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x48 — loada idx8: push argument onto eval stack
; Args on eval stack below saved_esp: arg[idx] = saved_esp - (idx+1)*3
op_loada:
    ; fp = &vm_state
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = idx
    ; Advance pc by 1
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; Compute (idx + 1) * 3
    add r2, 1
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = (idx + 1) * 3
    ; Get saved_esp from frame (fp_vm - 3)
    lw r2, 9(fp)
    lw r2, -3(r2)
    ; r2 = saved_esp
    sub r2, r0
    ; r2 = arg address
    lw r0, 0(r2)
    ; r0 = arg value
    ; Push onto eval stack
    lw r2, 3(fp)
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x49 — storea idx8: pop eval stack into argument
op_storea:
    ; fp = &vm_state
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = idx
    ; Advance pc by 1
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; Compute (idx + 1) * 3
    add r2, 1
    mov r0, r2
    add r0, r0
    add r0, r2
    ; r0 = (idx + 1) * 3
    ; Get saved_esp from frame (fp_vm - 3)
    lw r2, 9(fp)
    lw r2, -3(r2)
    sub r2, r0
    ; r2 = arg address
    push r2
    ; Pop value from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = value
    pop r2
    sw r0, 0(r2)
    la r0, vm_loop
    jmp (r0)

; 0x4A — loadn depth8 off8: load nonlocal via static link chain
; Follow static link chain 'depth' times from current fp_vm,
; then load local[off] from the found frame.
; Static link is at fp_vm - 6 in each frame.
op_loadn:
    ; fp = &vm_state
    ; Fetch depth byte from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = depth
    la r0, nonlocal_temps
    sw r2, 0(r0)
    ; nonlocal_temps[0] = depth
    ; Fetch off byte from code[pc+1]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r2, 1
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = off
    la r0, nonlocal_temps
    sw r2, 3(r0)
    ; nonlocal_temps[3] = off
    ; Advance pc by 2
    lw r0, 0(fp)
    add r0, 2
    sw r0, 0(fp)
    ; Traverse static link chain: start at fp_vm
    lw r0, 9(fp)
    ; r0 = current frame pointer
    la r2, nonlocal_temps
    lw r1, 0(r2)
    ; r1 = depth
loadn_chain:
    ceq r1, z
    brt loadn_done
    ; Follow static link: frame_fp - 6
    lw r0, -6(r0)
    add r1, -1
    bra loadn_chain
loadn_done:
    ; r0 = target frame's fp_vm
    ; Compute target address: fp_vm + off * 3
    la r2, nonlocal_temps
    lw r2, 3(r2)
    ; r2 = off
    mov r1, r2
    add r1, r1
    add r1, r2
    ; r1 = off * 3
    add r0, r1
    ; r0 = target address
    lw r2, 0(r0)
    ; r2 = value
    ; Push onto eval stack
    lw r0, 3(fp)
    sw r2, 0(r0)
    add r0, 3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x4B — storen depth8 off8: store nonlocal via static link chain
; Follow static link chain 'depth' times from current fp_vm,
; then store eval stack TOS into local[off] of the found frame.
op_storen:
    ; fp = &vm_state
    ; Fetch depth byte from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = depth
    la r0, nonlocal_temps
    sw r2, 0(r0)
    ; nonlocal_temps[0] = depth
    ; Fetch off byte from code[pc+1]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r2, 1
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = off
    la r0, nonlocal_temps
    sw r2, 3(r0)
    ; nonlocal_temps[3] = off
    ; Advance pc by 2
    lw r0, 0(fp)
    add r0, 2
    sw r0, 0(fp)
    ; Pop value from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = value to store
    la r2, nonlocal_temps
    sw r0, 6(r2)
    ; nonlocal_temps[6] = value
    ; Traverse static link chain: start at fp_vm
    lw r0, 9(fp)
    ; r0 = current frame pointer
    la r2, nonlocal_temps
    lw r1, 0(r2)
    ; r1 = depth
storen_chain:
    ceq r1, z
    brt storen_done
    lw r0, -6(r0)
    add r1, -1
    bra storen_chain
storen_done:
    ; r0 = target frame's fp_vm
    ; Compute target address: fp_vm + off * 3
    la r2, nonlocal_temps
    lw r2, 3(r2)
    ; r2 = off
    mov r1, r2
    add r1, r1
    add r1, r2
    ; r1 = off * 3
    add r0, r1
    ; r0 = target address
    push r0
    ; Retrieve value from temp
    la r0, nonlocal_temps
    lw r0, 6(r0)
    ; r0 = value
    pop r2
    ; r2 = target address
    sw r0, 0(r2)
    la r0, vm_loop
    jmp (r0)

; ============================================================
; Indirect Memory Access opcode handlers (0x50-0x53)
; ============================================================

; 0x50 — load: ( addr -- val ) load word from address
op_load:
    ; fp = &vm_state
    ; Pop address from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = address — nil pointer check
    ceq r0, z
    brf load_not_nil
    lc r0, 6
    la r2, vm_trap
    jmp (r2)
load_not_nil:
    lw r2, 0(r0)
    ; r2 = value at address
    ; Push onto eval stack
    lw r0, 3(fp)
    sw r2, 0(r0)
    add r0, 3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x51 — store: ( val addr -- ) store word to address
op_store:
    ; fp = &vm_state
    ; Pop addr from eval stack
    lw r2, 3(fp)
    add r2, -3
    lw r0, 0(r2)
    ; r0 = addr — nil pointer check
    ceq r0, z
    brf store_not_nil
    lc r0, 6
    la r2, vm_trap
    jmp (r2)
store_not_nil:
    push r0
    ; Pop val from eval stack
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = val
    pop r2
    ; r2 = addr
    sw r0, 0(r2)
    la r0, vm_loop
    jmp (r0)

; 0x52 — loadb: ( addr -- byte ) load byte zero-extended
op_loadb:
    ; fp = &vm_state
    ; Pop address from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = address — nil pointer check
    ceq r0, z
    brf loadb_not_nil
    lc r0, 6
    la r2, vm_trap
    jmp (r2)
loadb_not_nil:
    lbu r2, 0(r0)
    ; r2 = byte (zero-extended)
    ; Push onto eval stack
    lw r0, 3(fp)
    sw r2, 0(r0)
    add r0, 3
    sw r0, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x53 — storeb: ( byte addr -- ) store byte to address
op_storeb:
    ; fp = &vm_state
    ; Pop addr from eval stack
    lw r2, 3(fp)
    add r2, -3
    lw r0, 0(r2)
    ; r0 = addr — nil pointer check
    ceq r0, z
    brf storeb_not_nil
    lc r0, 6
    la r2, vm_trap
    jmp (r2)
storeb_not_nil:
    push r0
    ; Pop byte from eval stack
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = byte value
    pop r2
    ; r2 = addr
    sb r0, 0(r2)
    la r0, vm_loop
    jmp (r0)

; 0x70 — memcpy: ( src dst len -- ) copy len bytes, memmove semantics
op_memcpy:
    ; fp = &vm_state
    lw r2, 3(fp)         ; r2 = esp
    lw r0, -3(r2)        ; r0 = len (TOS)
    ceq r0, z
    brf memcpy_nonzero
    ; len is 0, just pop 3 words from eval stack
    add r2, -9
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)
memcpy_nonzero:
    ; Save len to temp
    la r2, memcpy_len_tmp
    sw r0, 0(r2)
    ; Save dst to temp
    lw r2, 3(fp)
    lw r0, -6(r2)        ; r0 = dst
    la r2, memcpy_dst_tmp
    sw r0, 0(r2)
    ; Save src to temp
    lw r2, 3(fp)
    lw r0, -9(r2)        ; r0 = src
    la r2, memcpy_src_tmp
    sw r0, 0(r2)
    ; Update esp (pop 3 words)
    lw r2, 3(fp)
    add r2, -9
    sw r2, 3(fp)
    ; Direction check: if src < dst, copy backward
    ; r0 = src still
    la r2, memcpy_dst_tmp
    lw r2, 0(r2)         ; r2 = dst
    clu r0, r2            ; flag = (src < dst)
    brf memcpy_fwd_loop
    la r0, memcpy_bwd_setup
    jmp (r0)

memcpy_fwd_loop:
    ; Check len
    la r0, memcpy_len_tmp
    lw r2, 0(r0)
    ceq r2, z
    brf memcpy_fwd_step
    la r0, vm_loop
    jmp (r0)
memcpy_fwd_step:
    add r2, -1
    sw r2, 0(r0)         ; len--
    ; Load byte from src
    la r0, memcpy_src_tmp
    lw r0, 0(r0)         ; r0 = src
    lbu r2, 0(r0)        ; r2 = *src
    push r2               ; save byte
    add r0, 1
    la r2, memcpy_src_tmp
    sw r0, 0(r2)         ; src++
    ; Store byte to dst
    la r0, memcpy_dst_tmp
    lw r0, 0(r0)         ; r0 = dst
    pop r2                ; r2 = byte
    sb r2, 0(r0)          ; *dst = byte
    add r0, 1
    la r2, memcpy_dst_tmp
    sw r0, 0(r2)         ; dst++
    la r0, memcpy_fwd_loop
    jmp (r0)

memcpy_bwd_setup:
    ; Start from end: adjust src and dst to last byte
    la r0, memcpy_len_tmp
    lw r0, 0(r0)         ; r0 = len
    add r0, -1            ; r0 = len - 1
    push r0               ; save offset
    ; src += offset
    la r2, memcpy_src_tmp
    lw r2, 0(r2)         ; r2 = src
    add r2, r0            ; r2 = src + len - 1
    la r0, memcpy_src_tmp
    sw r2, 0(r0)         ; update src
    ; dst += offset
    pop r0                ; r0 = offset
    la r2, memcpy_dst_tmp
    lw r2, 0(r2)         ; r2 = dst
    add r2, r0            ; r2 = dst + len - 1
    la r0, memcpy_dst_tmp
    sw r2, 0(r0)         ; update dst
    la r0, memcpy_bwd_loop
    jmp (r0)

memcpy_bwd_loop:
    ; Check len
    la r0, memcpy_len_tmp
    lw r2, 0(r0)
    ceq r2, z
    brf memcpy_bwd_step
    la r0, vm_loop
    jmp (r0)
memcpy_bwd_step:
    add r2, -1
    sw r2, 0(r0)         ; len--
    ; Load byte from src (at end)
    la r0, memcpy_src_tmp
    lw r0, 0(r0)
    lbu r2, 0(r0)
    push r2
    add r0, -1
    la r2, memcpy_src_tmp
    sw r0, 0(r2)         ; src--
    ; Store byte to dst (at end)
    la r0, memcpy_dst_tmp
    lw r0, 0(r0)
    pop r2
    sb r2, 0(r0)
    add r0, -1
    la r2, memcpy_dst_tmp
    sw r0, 0(r2)         ; dst--
    la r0, memcpy_bwd_loop
    jmp (r0)

; Temporary storage for memcpy
memcpy_src_tmp:
    .word 0
memcpy_dst_tmp:
    .word 0
memcpy_len_tmp:
    .word 0

; 0x71 — memset: ( dst val len -- ) fill len bytes with val
op_memset:
    ; fp = &vm_state
    lw r2, 3(fp)         ; r2 = esp
    lw r0, -3(r2)        ; r0 = len (TOS)
    ceq r0, z
    brf memset_nonzero
    ; len is 0, just pop 3 words from eval stack
    add r2, -9
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)
memset_nonzero:
    ; Save len to temp
    la r2, memset_len_tmp
    sw r0, 0(r2)
    ; Save val to temp
    lw r2, 3(fp)
    lw r0, -6(r2)        ; r0 = val
    la r2, memset_val_tmp
    sw r0, 0(r2)
    ; Save dst to temp
    lw r2, 3(fp)
    lw r0, -9(r2)        ; r0 = dst
    la r2, memset_dst_tmp
    sw r0, 0(r2)
    ; Update esp (pop 3 words)
    lw r2, 3(fp)
    add r2, -9
    sw r2, 3(fp)
    la r0, memset_loop
    jmp (r0)

memset_loop:
    ; Check len
    la r0, memset_len_tmp
    lw r2, 0(r0)
    ceq r2, z
    brf memset_step
    la r0, vm_loop
    jmp (r0)
memset_step:
    add r2, -1
    sw r2, 0(r0)         ; len--
    ; Store val byte to dst
    la r0, memset_val_tmp
    lw r0, 0(r0)         ; r0 = val
    push r0               ; save val
    la r0, memset_dst_tmp
    lw r0, 0(r0)         ; r0 = dst
    pop r2                ; r2 = val
    sb r2, 0(r0)          ; *dst = val
    add r0, 1
    la r2, memset_dst_tmp
    sw r0, 0(r2)         ; dst++
    la r0, memset_loop
    jmp (r0)

; Temporary storage for memset
memset_dst_tmp:
    .word 0
memset_val_tmp:
    .word 0
memset_len_tmp:
    .word 0

; 0x72 — memcmp: ( a b len -- result )
; Compare len bytes at a and b lexicographically.
; Push 0 if equal, -1 if a<b, 1 if a>b.
op_memcmp:
    ; fp = &vm_state
    lw r2, 3(fp)         ; r2 = esp
    lw r0, -3(r2)        ; r0 = len (TOS)
    ceq r0, z
    brf memcmp_nonzero
    ; len is 0, pop 3 words, push 0 (equal)
    add r2, -9
    sw r2, 3(fp)
    ; push 0 result
    lw r2, 3(fp)
    lc r0, 0
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)
memcmp_nonzero:
    ; Save len to temp
    la r2, memcmp_len_tmp
    sw r0, 0(r2)
    ; Save b to temp
    lw r2, 3(fp)
    lw r0, -6(r2)        ; r0 = b
    la r2, memcmp_b_tmp
    sw r0, 0(r2)
    ; Save a to temp
    lw r2, 3(fp)
    lw r0, -9(r2)        ; r0 = a
    la r2, memcmp_a_tmp
    sw r0, 0(r2)
    ; Update esp (pop 3 words)
    lw r2, 3(fp)
    add r2, -9
    sw r2, 3(fp)
    la r0, memcmp_loop
    jmp (r0)

memcmp_loop:
    ; Check len
    la r0, memcmp_len_tmp
    lw r2, 0(r0)
    ceq r2, z
    brf memcmp_step
    ; All bytes equal — push 0
    lw r2, 3(fp)
    lc r0, 0
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)
memcmp_step:
    add r2, -1
    sw r2, 0(r0)         ; len--
    ; Load byte from a
    la r0, memcmp_a_tmp
    lw r0, 0(r0)         ; r0 = a ptr
    lbu r2, 0(r0)        ; r2 = *a
    push r2               ; save byte_a
    add r0, 1
    la r2, memcmp_a_tmp
    sw r0, 0(r2)         ; a++
    ; Load byte from b
    la r0, memcmp_b_tmp
    lw r0, 0(r0)         ; r0 = b ptr
    lbu r2, 0(r0)        ; r2 = *b
    push r2               ; save byte_b
    add r0, 1
    la r2, memcmp_b_tmp
    sw r0, 0(r2)         ; b++
    ; Compare: byte_b on top, byte_a below
    pop r2                ; r2 = byte_b
    pop r0                ; r0 = byte_a
    ceq r0, r2
    brf memcmp_loop       ; equal, continue
    ; Not equal — determine result
    clu r0, r2            ; flag = (byte_a < byte_b)
    brf memcmp_greater
    ; a < b: push -1 (0xFFFFFF in 24-bit)
    lw r2, 3(fp)
    la r0, -1
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)
memcmp_greater:
    ; a > b: push 1
    lw r2, 3(fp)
    lc r0, 1
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x75 — xloadg unit_id8 offset8: load global from another unit
; Computes: gp + (unit_table[unit_id].global_base + offset) * 3
; Pushes the value onto eval stack.
op_xloadg:
    ; fp = &vm_state
    ; Fetch unit_id and offset from code[pc]
    lw r0, 18(fp)           ; r0 = code base
    lw r2, 0(fp)            ; r2 = pc
    add r0, r2              ; r0 = &code[pc]
    lbu r2, 0(r0)           ; r2 = unit_id
    push r2
    lbu r2, 1(r0)           ; r2 = offset
    push r2
    ; Advance pc by 2
    lw r0, 0(fp)
    add r0, 2
    sw r0, 0(fp)
    ; Look up unit_table[unit_id].global_base
    ; unit_table entry is 9 bytes: base_addr(3) + global_base(3) + irt_off(3)
    ; Stack: [unit_id, offset]
    pop r0                   ; r0 = offset
    la r2, xcall_temps
    sw r0, 0(r2)            ; xcall_temps[0] = offset
    pop r0                   ; r0 = unit_id
    ; Compute unit_id * 9: *9 = *8 + *1, *8 = *2*2*2
    mov r2, r0              ; r2 = uid (saved)
    add r0, r0              ; r0 = uid*2
    add r0, r0              ; r0 = uid*4
    add r0, r0              ; r0 = uid*8
    add r0, r2              ; r0 = uid*9
    ; r0 = unit_id * 9
    lw r2, 36(fp)           ; r2 = unit_table_ptr
    add r0, r2              ; r0 = &unit_table[unit_id]
    ; Read global_base from entry offset 3
    push fp
    push r0
    pop fp
    lw r0, 3(fp)            ; r0 = global_base (word index)
    pop fp
    ; Compute (global_base + offset) * 3
    la r2, xcall_temps
    lw r2, 0(r2)            ; r2 = offset
    add r0, r2              ; r0 = global_base + offset
    ; Multiply by 3
    mov r2, r0
    add r0, r0
    add r0, r2              ; r0 = (global_base + offset) * 3
    ; Add gp base
    lw r2, 12(fp)           ; r2 = gp
    add r0, r2              ; r0 = absolute address
    ; Load value from that address
    push fp
    push r0
    pop fp
    lw r0, 0(fp)            ; r0 = value
    pop fp
    ; Push onto eval stack
    lw r2, 3(fp)            ; r2 = esp
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x76 — xstoreg unit_id8 offset8: store to global in another unit
; Pops value from eval stack, stores at gp + (unit_table[unit_id].global_base + offset) * 3
op_xstoreg:
    ; fp = &vm_state
    ; Fetch unit_id and offset from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)           ; r2 = unit_id
    push r2
    lbu r2, 1(r0)           ; r2 = offset
    push r2
    ; Advance pc by 2
    lw r0, 0(fp)
    add r0, 2
    sw r0, 0(fp)
    ; Pop value from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)            ; r0 = value to store
    la r2, xcall_temps
    sw r0, 3(r2)            ; xcall_temps[3] = value
    ; Compute target address (same as xloadg)
    pop r0                   ; r0 = offset
    la r2, xcall_temps
    sw r0, 0(r2)            ; xcall_temps[0] = offset
    pop r0                   ; r0 = unit_id
    ; unit_id * 9
    mov r2, r0
    add r0, r0
    add r0, r0
    add r0, r0              ; r0 = uid*8
    add r0, r2              ; r0 = uid*9
    lw r2, 36(fp)           ; r2 = unit_table_ptr
    add r0, r2              ; r0 = &unit_table[unit_id]
    push fp
    push r0
    pop fp
    lw r0, 3(fp)            ; r0 = global_base
    pop fp
    la r2, xcall_temps
    lw r2, 0(r2)            ; r2 = offset
    add r0, r2              ; r0 = global_base + offset
    mov r2, r0
    add r0, r0
    add r0, r2              ; r0 = (global_base + offset) * 3
    lw r2, 12(fp)           ; r2 = gp
    add r0, r2              ; r0 = absolute address
    ; Store value
    la r2, xcall_temps
    lw r2, 3(r2)            ; r2 = value
    push fp
    push r0
    pop fp
    sw r2, 0(fp)            ; mem[addr] = value
    pop fp
    la r0, vm_loop
    jmp (r0)

; Temporary storage for memcmp
memcmp_a_tmp:
    .word 0
memcmp_b_tmp:
    .word 0
memcmp_len_tmp:
    .word 0

; 0x73 — jmp_ind: ( addr -- )
; Jump to address on top of eval stack (indirect/computed jump).
op_jmp_ind:
    ; fp = &vm_state
    lw r2, 3(fp)         ; r2 = esp
    lw r0, -3(r2)        ; r0 = addr (TOS)
    ; Pop the address
    add r2, -3
    sw r2, 3(fp)
    ; Set pc = addr
    sw r0, 0(fp)
    la r0, vm_loop
    jmp (r0)

; 0x74 — xcall slot16: cross-unit procedure call via IRT
; Reads 16-bit slot index from code, looks up absolute target address
; from IRT[slot], builds call frame with caller unit_id in static_link
; high byte, then jumps to target.
; Encoding: [0x74, slot_lo, slot_hi] (3 bytes)
op_xcall:
    ; fp = &vm_state
    ; 1. Fetch slot_lo from code[pc]
    lw r0, 18(fp)           ; r0 = code base
    lw r2, 0(fp)            ; r2 = pc
    add r0, r2              ; r0 = &code[pc]
    lbu r2, 0(r0)           ; r2 = slot_lo
    push r2
    lbu r2, 1(r0)           ; r2 = slot_hi
    pop r0
    ; Combine: slot = slot_lo | (slot_hi << 8)
    push r0                  ; save slot_lo
    lc r0, 8
    shl r2, r0              ; r2 = slot_hi << 8
    pop r0
    or r0, r2               ; r0 = slot (16-bit)
    push r0                  ; save slot

    ; 2. Advance pc by 2 (skip slot operand), save as return_pc
    lw r0, 0(fp)
    add r0, 2
    la r2, xcall_temps
    sw r0, 0(r2)            ; xcall_temps[0] = return_pc

    ; 3. Look up IRT: target = mem[irt_base + slot * 3]
    ; COR24 stack: [slot]
    pop r0                   ; r0 = slot
    ; Compute slot * 3
    mov r2, r0
    add r0, r0
    add r0, r2              ; r0 = slot * 3
    ; Add irt_base
    lw r2, 27(fp)           ; r2 = irt_base
    add r0, r2              ; r0 = &IRT[slot]
    ; Read target address from IRT
    push fp
    push r0
    pop fp
    lw r0, 0(fp)            ; r0 = target_pc (absolute)
    pop fp
    la r2, xcall_temps
    sw r0, 3(r2)            ; xcall_temps[3] = target_pc

    ; 4. Build call frame on call stack
    lw r2, 6(fp)            ; r2 = csp
    ; frame[0] = return_pc
    la r0, xcall_temps
    lw r0, 0(r0)
    sw r0, 0(r2)
    ; frame[3] = dynamic_link (current fp_vm)
    lw r0, 9(fp)
    sw r0, 3(r2)
    ; frame[6] = static_link: encode caller unit_id in high byte
    ; static_link = (current_unit + 1) << 16
    ; The +1 ensures unit 0 also produces a nonzero high byte
    lbu r0, 33(fp)          ; r0 = current_unit
    add r0, 1               ; r0 = current_unit + 1
    lc r1, 16
    shl r0, r1              ; r0 = (current_unit + 1) << 16
    sw r0, 6(r2)
    ; frame[9] = saved_esp
    lw r0, 3(fp)
    sw r0, 9(r2)
    ; Advance csp by 12
    add r2, 12
    sw r2, 6(fp)

    ; 5. Set pc = target_pc
    la r0, xcall_temps
    lw r0, 3(r0)
    sw r0, 0(fp)

    ; 6. Jump to vm_loop
    la r0, vm_loop
    jmp (r0)

; 0x60 — sys id8: system call dispatch
; Uses sys_id_temp to preserve sys id across comparisons.
; All handlers expect fp = &vm_state on entry.
op_sys:
    ; fp = &vm_state from dispatch
    ; Fetch sys ID byte
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = sys id
    ; Increment pc
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; Save sys id to temp memory (so we can use both r0/r2 freely)
    push fp
    la r0, sys_id_temp
    push r0
    pop fp
    sw r2, 0(fp)
    pop fp
    ; fp = &vm_state again
    ; Dispatch: id == 0 (HALT)?
    mov r0, r2
    ceq r0, z
    brt sys_halt
    ; id == 1 (PUTC)?
    lc r2, 1
    ceq r0, r2
    brt sys_putc
    ; Reload sys id for further checks
    push fp
    la r0, sys_id_temp
    push r0
    pop fp
    lw r0, 0(fp)
    pop fp
    ; id == 2 (GETC)?
    lc r2, 2
    ceq r0, r2
    brt sys_getc_j
    ; Reload sys id
    push fp
    la r0, sys_id_temp
    push r0
    pop fp
    lw r0, 0(fp)
    pop fp
    ; id == 3 (LED)?
    lc r2, 3
    ceq r0, r2
    brt sys_led_j
    ; Reload sys id
    push fp
    la r0, sys_id_temp
    push r0
    pop fp
    lw r0, 0(fp)
    pop fp
    ; id == 4 (ALLOC)?
    lc r2, 4
    ceq r0, r2
    brt sys_alloc_j
    ; id == 5 (FREE)?
    lc r2, 5
    ceq r0, r2
    brt sys_free_j
    ; Reload sys id
    push fp
    la r0, sys_id_temp
    push r0
    pop fp
    lw r0, 0(fp)
    pop fp
    ; id == 6 (READ_SWITCH)?
    lc r2, 6
    ceq r0, r2
    brt sys_rdswitch_j
    ; id == 7 (SET_IRT_BASE)?
    lc r2, 7
    ceq r0, r2
    brt sys_set_irt_j
    ; id == 8 (DUMP_STATE)?
    lc r2, 8
    ceq r0, r2
    brt sys_dump_j
    ; Unknown sys id — trap
    la r0, op_invalid
    jmp (r0)

; Jump trampolines for far handlers
sys_getc_j:
    la r0, sys_getc
    jmp (r0)
sys_led_j:
    la r0, sys_led
    jmp (r0)
sys_alloc_j:
    la r0, sys_alloc
    jmp (r0)
sys_free_j:
    la r0, sys_free
    jmp (r0)
sys_rdswitch_j:
    la r0, sys_read_switch
    jmp (r0)
sys_set_irt_j:
    la r0, sys_set_irt_base
    jmp (r0)
sys_dump_j:
    la r0, sys_dump_state
    jmp (r0)

; sys HALT (id=0): stop VM execution
sys_halt:
    ; fp = &vm_state
    lc r0, 1
    sw r0, 21(fp)
    la r0, vm_loop
    jmp (r0)

; sys PUTC (id=1): pop char from eval stack, send to UART
sys_putc:
    ; fp = &vm_state
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    ; r2 = new esp = &TOS
    lw r0, 0(r2)
    ; r0 = char value
    push r0
    la r2, -65280
sys_putc_wait:
    lb r0, 1(r2)
    cls r0, z
    brt sys_putc_wait
    pop r0
    sb r0, 0(r2)
    la r0, vm_loop
    jmp (r0)

; sys GETC (id=2): read byte from UART, push onto eval stack
sys_getc:
    ; Poll UART status until RX ready (bit 0)
sys_getc_wait:
    la r2, -65280
    lbu r0, 1(r2)
    ; bit 0 = RX ready; mask it
    lc r2, 1
    and r0, r2
    ceq r0, z
    brt sys_getc_wait
    ; RX ready — read data byte
    la r2, -65280
    lbu r0, 0(r2)
    ; r0 = received byte; push onto eval stack
    la r2, vm_state
    push r2
    pop fp
    lw r2, 3(fp)
    ; r2 = esp
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; sys LED (id=3): pop state from eval stack, write to LED port
sys_led:
    ; fp = &vm_state
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    ; r2 = new esp = &TOS
    lw r0, 0(r2)
    ; r0 = LED state (1=on, 0=off from caller)
    ; Hardware is active-low: invert bit 0 before writing
    lc r2, 1
    xor r0, r2
    la r2, -65536
    sb r0, 0(r2)
    la r0, vm_loop
    jmp (r0)

; sys DUMP_STATE (id=8): print vm_state to UART for debugging
; Format: "VM: pc=NNNNNN esp=NNNNNN csp=NNNNNN fp=NNNNNN\n"
;         "    gp=NNNNNN hp=NNNNNN code=NNNNNN irt=NNNNNN u=NN\n"
sys_dump_state:
    la r0, vm_state
    push r0
    pop fp
    ; Line 1: "VM: pc="
    la r0, dump_s_vm
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 0(fp)            ; pc
    la r2, uart_put_hex24
    jal r1, (r2)
    ; " esp="
    la r0, dump_s_esp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 3(fp)            ; esp
    la r2, uart_put_hex24
    jal r1, (r2)
    ; " csp="
    la r0, dump_s_csp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 6(fp)            ; csp
    la r2, uart_put_hex24
    jal r1, (r2)
    ; " fp="
    la r0, dump_s_fp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 9(fp)            ; fp_vm
    la r2, uart_put_hex24
    jal r1, (r2)
    ; newline
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    ; Line 2: "    gp="
    la r0, dump_s_gp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 12(fp)           ; gp
    la r2, uart_put_hex24
    jal r1, (r2)
    ; " hp="
    la r0, dump_s_hp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 15(fp)           ; hp
    la r2, uart_put_hex24
    jal r1, (r2)
    ; " code="
    la r0, dump_s_code
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 18(fp)           ; code
    la r2, uart_put_hex24
    jal r1, (r2)
    ; " irt="
    la r0, dump_s_irt
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 27(fp)           ; irt_base
    la r2, uart_put_hex24
    jal r1, (r2)
    ; " u="
    la r0, dump_s_u
    la r2, uart_puts
    jal r1, (r2)
    lbu r0, 33(fp)          ; current_unit
    la r2, uart_put_hex8
    jal r1, (r2)
    ; newline
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    la r0, vm_loop
    jmp (r0)

; String constants for dump_state
dump_s_vm:
    .byte 86, 77, 58, 32, 112, 99, 61, 0
    ; "VM: pc=\0"
dump_s_esp:
    .byte 32, 101, 115, 112, 61, 0
    ; " esp=\0"
dump_s_csp:
    .byte 32, 99, 115, 112, 61, 0
    ; " csp=\0"
dump_s_fp:
    .byte 32, 102, 112, 61, 0
    ; " fp=\0"
dump_s_gp:
    .byte 32, 32, 32, 32, 103, 112, 61, 0
    ; "    gp=\0"
dump_s_hp:
    .byte 32, 104, 112, 61, 0
    ; " hp=\0"
dump_s_code:
    .byte 32, 99, 111, 100, 101, 61, 0
    ; " code=\0"
dump_s_irt:
    .byte 32, 105, 114, 116, 61, 0
    ; " irt=\0"
dump_s_u:
    .byte 32, 117, 61, 0
    ; " u=\0"

; sys SET_IRT_BASE (id=7): pop address, set vm_state.irt_base
sys_set_irt_base:
    la r0, vm_state
    push r0
    pop fp
    ; Pop address from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)           ; esp -= 3
    lw r0, 0(r2)           ; r0 = address (TOS)
    sw r0, 27(fp)          ; irt_base = address
    la r0, vm_loop
    jmp (r0)

; sys READ_SWITCH (id=6): read switch state, push onto eval stack
sys_read_switch:
    la r0, vm_state
    push r0
    pop fp
    ; Read switch register (bit 0 = button S2)
    la r2, -65536
    lbu r0, 0(r2)
    lc r2, 1
    and r0, r2
    ; Hardware is active-low: invert bit 0 so 1=pressed, 0=not pressed
    lc r2, 1
    xor r0, r2
    ; Push result onto eval stack
    lw r2, 3(fp)
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; sys ALLOC (id=4): pop size, bump-allocate, push pointer
; Uses nonlocal_temps as scratch: [0]=size, [3]=old hp (return ptr)
sys_alloc:
    la r0, vm_state
    push r0
    pop fp
    ; Pop size from eval stack
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    lw r0, 0(r2)
    ; r0 = size
    ; Save size to nonlocal_temps[0]
    la r2, nonlocal_temps
    push r2
    pop fp
    sw r0, 0(fp)
    ; Load current hp and save as return pointer to nonlocal_temps[3]
    la r0, vm_state
    push r0
    pop fp
    lw r0, 15(fp)
    ; r0 = old hp (allocated pointer)
    la r2, nonlocal_temps
    push r2
    pop fp
    sw r0, 3(fp)
    ; Compute new hp = old_hp + size
    lw r2, 0(fp)
    ; r2 = size
    add r0, r2
    ; r0 = new hp
    ; Heap overflow check: new hp must be < heap_limit
    push r0
    la r2, heap_limit
    push r2
    pop fp
    lw r2, 0(fp)
    pop r0
    clu r0, r2
    brt alloc_no_overflow
    lc r0, 5
    la r2, vm_trap
    jmp (r2)
alloc_no_overflow:
    ; Store new hp to vm_state.hp
    la r2, vm_state
    push r2
    pop fp
    sw r0, 15(fp)
    ; Push old hp (allocated pointer) onto eval stack
    la r2, nonlocal_temps
    push r2
    pop fp
    lw r0, 3(fp)
    ; r0 = allocated pointer
    la r2, vm_state
    push r2
    pop fp
    lw r2, 3(fp)
    ; r2 = esp
    sw r0, 0(r2)
    add r2, 3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; sys FREE (id=5): pop ptr, no-op (bump allocator doesn't free)
sys_free:
    la r0, vm_state
    push r0
    pop fp
    ; Pop ptr from eval stack and discard
    lw r2, 3(fp)
    add r2, -3
    sw r2, 3(fp)
    la r0, vm_loop
    jmp (r0)

; 0x36 — trap code8: trigger trap with explicit code
op_trap:
    ; fp = &vm_state from dispatch
    ; Fetch trap code byte from code[pc]
    lw r0, 18(fp)
    lw r2, 0(fp)
    add r0, r2
    lbu r2, 0(r0)
    ; r2 = trap code
    ; Increment pc past operand
    lw r0, 0(fp)
    add r0, 1
    sw r0, 0(fp)
    ; Trigger trap
    mov r0, r2
    la r2, vm_trap
    jmp (r2)

; Invalid opcode: trap code 4 (INVALID_OPCODE)
op_invalid:
    lc r0, 4
    la r2, vm_trap
    jmp (r2)

; Stub handler — all unimplemented opcodes trap as invalid
op_stub:
    la r0, op_invalid
    jmp (r0)

; ============================================================
; Dispatch table (116 entries: opcodes 0x00 through 0x73)
; Each entry is a .word (3 bytes) holding the handler address
; ============================================================
dispatch_table:
    ; 0x00-0x06: Stack / Constants
    .word op_halt
    .word op_push
    .word op_push_s
    .word op_dup
    .word op_drop
    .word op_swap
    .word op_over
    ; 0x07-0x0F: reserved (gap)
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    ; 0x10-0x1B: Arithmetic / Logic
    .word op_add
    .word op_sub
    .word op_mul
    .word op_div
    .word op_mod
    .word op_neg
    .word op_and
    .word op_or
    .word op_xor
    .word op_not
    .word op_shl
    .word op_shr
    ; 0x1C-0x1F: reserved (gap)
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    ; 0x20-0x25: Comparison
    .word op_eq
    .word op_ne
    .word op_lt
    .word op_le
    .word op_gt
    .word op_ge
    ; 0x26-0x2F: reserved (gap)
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    ; 0x30-0x35: Control Flow
    .word op_jmp
    .word op_jz
    .word op_jnz
    .word op_call
    .word op_ret
    .word op_calln
    ; 0x36: trap
    .word op_trap
    ; 0x37-0x3F: reserved (gap)
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    ; 0x40-0x4B: Local / Global / Nonlocal Access
    .word op_enter
    .word op_leave
    .word op_loadl
    .word op_storel
    .word op_loadg
    .word op_storeg
    .word op_addrl
    .word op_addrg
    .word op_loada
    .word op_storea
    .word op_loadn
    .word op_storen
    ; 0x4C-0x4F: reserved (gap)
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    ; 0x50-0x53: Indirect Memory Access
    .word op_load
    .word op_store
    .word op_loadb
    .word op_storeb
    ; 0x54-0x5F: reserved (gap)
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    ; 0x60: sys
    .word op_sys
    ; 0x61-0x6F: reserved (gap)
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    .word op_invalid
    ; 0x70-0x72: Memory block operations
    .word op_memcpy
    .word op_memset
    .word op_memcmp
    ; 0x73: Indirect jump
    .word op_jmp_ind
    ; 0x74: Cross-unit call
    .word op_xcall
    ; 0x75-0x76: Cross-unit global access
    .word op_xloadg
    .word op_xstoreg

; ============================================================
; String constants
; ============================================================
msg_boot:
    .byte 80, 86, 77, 32, 79, 75, 10, 0
    ; "PVM OK\n\0"

msg_halted:
    .byte 72, 65, 76, 84, 10, 0
    ; "HALT\n\0"

msg_trap_prefix:
    .byte 84, 82, 65, 80, 32, 0
    ; "TRAP \0" (space, no newline — code digit and \n printed separately)

; ============================================================
; Temporary storage for ret handler (4 words = 12 bytes)
; ============================================================
ret_temps:
    .word 0
    ; [0] nargs * 3
    .word 0
    ; [3] saved_esp
    .word 0
    ; [6] retval
    .word 0
    ; [9] has_rv flag
    .word 0
    ; [12] static_link (for cross-unit return detection)

; ============================================================
; Temporary storage for nonlocal handlers (3 words = 9 bytes)
; ============================================================
; Temporary storage for sys dispatch (1 word = 3 bytes)
sys_id_temp:
    .word 0

nonlocal_temps:
    .word 0
    ; [0] depth
    .word 0
    ; [3] off (or static link for calln)
    .word 0
    ; [6] value (for storen)

; Temporary storage for .p24m header parsing (2 words = 6 bytes)
p24m_temps:
    .word 0
    ; [0] entry_point
    .word 0
    ; [3] base address

; Temporary storage for xcall handler (2 words = 6 bytes)
xcall_temps:
    .word 0
    ; [0] return_pc
    .word 0
    ; [3] target_pc

; ============================================================
; VM state struct (14 words = 42 bytes)
; ============================================================
vm_state:
    .word 0
    ; pc (offset 0)
    .word 0
    ; esp (offset 3)
    .word 0
    ; csp (offset 6)
    .word 0
    ; fp_vm (offset 9)
    .word 0
    ; gp (offset 12)
    .word 0
    ; hp (offset 15)
    .word 0
    ; code (offset 18)
    .word 0
    ; status (offset 21)
    .word 0
    ; trap_code (offset 24)
    .word 0
    ; irt_base (offset 27) — base address of import resolution table
    .word 0
    ; unit_count (offset 30) — number of loaded units (low byte)
    .word 0
    ; current_unit (offset 33) — currently executing unit ID (low byte)
    .word 0
    ; unit_table_ptr (offset 36) — absolute address of unit table
    .word 0
    ; p24m_base (offset 39) — base address of loaded .p24m image (0 if none)

; ============================================================
; Memory segments
; ============================================================

; Test bytecode: trap handling
; Expected UART output: PVM OK\nOK\nTRAP 0\n
;
; Test 1: Print "OK\n" to confirm VM is running, then trigger user trap
;
;  0: push_s 79      02, 79        ; 'O'
;  2: sys 1          96, 1         ; PUTC
;  4: push_s 75      02, 75        ; 'K'
;  6: sys 1          96, 1         ; PUTC
;  8: push_s 10      02, 10        ; '\n'
; 10: sys 1          96, 1         ; PUTC
; 12: trap 0         54, 0         ; USER_TRAP (code 0)
; 14: sys 0          96, 0         ; HALT (should not reach here)
;
; Other trap tests (change bytecode to test each):
; code_ptr — indirection for code segment base address.
; Default: points to built-in code_seg.
; For external .p24: patch this word to the load address (e.g., 0x010000)
; using --load-binary or --patch before execution starts.
code_ptr:
    .word code_seg

; vm_flags — patchable flags byte controlling VM behavior.
; Set via: --patch <addr_of_vm_flags>=<value>
; Bit 0: verbose boot — print memory map after .p24m/.p24 loading
; Bit 1: (reserved for trace mode — not yet implemented)
; Default: 0 (no flags set)
vm_flags:
    .byte 0

; heap_limit — patchable word: heap allocation ceiling.
; Default: 0x00F000 (~40KB usable heap above heap_seg).
; The heap uses bare SRAM — no pre-allocated data needed.
; For .p24m images loaded at 0x010000, leaves a 4KB guard gap.
; Patch higher for more heap, or lower to restrict.
; sys ALLOC traps (TRAP 5) when hp >= this value.
; Set via: --patch <addr_of_heap_limit>=<value>
heap_limit:
    .word 0x00F000

;   DIV_ZERO:       push_s 1, push_s 0, div  → TRAP 1
;   STACK_OVERFLOW: (fill stack past limit)   → TRAP 2
;   STACK_UNDERFLOW: drop (on empty stack)    → TRAP 3
;   INVALID_OPCODE: .byte 0xFF               → TRAP 4
;   HEAP_OVERFLOW:  sys ALLOC past heap_limit → TRAP 5
;   NIL_POINTER:    push_s 0, load           → TRAP 6
code_seg:
    ; Print "OK\n"
    .byte 2, 79
    .byte 96, 1
    .byte 2, 75
    .byte 96, 1
    .byte 2, 10
    .byte 96, 1
    ; trap 0 (USER_TRAP) — opcode 0x36 = 54 decimal
    .byte 54, 0
    ; HALT (unreachable)
    .byte 96, 0

; Globals segment (512 words = 1536 bytes)
; Sized for programs with arrays (e.g., BASIC interpreter needs ~500 globals).
; For .p24m images, globals are in the image itself (this is unused).
globals_seg:
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    ; 48 lines × 32 bytes = 1536 bytes = 512 words

; Call stack (grows upward, 1536 bytes for nested/recursive frames)
call_stack:
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    ; 48 lines x 32 bytes = 1536 bytes = 512 words

; Eval stack (grows upward, 1536 bytes)
eval_stack:
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    ; 48 lines x 32 bytes = 1536 bytes = 512 words

; Heap (bump-allocated upward from heap_seg toward heap_limit)
; No pre-allocated data — uses available SRAM between here and heap_limit.
; Default heap_limit is 0x00F000 (~40KB usable heap for typical layouts).
; For .p24m images loaded at 0x010000, this leaves a 4KB guard gap.
; Patch heap_limit for more/less heap as needed.
heap_seg:
