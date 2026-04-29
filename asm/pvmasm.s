; pvmasm.s — P-Code Assembler + VM for COR24
;
; Integrated assembler and virtual machine:
;   1. Read .spc source from UART
;   2. Two-pass assembly to bytecode (code+data contiguous in code_buf)
;   3. Execute assembled bytecode in the p-code VM
;
; Assembly phases:
;   Pass 1: collect symbols (labels, procs, consts, globals, data), compute sizes
;   Pass 2: emit bytecode, resolve symbol references
;
; Token types:
;   0 = TOK_EOF     end of input
;   1 = TOK_NL      newline
;   2 = TOK_NUM     integer literal (value in tok_value)
;   3 = TOK_IDENT   identifier/mnemonic/name (string in tok_buf)
;   4 = TOK_DIR     directive without '.' (string in tok_buf)
;   5 = TOK_LABEL   label definition without ':' (string in tok_buf)
;   6 = TOK_COMMA   comma separator
;
; Symbol types:
;   0 = SYM_CONST   named constant (value = literal)
;   1 = SYM_LABEL   code label (value = code offset)
;   2 = SYM_PROC    procedure entry (value = code offset)
;   3 = SYM_GLOBAL  global variable (value = global segment offset)
;   4 = SYM_DATA    data block (value = data segment offset)
;
; Operand types (mnemonic table):
;   0 = NONE    1-byte instruction
;   1 = IMM8    2-byte: opcode + byte
;   2 = IMM24   4-byte: opcode + word
;   3 = D8_A24  5-byte: opcode + byte + word (calln)
;   4 = D8_O8   3-byte: opcode + byte + byte (loadn/storen)
;
; Register allocation:
;   r0 = work/scratch, parameter, return value
;   r1 = return address (jal) or scratch
;   r2 = scratch, function address for jal
;   fp = memory base for indexed loads/stores
;   sp = COR24 hardware stack (EBR)
;
; UART: data at -65280 (0xFF0100), status at -65279 (0xFF0101)
;   TX busy = status bit 7 (sign bit via lb sign-extend)
;   RX ready = status bit 0

; ============================================================
; Entry point
; ============================================================
_start:
    ; Print boot message
    la r0, msg_boot
    la r2, uart_puts
    jal r1, (r2)

    ; Read all UART input into input_buf
    la r2, read_all_input
    jal r1, (r2)

    ; ---- Pass 1: collect symbols, compute sizes ----
    lc r0, 0
    la r2, input_pos
    sw r0, 0(r2)
    ; Prime first character
    la r2, lex_advance
    jal r1, (r2)
    ; Set pass number = 1
    lc r0, 1
    la r2, pass_num
    sb r0, 0(r2)
    ; Reset counters
    lc r0, 0
    la r2, code_addr
    sw r0, 0(r2)
    la r2, global_offset
    sw r0, 0(r2)
    la r2, data_offset
    sw r0, 0(r2)
    la r2, sym_count
    sw r0, 0(r2)
    ; Initialize name_pool_ptr
    la r0, name_pool
    la r2, name_pool_ptr
    sw r0, 0(r2)
    ; Run pass 1
    la r2, parse_program
    jal r1, (r2)

    ; Save code size after pass 1
    la r2, code_addr
    lw r0, 0(r2)
    la r2, code_size
    sw r0, 0(r2)
    ; Save data size
    la r2, data_offset
    lw r0, 0(r2)
    la r2, total_data_size
    sw r0, 0(r2)

    ; Patch data and global symbols with absolute offsets
    la r2, patch_symbols
    jal r1, (r2)

    ; ---- Pass 2: emit bytecode ----
    lc r0, 0
    la r2, input_pos
    sw r0, 0(r2)
    ; Prime first character
    la r2, lex_advance
    jal r1, (r2)
    ; Set pass number = 2
    lc r0, 2
    la r2, pass_num
    sb r0, 0(r2)
    ; Initialize code output pointer
    la r0, code_buf
    la r2, code_ptr
    sw r0, 0(r2)
    ; Initialize data output pointer = code_buf + code_size (contiguous)
    la r0, code_buf
    push r0
    la r2, code_size
    lw r0, 0(r2)
    pop r2
    add r0, r2
    la r2, data_ptr
    sw r0, 0(r2)
    ; Run pass 2
    la r2, parse_program
    jal r1, (r2)

    ; ---- Dump bytecode for verification ----
    la r2, dump_bytecode
    jal r1, (r2)

    ; ---- Initialize VM and execute assembled bytecode ----
    la r0, msg_vm_boot
    la r2, uart_puts
    jal r1, (r2)

    ; Set up vm_state (fp = &vm_state)
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

    ; fp_vm = 0
    lc r0, 0
    sw r0, 9(fp)

    ; gp = globals_seg
    la r0, globals_seg
    sw r0, 12(fp)

    ; hp = heap_seg
    la r0, heap_seg
    sw r0, 15(fp)

    ; code = code_buf (assembled bytecode)
    la r0, code_buf
    sw r0, 18(fp)

    ; status = 0 (running)
    lc r0, 0
    sw r0, 21(fp)

    ; trap_code = 0
    lc r0, 0
    sw r0, 24(fp)

    ; Enter VM main loop
    la r0, vm_loop
    jmp (r0)

; ============================================================
; UART helpers
; ============================================================

; uart_put_hex24 — print 24-bit value in r0 as 6 hex digits
; Non-leaf. Clobbers: r0, r1, r2.
uart_put_hex24:
    push r1
    la r2, hex_temp
    sw r0, 0(r2)
    lc r2, 16
    sra r0, r2
    lcu r2, 0xFF
    and r0, r2
    la r2, uart_put_hex8
    jal r1, (r2)
    la r0, hex_temp
    lw r0, 0(r0)
    lc r2, 8
    sra r0, r2
    lcu r2, 0xFF
    and r0, r2
    la r2, uart_put_hex8
    jal r1, (r2)
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
    lc r2, 4
    sra r0, r2
    lc r2, 0x0F
    and r0, r2
    la r2, uart_put_nybble
    jal r1, (r2)
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
    clu r0, r2
    brt hex_digit_num
    add r0, -10
    add r0, 65
    bra hex_digit_out
hex_digit_num:
    add r0, 48
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
; Leaf function. Clobbers: r0, r2. Preserves: r1.
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
; Non-leaf. Clobbers: r0, r1, r2.
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
; read_all_input — read UART into input_buf until EOT (0x04)
; ============================================================
; Non-leaf. Clobbers: r0, r1, r2.
read_all_input:
    push r1
    ; Initialize write pointer and length
    la r0, input_buf
    la r2, rai_ptr
    sw r0, 0(r2)
    lc r0, 0
    la r2, input_len
    sw r0, 0(r2)

rai_loop:
    ; Poll UART RX ready
    la r2, -65280
rai_poll:
    lbu r0, 1(r2)
    push r2
    lc r2, 1
    and r0, r2
    pop r2
    ceq r0, z
    brt rai_poll
    ; Read byte
    lbu r0, 0(r2)
    ; Check for EOT (0x04)
    lc r2, 4
    ceq r0, r2
    brf rai_not_eot
    la r0, rai_done
    jmp (r0)
rai_not_eot:
    ; Store byte in buffer
    la r2, rai_ptr
    lw r2, 0(r2)
    sb r0, 0(r2)
    ; Advance pointer
    la r2, rai_ptr
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    ; Increment length
    la r2, input_len
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    bra rai_loop

rai_done:
    ; Null-terminate buffer
    la r2, rai_ptr
    lw r2, 0(r2)
    lc r0, 0
    sb r0, 0(r2)
    pop r1
    jmp (r1)

; ============================================================
; Lexer — character input (buffer-based)
; ============================================================

; lex_advance — read next character from input_buf
; If past end, sets lex_char = 0 (EOF).
; Leaf function. Clobbers: r0, r2. Preserves: r1.
lex_advance:
    la r2, input_pos
    lw r0, 0(r2)
    ; Save position for comparison
    push r0
    la r2, input_len
    lw r2, 0(r2)
    pop r0
    clu r0, r2
    brf lex_adv_eof
    ; Read byte from input_buf[position]
    la r2, input_buf
    add r2, r0
    lbu r0, 0(r2)
    ; Advance position
    push r0
    la r2, input_pos
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    pop r0
    ; Store in lex_char
    la r2, lex_char
    sb r0, 0(r2)
    jmp (r1)
lex_adv_eof:
    lc r0, 0
    la r2, lex_char
    sb r0, 0(r2)
    jmp (r1)

; ============================================================
; Lexer — tokenizer
; ============================================================

; next_token — consume input and produce the next token
; Sets tok_type, tok_buf/tok_len (for string tokens), tok_value (for numbers).
; Non-leaf. Clobbers: r0, r1, r2, fp.
next_token:
    push r1

    ; Skip spaces (32) and tabs (9)
nt_skip_ws:
    la r2, lex_char
    lbu r0, 0(r2)
    lc r2, 32
    ceq r0, r2
    brt nt_is_ws
    lc r2, 9
    ceq r0, r2
    brt nt_is_ws
    bra nt_classify

nt_is_ws:
    la r2, lex_advance
    jal r1, (r2)
    bra nt_skip_ws

    ; ---- Character classification ----
    ; Uses inverted-branch + far-jump pattern to avoid branch range issues.

nt_classify:
    ; r0 = current char (non-space, non-tab)

    ; EOF (char == 0)
    ceq r0, z
    brf nt_not_eof
    la r0, nt_eof
    jmp (r0)
nt_not_eof:

    ; Newline (char == 10)
    lc r2, 10
    ceq r0, r2
    brf nt_not_nl
    la r0, nt_newline
    jmp (r0)
nt_not_nl:

    ; Carriage return (char == 13) — skip silently
    lc r2, 13
    ceq r0, r2
    brf nt_not_cr
    la r0, nt_cr
    jmp (r0)
nt_not_cr:

    ; Comment (char == ';' = 59)
    lc r2, 59
    ceq r0, r2
    brf nt_not_cmt
    la r0, nt_comment
    jmp (r0)
nt_not_cmt:

    ; Comma (char == ',' = 44)
    lc r2, 44
    ceq r0, r2
    brf nt_not_comma
    la r0, nt_comma
    jmp (r0)
nt_not_comma:

    ; Directive (char == '.' = 46)
    lc r2, 46
    ceq r0, r2
    brf nt_not_dir
    la r0, nt_directive
    jmp (r0)
nt_not_dir:

    ; Negative sign (char == '-' = 45) → number
    lc r2, 45
    ceq r0, r2
    brf nt_not_neg
    la r0, nt_number
    jmp (r0)
nt_not_neg:

    ; Digit check: '0'(48) <= r0 <= '9'(57)
    lc r2, 48
    clu r0, r2
    brt nt_check_alpha
    lc r2, 58
    clu r0, r2
    brf nt_check_alpha
    la r0, nt_number
    jmp (r0)

nt_check_alpha:
    ; Underscore (95)
    lc r2, 95
    ceq r0, r2
    brf nt_not_under
    la r0, nt_ident
    jmp (r0)
nt_not_under:

    ; Uppercase: 'A'(65) to 'Z'(90)
    lc r2, 65
    clu r0, r2
    brt nt_not_upper
    lc r2, 91
    clu r0, r2
    brf nt_not_upper
    la r0, nt_ident
    jmp (r0)
nt_not_upper:

    ; Lowercase: 'a'(97) to 'z'(122)
    lc r2, 97
    clu r0, r2
    brt nt_do_skip
    lc r2, 123
    clu r0, r2
    brf nt_do_skip
    la r0, nt_ident
    jmp (r0)

nt_do_skip:
    ; Unknown character — skip and retry
    la r2, lex_advance
    jal r1, (r2)
    la r0, nt_skip_ws
    jmp (r0)

; ---- Token handlers ----

nt_eof:
    la r2, tok_type
    lc r0, 0
    sb r0, 0(r2)
    pop r1
    jmp (r1)

nt_newline:
    ; Advance past \n
    la r2, lex_advance
    jal r1, (r2)
    la r2, tok_type
    lc r0, 1
    sb r0, 0(r2)
    pop r1
    jmp (r1)

nt_cr:
    ; Skip \r, continue scanning
    la r2, lex_advance
    jal r1, (r2)
    la r0, nt_skip_ws
    jmp (r0)

nt_comment:
    ; Skip to end of line or EOF
nt_cmt_loop:
    la r2, lex_advance
    jal r1, (r2)
    la r2, lex_char
    lbu r0, 0(r2)
    ; EOF?
    ceq r0, z
    brf nt_cmt_not_eof
    la r0, nt_eof
    jmp (r0)
nt_cmt_not_eof:
    ; Newline?
    lc r2, 10
    ceq r0, r2
    brf nt_cmt_loop
    ; Found \n — produce newline token
    la r0, nt_newline
    jmp (r0)

nt_comma:
    la r2, lex_advance
    jal r1, (r2)
    la r2, tok_type
    lc r0, 6
    sb r0, 0(r2)
    pop r1
    jmp (r1)

nt_directive:
    ; Advance past '.'
    la r2, lex_advance
    jal r1, (r2)
    ; Read directive name into tok_buf
    la r2, read_name
    jal r1, (r2)
    ; Set tok_type = 4 (TOK_DIR)
    la r2, tok_type
    lc r0, 4
    sb r0, 0(r2)
    pop r1
    jmp (r1)

nt_number:
    ; Parse number (starts with '-' or digit)
    la r2, parse_number
    jal r1, (r2)
    ; tok_type and tok_value set by parse_number
    pop r1
    jmp (r1)

nt_ident:
    ; Read name into tok_buf
    la r2, read_name
    jal r1, (r2)
    ; Check if followed by ':' (label definition)
    la r2, lex_char
    lbu r0, 0(r2)
    lc r2, 58
    ceq r0, r2
    brf nt_ident_done
    ; Label: consume ':'
    la r2, lex_advance
    jal r1, (r2)
    la r2, tok_type
    lc r0, 5
    sb r0, 0(r2)
    pop r1
    jmp (r1)
nt_ident_done:
    la r2, tok_type
    lc r0, 3
    sb r0, 0(r2)
    pop r1
    jmp (r1)

; ============================================================
; read_name — read alphanumeric/underscore chars into tok_buf
; ============================================================
; Precondition: lex_char is first char of name (alpha or underscore)
; Postcondition: tok_buf filled and null-terminated, tok_len set
; Non-leaf. Clobbers: r0, r1, r2, fp.
read_name:
    push r1
    ; Initialize write pointer
    la r0, tok_buf
    la r2, tok_ptr
    sw r0, 0(r2)

rn_loop:
    la r2, lex_char
    lbu r0, 0(r2)

    ; Check underscore (95)
    lc r2, 95
    ceq r0, r2
    brt rn_store

    ; Check digit: 48 <= r0 <= 57
    lc r2, 48
    clu r0, r2
    brt rn_not_digit
    lc r2, 58
    clu r0, r2
    brt rn_store
rn_not_digit:

    ; Check uppercase: 65 <= r0 <= 90
    lc r2, 65
    clu r0, r2
    brt rn_done
    lc r2, 91
    clu r0, r2
    brt rn_store

    ; Check lowercase: 97 <= r0 <= 122
    lc r2, 97
    clu r0, r2
    brt rn_done
    lc r2, 123
    clu r0, r2
    brf rn_done
    ; Fall through: is lowercase letter

rn_store:
    ; Store char at tok_ptr, advance ptr
    la r2, tok_ptr
    push r2
    pop fp
    lw r2, 0(fp)
    sb r0, 0(r2)
    add r2, 1
    sw r2, 0(fp)
    ; Advance lexer
    la r2, lex_advance
    jal r1, (r2)
    la r0, rn_loop
    jmp (r0)

rn_done:
    ; Null-terminate tok_buf
    la r2, tok_ptr
    lw r2, 0(r2)
    lc r0, 0
    sb r0, 0(r2)
    ; Calculate length: end - tok_buf
    la r0, tok_buf
    sub r2, r0
    ; Store tok_len
    la r0, tok_len
    sb r2, 0(r0)
    pop r1
    jmp (r1)

; ============================================================
; parse_number — parse decimal integer from UART input
; ============================================================
; Precondition: lex_char is first char ('-' or digit)
; Postcondition: tok_type = 2 (TOK_NUM), tok_value = parsed value
; Non-leaf. Clobbers: r0, r1, r2, fp.
parse_number:
    push r1
    ; Check for negative sign
    la r2, lex_char
    lbu r0, 0(r2)
    lc r2, 45
    ceq r0, r2
    brf pn_positive
    ; Negative: set flag, advance past '-'
    lc r0, 1
    la r2, num_neg
    sb r0, 0(r2)
    la r2, lex_advance
    jal r1, (r2)
    bra pn_start
pn_positive:
    lc r0, 0
    la r2, num_neg
    sb r0, 0(r2)
pn_start:
    ; Initialize accumulator to 0
    lc r0, 0
    la r2, tok_value
    sw r0, 0(r2)

pn_loop:
    ; Get current char
    la r2, lex_char
    lbu r0, 0(r2)
    ; Check if digit: 48 <= r0 <= 57
    lc r2, 48
    clu r0, r2
    brt pn_loop_done
    lc r2, 58
    clu r0, r2
    brf pn_loop_done
    ; Convert digit char to value
    add r0, -48
    ; acc = acc * 10 + digit
    push r0
    la r2, tok_value
    lw r0, 0(r2)
    lc r2, 10
    mul r0, r2
    pop r2
    add r0, r2
    la r2, tok_value
    sw r0, 0(r2)
    ; Advance lexer
    la r2, lex_advance
    jal r1, (r2)
    bra pn_loop

pn_loop_done:
    ; Check negative flag
    la r2, num_neg
    lbu r0, 0(r2)
    ceq r0, z
    brt pn_set_type
    ; Negate tok_value
    la r0, tok_value
    push r0
    pop fp
    lw r0, 0(fp)
    lc r2, 0
    sub r2, r0
    sw r2, 0(fp)

pn_set_type:
    la r2, tok_type
    lc r0, 2
    sb r0, 0(r2)
    pop r1
    jmp (r1)

; ============================================================
; Parser — main program loop
; ============================================================

; parse_program — parse all tokens, dispatching by type
; Shared by pass 1 and pass 2 (behavior differs based on pass_num).
; Non-leaf. Clobbers: r0, r1, r2, fp.
parse_program:
    push r1

pp_loop:
    ; Get next token
    la r2, next_token
    jal r1, (r2)

    ; Load token type
    la r2, tok_type
    lbu r0, 0(r2)

    ; EOF → done
    ceq r0, z
    brf pp_not_eof
    pop r1
    jmp (r1)
pp_not_eof:

    ; NL → skip
    lc r2, 1
    ceq r0, r2
    brf pp_not_nl
    la r0, pp_loop
    jmp (r0)
pp_not_nl:

    ; COMMA → skip
    lc r2, 6
    ceq r0, r2
    brf pp_not_comma
    la r0, pp_loop
    jmp (r0)
pp_not_comma:

    ; DIR (4) → handle directive
    lc r2, 4
    ceq r0, r2
    brf pp_not_dir
    la r2, handle_dir
    jal r1, (r2)
    la r0, pp_loop
    jmp (r0)
pp_not_dir:

    ; LABEL (5) → handle label
    lc r2, 5
    ceq r0, r2
    brf pp_not_label
    la r2, handle_label
    jal r1, (r2)
    la r0, pp_loop
    jmp (r0)
pp_not_label:

    ; IDENT (3) → handle instruction
    lc r2, 3
    ceq r0, r2
    brf pp_skip
    la r2, handle_instr
    jal r1, (r2)
    la r0, pp_loop
    jmp (r0)
pp_skip:

    ; Unexpected token — skip
    la r0, pp_loop
    jmp (r0)

; ============================================================
; Parser — directive handler
; ============================================================

; handle_dir — dispatch by directive name in tok_buf
; Non-leaf. Clobbers: r0, r1, r2.
handle_dir:
    push r1

    ; Check "const"
    la r0, tok_buf
    la r2, str_eq_a
    sw r0, 0(r2)
    la r0, dir_const_str
    la r2, str_eq_b
    sw r0, 0(r2)
    la r2, str_eq
    jal r1, (r2)
    ceq r0, z
    brt hd_not_const
    la r2, dir_const
    jal r1, (r2)
    pop r1
    jmp (r1)
hd_not_const:

    ; Check "global"
    la r0, tok_buf
    la r2, str_eq_a
    sw r0, 0(r2)
    la r0, dir_global_str
    la r2, str_eq_b
    sw r0, 0(r2)
    la r2, str_eq
    jal r1, (r2)
    ceq r0, z
    brt hd_not_global
    la r2, dir_global
    jal r1, (r2)
    pop r1
    jmp (r1)
hd_not_global:

    ; Check "data"
    la r0, tok_buf
    la r2, str_eq_a
    sw r0, 0(r2)
    la r0, dir_data_str
    la r2, str_eq_b
    sw r0, 0(r2)
    la r2, str_eq
    jal r1, (r2)
    ceq r0, z
    brt hd_not_data
    la r2, dir_data
    jal r1, (r2)
    pop r1
    jmp (r1)
hd_not_data:

    ; Check "proc"
    la r0, tok_buf
    la r2, str_eq_a
    sw r0, 0(r2)
    la r0, dir_proc_str
    la r2, str_eq_b
    sw r0, 0(r2)
    la r2, str_eq
    jal r1, (r2)
    ceq r0, z
    brt hd_not_proc
    la r2, dir_proc
    jal r1, (r2)
    pop r1
    jmp (r1)
hd_not_proc:

    ; Check "end" — emit leave in pass 2, advance code_addr in pass 1
    la r0, tok_buf
    la r2, str_eq_a
    sw r0, 0(r2)
    la r0, dir_end_str
    la r2, str_eq_b
    sw r0, 0(r2)
    la r2, str_eq
    jal r1, (r2)
    ceq r0, z
    brt hd_unknown
    ; Check pass number
    la r2, pass_num
    lbu r0, 0(r2)
    lc r2, 1
    ceq r0, r2
    brf hd_end_p2
    ; Pass 1: advance code_addr by 1 (leave opcode)
    la r2, code_addr
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)
hd_end_p2:
    ; Pass 2: emit leave opcode (0x41 = 65)
    lc r0, 65
    la r2, emit_byte
    jal r1, (r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)
hd_unknown:
    ; Unknown directive — skip
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)

; ============================================================
; Parser — directive implementations
; ============================================================

; dir_const — .const NAME value
; Non-leaf.
dir_const:
    push r1
    ; Read name token
    la r2, next_token
    jal r1, (r2)
    ; Only register in pass 1
    la r2, pass_num
    lbu r0, 0(r2)
    lc r2, 1
    ceq r0, r2
    brf dc_skip
    ; Copy name to name pool
    la r2, sym_name_copy
    jal r1, (r2)
    la r2, sym_add_name
    sw r0, 0(r2)
    ; Read value token
    la r2, next_token
    jal r1, (r2)
    la r2, tok_value
    lw r0, 0(r2)
    la r2, sym_add_val
    sw r0, 0(r2)
    ; Type = 0 (SYM_CONST)
    lc r0, 0
    la r2, sym_add_type
    sb r0, 0(r2)
    ; Add symbol
    la r2, sym_add
    jal r1, (r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)
dc_skip:
    ; Pass 2: skip value token and rest of line
    la r2, next_token
    jal r1, (r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)

; dir_global — .global NAME nwords
; Non-leaf.
dir_global:
    push r1
    ; Read name token
    la r2, next_token
    jal r1, (r2)
    ; Only register in pass 1
    la r2, pass_num
    lbu r0, 0(r2)
    lc r2, 1
    ceq r0, r2
    brf dg_skip
    ; Copy name to name pool
    la r2, sym_name_copy
    jal r1, (r2)
    la r2, sym_add_name
    sw r0, 0(r2)
    ; Value = current global_offset
    la r2, global_offset
    lw r0, 0(r2)
    la r2, sym_add_val
    sw r0, 0(r2)
    ; Type = 3 (SYM_GLOBAL)
    lc r0, 3
    la r2, sym_add_type
    sb r0, 0(r2)
    ; Add symbol
    la r2, sym_add
    jal r1, (r2)
    ; Read nwords
    la r2, next_token
    jal r1, (r2)
    ; Advance global_offset by nwords * 3
    la r2, tok_value
    lw r0, 0(r2)
    lc r2, 3
    mul r0, r2
    push r0
    la r2, global_offset
    lw r0, 0(r2)
    pop r2
    add r0, r2
    la r2, global_offset
    sw r0, 0(r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)
dg_skip:
    la r2, next_token
    jal r1, (r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)

; dir_data — .data NAME byte, byte, ...
; Non-leaf.
dir_data:
    push r1
    ; Read name token
    la r2, next_token
    jal r1, (r2)
    ; Only register in pass 1
    la r2, pass_num
    lbu r0, 0(r2)
    lc r2, 1
    ceq r0, r2
    brf dd_pass2
    ; Pass 1: register name, count bytes
    la r2, sym_name_copy
    jal r1, (r2)
    la r2, sym_add_name
    sw r0, 0(r2)
    la r2, data_offset
    lw r0, 0(r2)
    la r2, sym_add_val
    sw r0, 0(r2)
    lc r0, 4
    la r2, sym_add_type
    sb r0, 0(r2)
    la r2, sym_add
    jal r1, (r2)
    ; Count bytes until NL/EOF
    lc r0, 0
    la r2, dd_count
    sw r0, 0(r2)
dd_p1_loop:
    la r2, next_token
    jal r1, (r2)
    la r2, tok_type
    lbu r0, 0(r2)
    ; NL or EOF → done
    lc r2, 1
    ceq r0, r2
    brf dd_p1_not_nl
    la r0, dd_p1_done
    jmp (r0)
dd_p1_not_nl:
    ceq r0, z
    brf dd_p1_not_eof
    la r0, dd_p1_done
    jmp (r0)
dd_p1_not_eof:
    ; COMMA → skip
    lc r2, 6
    ceq r0, r2
    brt dd_p1_loop
    ; NUM → count
    lc r2, 2
    ceq r0, r2
    brf dd_p1_loop
    la r2, dd_count
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    la r0, dd_p1_loop
    jmp (r0)
dd_p1_done:
    ; Add byte count to data_offset
    la r2, dd_count
    lw r0, 0(r2)
    push r0
    la r2, data_offset
    lw r0, 0(r2)
    pop r2
    add r0, r2
    la r2, data_offset
    sw r0, 0(r2)
    pop r1
    jmp (r1)

dd_pass2:
    ; Pass 2: emit bytes to data_buf
dd_p2_loop:
    la r2, next_token
    jal r1, (r2)
    la r2, tok_type
    lbu r0, 0(r2)
    ; NL or EOF → done
    lc r2, 1
    ceq r0, r2
    brf dd_p2_not_nl
    la r0, dd_p2_done
    jmp (r0)
dd_p2_not_nl:
    ceq r0, z
    brf dd_p2_not_eof
    la r0, dd_p2_done
    jmp (r0)
dd_p2_not_eof:
    ; COMMA → skip
    lc r2, 6
    ceq r0, r2
    brt dd_p2_loop
    ; NUM → emit byte to data_buf
    la r2, tok_value
    lw r0, 0(r2)
    la r2, data_ptr
    lw r2, 0(r2)
    sb r0, 0(r2)
    ; Advance data_ptr
    la r2, data_ptr
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    la r0, dd_p2_loop
    jmp (r0)
dd_p2_done:
    pop r1
    jmp (r1)

; dir_proc — .proc NAME nlocals
; Non-leaf.
dir_proc:
    push r1
    ; Read name token
    la r2, next_token
    jal r1, (r2)
    ; Only register in pass 1
    la r2, pass_num
    lbu r0, 0(r2)
    lc r2, 1
    ceq r0, r2
    brf dp_skip
    ; Copy name to name pool
    la r2, sym_name_copy
    jal r1, (r2)
    la r2, sym_add_name
    sw r0, 0(r2)
    ; Value = current code_addr
    la r2, code_addr
    lw r0, 0(r2)
    la r2, sym_add_val
    sw r0, 0(r2)
    ; Type = 2 (SYM_PROC)
    lc r0, 2
    la r2, sym_add_type
    sb r0, 0(r2)
    la r2, sym_add
    jal r1, (r2)
    ; Read nlocals
    la r2, next_token
    jal r1, (r2)
    ; Advance code_addr by 2 (enter opcode + nlocals byte)
    la r2, code_addr
    lw r0, 0(r2)
    add r0, 2
    sw r0, 0(r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)
dp_skip:
    ; Pass 2: read nlocals, emit enter + nlocals
    la r2, next_token
    jal r1, (r2)
    la r2, resolve_operand
    jal r1, (r2)
    push r0
    ; Emit enter opcode (0x40 = 64)
    lc r0, 64
    la r2, emit_byte
    jal r1, (r2)
    ; Emit nlocals byte
    pop r0
    la r2, emit_byte
    jal r1, (r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)

; ============================================================
; Parser — label handler
; ============================================================

; handle_label — register label in symbol table (pass 1 only)
; Non-leaf.
handle_label:
    push r1
    ; Only in pass 1
    la r2, pass_num
    lbu r0, 0(r2)
    lc r2, 1
    ceq r0, r2
    brf hl_done
    ; Copy name to name pool
    la r2, sym_name_copy
    jal r1, (r2)
    la r2, sym_add_name
    sw r0, 0(r2)
    ; Type = 1 (SYM_LABEL)
    lc r0, 1
    la r2, sym_add_type
    sb r0, 0(r2)
    ; Value = current code_addr
    la r2, code_addr
    lw r0, 0(r2)
    la r2, sym_add_val
    sw r0, 0(r2)
    la r2, sym_add
    jal r1, (r2)
hl_done:
    pop r1
    jmp (r1)

; ============================================================
; Parser — instruction handler
; ============================================================

; handle_instr — look up mnemonic, emit or count instruction
; Non-leaf. Clobbers: r0, r1, r2.
handle_instr:
    push r1
    ; Look up mnemonic
    la r2, mnem_lookup
    jal r1, (r2)
    ; r0 = 1 if found, 0 if not
    ceq r0, z
    brf hi_found
    ; Unknown mnemonic
    la r0, msg_err_mnem
    la r2, uart_puts
    jal r1, (r2)
    la r0, tok_buf
    la r2, uart_puts
    jal r1, (r2)
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)

hi_found:
    ; cur_opcode and cur_optype are set
    ; Check pass number
    la r2, pass_num
    lbu r0, 0(r2)
    lc r2, 1
    ceq r0, r2
    brf hi_do_pass2
    ; ---- Pass 1: count instruction size ----
    la r0, hi_pass1
    jmp (r0)
hi_do_pass2:
    ; ---- Pass 2: emit opcode byte first ----
    la r2, cur_opcode
    lbu r0, 0(r2)
    la r2, emit_byte
    jal r1, (r2)
    la r0, hi_p2_operand
    jmp (r0)

; ---- Pass 1: add instruction size to code_addr ----
hi_pass1:
    ; code_addr += 1 (opcode byte)
    la r2, code_addr
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    ; Now add operand size based on type
    la r2, cur_optype
    lbu r0, 0(r2)
    ; type 0 (NONE): +0
    ceq r0, z
    brf hi_p1_not_t0
    la r0, hi_p1_done
    jmp (r0)
hi_p1_not_t0:
    ; type 1 (IMM8): +1
    lc r2, 1
    ceq r0, r2
    brf hi_p1_not_t1
    la r2, code_addr
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    la r0, hi_p1_done
    jmp (r0)
hi_p1_not_t1:
    ; type 2 (IMM24): +3
    lc r2, 2
    ceq r0, r2
    brf hi_p1_not_t2
    la r2, code_addr
    lw r0, 0(r2)
    add r0, 3
    sw r0, 0(r2)
    la r0, hi_p1_done
    jmp (r0)
hi_p1_not_t2:
    ; type 3 (D8_A24): +4
    lc r2, 3
    ceq r0, r2
    brf hi_p1_not_t3
    la r2, code_addr
    lw r0, 0(r2)
    add r0, 4
    sw r0, 0(r2)
    la r0, hi_p1_done
    jmp (r0)
hi_p1_not_t3:
    ; type 4 (D8_O8): +2
    lc r2, 4
    ceq r0, r2
    brf hi_p1_not_t4
    la r2, code_addr
    lw r0, 0(r2)
    add r0, 2
    sw r0, 0(r2)
    la r0, hi_p1_done
    jmp (r0)
hi_p1_not_t4:
    ; type 5 (IMM16): +2
    la r2, code_addr
    lw r0, 0(r2)
    add r0, 2
    sw r0, 0(r2)

hi_p1_done:
    ; Skip remaining tokens on line
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)

; ---- Pass 2: emit operand(s) ----
hi_p2_operand:
    la r2, cur_optype
    lbu r0, 0(r2)
    ; type 0 (NONE): no operand
    ceq r0, z
    brf hi_p2_not_t0
    la r0, hi_p2_done
    jmp (r0)
hi_p2_not_t0:
    ; type 1 (IMM8): read token, emit byte
    lc r2, 1
    ceq r0, r2
    brf hi_p2_not_t1
    la r2, next_token
    jal r1, (r2)
    la r2, resolve_operand
    jal r1, (r2)
    la r2, emit_byte
    jal r1, (r2)
    la r0, hi_p2_done
    jmp (r0)
hi_p2_not_t1:
    ; type 2 (IMM24): read token, emit word
    lc r2, 2
    ceq r0, r2
    brf hi_p2_not_t2
    la r2, next_token
    jal r1, (r2)
    la r2, resolve_operand
    jal r1, (r2)
    la r2, emit_word
    jal r1, (r2)
    la r0, hi_p2_done
    jmp (r0)
hi_p2_not_t2:
    ; type 3 (D8_A24): read two tokens, emit byte + word
    lc r2, 3
    ceq r0, r2
    brf hi_p2_not_t3
    ; First: depth byte
    la r2, next_token
    jal r1, (r2)
    la r2, resolve_operand
    jal r1, (r2)
    la r2, emit_byte
    jal r1, (r2)
    ; Second: address word
    la r2, next_token
    jal r1, (r2)
    la r2, resolve_operand
    jal r1, (r2)
    la r2, emit_word
    jal r1, (r2)
    la r0, hi_p2_done
    jmp (r0)
hi_p2_not_t3:
    ; type 4 (D8_O8): read two tokens, emit byte + byte
    la r2, cur_optype
    lbu r0, 0(r2)
    lc r2, 4
    ceq r0, r2
    brf hi_p2_not_t4
    la r2, next_token
    jal r1, (r2)
    la r2, resolve_operand
    jal r1, (r2)
    la r2, emit_byte
    jal r1, (r2)
    la r2, next_token
    jal r1, (r2)
    la r2, resolve_operand
    jal r1, (r2)
    la r2, emit_byte
    jal r1, (r2)
    la r0, hi_p2_done
    jmp (r0)
hi_p2_not_t4:
    ; type 5 (IMM16): read token, emit lo byte + hi byte
    la r2, next_token
    jal r1, (r2)
    la r2, resolve_operand
    jal r1, (r2)
    ; r0 = resolved value; emit low byte then high byte
    push r0
    la r2, emit_byte         ; emit low byte (r0 & 0xFF)
    jal r1, (r2)
    pop r0
    lc r2, 8
    sra r0, r2               ; r0 >>= 8
    la r2, emit_byte         ; emit high byte
    jal r1, (r2)

hi_p2_done:
    la r2, skip_to_eol
    jal r1, (r2)
    pop r1
    jmp (r1)

; ============================================================
; skip_to_eol — consume tokens until NL or EOF
; ============================================================
; Non-leaf. Clobbers: r0, r1, r2.
skip_to_eol:
    push r1
ste_loop:
    la r2, tok_type
    lbu r0, 0(r2)
    ; NL?
    lc r2, 1
    ceq r0, r2
    brt ste_done
    ; EOF?
    ceq r0, z
    brt ste_done
    ; Consume next token
    la r2, next_token
    jal r1, (r2)
    bra ste_loop
ste_done:
    pop r1
    jmp (r1)

; ============================================================
; Symbol table — add entry
; ============================================================

; sym_add — add symbol from sym_add_name/type/val
; Non-leaf. Clobbers: r0, r1, r2.
sym_add:
    push r1
    ; Check for overflow (max 128 entries)
    la r2, sym_count
    lw r0, 0(r2)
    lc r2, 127
    add r2, 1
    clu r0, r2
    brt sa_ok
    ; Overflow — print error and skip
    la r0, msg_err_sym
    la r2, uart_puts
    jal r1, (r2)
    la r0, msg_sym_full
    la r2, uart_puts
    jal r1, (r2)
    pop r1
    jmp (r1)
sa_ok:
    ; Calculate entry address: sym_table + sym_count * 9
    la r2, sym_count
    lw r0, 0(r2)
    lc r2, 9
    mul r0, r2
    la r2, sym_table
    add r0, r2
    la r2, sa_entry
    sw r0, 0(r2)
    ; Write word 0: name pool offset
    la r2, sym_add_name
    lw r0, 0(r2)
    la r2, sa_entry
    lw r2, 0(r2)
    sw r0, 0(r2)
    ; Write word 1: type
    la r2, sym_add_type
    lbu r0, 0(r2)
    la r2, sa_entry
    lw r2, 0(r2)
    sw r0, 3(r2)
    ; Write word 2: value
    la r2, sym_add_val
    lw r0, 0(r2)
    la r2, sa_entry
    lw r2, 0(r2)
    sw r0, 6(r2)
    ; Increment sym_count
    la r2, sym_count
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    pop r1
    jmp (r1)

; ============================================================
; Symbol table — find by name
; ============================================================

; sym_find — search symbol table for name in tok_buf
; Returns value in r0. Prints error if not found, returns 0.
; Non-leaf. Clobbers: r0, r1, r2.
sym_find:
    push r1
    ; Check if table is empty
    la r2, sym_count
    lw r0, 0(r2)
    ceq r0, z
    brf sf_start
    la r0, sf_not_found
    jmp (r0)
sf_start:
    ; Init search state
    la r2, sym_count
    lw r0, 0(r2)
    la r2, sf_count
    sw r0, 0(r2)
    lc r0, 0
    la r2, sf_index
    sw r0, 0(r2)
    la r0, sym_table
    la r2, sf_ptr
    sw r0, 0(r2)

sf_loop:
    ; Check index < count
    la r2, sf_index
    lw r0, 0(r2)
    push r0
    la r2, sf_count
    lw r2, 0(r2)
    pop r0
    clu r0, r2
    brf sf_not_found

    ; Get name address: name_pool + entry[0]
    la r2, sf_ptr
    lw r2, 0(r2)
    lw r0, 0(r2)
    la r2, name_pool
    add r0, r2

    ; Compare with tok_buf
    la r2, str_eq_a
    sw r0, 0(r2)
    la r0, tok_buf
    la r2, str_eq_b
    sw r0, 0(r2)
    la r2, str_eq
    jal r1, (r2)
    ; r0 = 1 if match
    ceq r0, z
    brt sf_next

    ; Found! Return value (word 2 at offset 6)
    la r2, sf_ptr
    lw r2, 0(r2)
    lw r0, 6(r2)
    pop r1
    jmp (r1)

sf_next:
    ; Advance pointer by 9
    la r2, sf_ptr
    lw r0, 0(r2)
    add r0, 9
    sw r0, 0(r2)
    ; Increment index
    la r2, sf_index
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    la r0, sf_loop
    jmp (r0)

sf_not_found:
    la r0, msg_err_sym
    la r2, uart_puts
    jal r1, (r2)
    la r0, tok_buf
    la r2, uart_puts
    jal r1, (r2)
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    lc r0, 0
    pop r1
    jmp (r1)

; ============================================================
; Symbol table — copy name to name pool
; ============================================================

; sym_name_copy — copy tok_buf into name_pool, return offset in r0
; Non-leaf. Clobbers: r0, r1, r2.
sym_name_copy:
    push r1
    ; Calculate offset: name_pool_ptr - name_pool
    la r2, name_pool_ptr
    lw r0, 0(r2)
    la r2, name_pool
    sub r0, r2
    push r0
    ; Set up copy source
    la r0, tok_buf
    la r2, snc_src
    sw r0, 0(r2)

snc_loop:
    ; Load byte from source
    la r2, snc_src
    lw r2, 0(r2)
    lbu r0, 0(r2)
    push r0
    ; Store to name_pool_ptr
    la r2, name_pool_ptr
    lw r2, 0(r2)
    pop r0
    sb r0, 0(r2)
    ; Check if null
    push r0
    ; Advance dest
    la r2, name_pool_ptr
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    ; Advance source
    la r2, snc_src
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    ; Check saved byte for null
    pop r0
    ceq r0, z
    brf snc_loop

    ; Return offset
    pop r0
    pop r1
    jmp (r1)

; ============================================================
; String comparison
; ============================================================

; str_eq — compare strings at str_eq_a and str_eq_b
; Returns r0 = 1 if equal, 0 if not.
; Non-leaf. Clobbers: r0, r1, r2.
str_eq:
    push r1

seq_loop:
    la r2, str_eq_a
    lw r2, 0(r2)
    lbu r0, 0(r2)
    push r0
    la r2, str_eq_b
    lw r2, 0(r2)
    lbu r0, 0(r2)
    pop r2
    ; r2 = byte from a, r0 = byte from b
    ceq r0, r2
    brf seq_ne
    ; Same byte — check for null
    ceq r0, z
    brt seq_eq
    ; Advance both pointers
    la r2, str_eq_a
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    la r2, str_eq_b
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    bra seq_loop

seq_ne:
    lc r0, 0
    pop r1
    jmp (r1)

seq_eq:
    lc r0, 1
    pop r1
    jmp (r1)

; ============================================================
; Emit helpers — write to code_buf
; ============================================================

; emit_byte — write byte in r0 to code_buf, advance code_ptr
; Leaf function. Clobbers: r0, r2. Preserves: r1.
emit_byte:
    la r2, code_ptr
    lw r2, 0(r2)
    sb r0, 0(r2)
    add r2, 1
    mov r0, r2
    la r2, code_ptr
    sw r0, 0(r2)
    jmp (r1)

; emit_word — write 24-bit word in r0 to code_buf, advance by 3
; Leaf function. Clobbers: r0, r2. Preserves: r1.
emit_word:
    la r2, code_ptr
    lw r2, 0(r2)
    sw r0, 0(r2)
    add r2, 3
    mov r0, r2
    la r2, code_ptr
    sw r0, 0(r2)
    jmp (r1)

; ============================================================
; Mnemonic lookup
; ============================================================

; mnem_lookup — find tok_buf in mnemonic table
; Sets cur_opcode and cur_optype on match.
; Returns r0 = 1 if found, 0 if not.
; Non-leaf. Clobbers: r0, r1, r2.
mnem_lookup:
    push r1
    ; Init pointer to start of table
    la r0, mnem_table
    la r2, mnem_ptr
    sw r0, 0(r2)

ml_loop:
    ; Check for end sentinel (first byte = 0)
    la r2, mnem_ptr
    lw r2, 0(r2)
    lbu r0, 0(r2)
    ceq r0, z
    brf ml_compare
    ; End of table — not found
    lc r0, 0
    pop r1
    jmp (r1)

ml_compare:
    ; Compare tok_buf with current entry string
    la r0, tok_buf
    la r2, str_eq_a
    sw r0, 0(r2)
    la r2, mnem_ptr
    lw r0, 0(r2)
    la r2, str_eq_b
    sw r0, 0(r2)
    la r2, str_eq
    jal r1, (r2)
    ; r0 = 1 if match
    ceq r0, z
    brt ml_skip
    ; Match found!
    la r0, ml_found
    jmp (r0)

ml_skip:
    ; Skip past string null terminator
    la r2, mnem_ptr
    lw r0, 0(r2)
ml_skip_str:
    mov r2, r0
    lbu r2, 0(r2)
    add r0, 1
    ceq r2, z
    brf ml_skip_str
    ; r0 now points past null (at opcode byte)
    ; Skip opcode + type (2 bytes)
    add r0, 2
    la r2, mnem_ptr
    sw r0, 0(r2)
    la r0, ml_loop
    jmp (r0)

ml_found:
    ; Walk to null terminator of matched string
    la r2, mnem_ptr
    lw r0, 0(r2)
ml_find_null:
    mov r2, r0
    lbu r2, 0(r2)
    add r0, 1
    ceq r2, z
    brf ml_find_null
    ; r0 points to opcode byte (right after null)
    mov r2, r0
    lbu r0, 0(r2)
    push r0
    lbu r0, 1(r2)
    la r2, cur_optype
    sb r0, 0(r2)
    pop r0
    la r2, cur_opcode
    sb r0, 0(r2)
    ; Return success
    lc r0, 1
    pop r1
    jmp (r1)

; ============================================================
; Operand resolution
; ============================================================

; resolve_operand — resolve current token to a value
; If NUM, returns tok_value. If IDENT, looks up symbol.
; Returns value in r0.
; Non-leaf. Clobbers: r0, r1, r2.
resolve_operand:
    push r1
    la r2, tok_type
    lbu r0, 0(r2)
    ; NUM?
    lc r2, 2
    ceq r0, r2
    brf ro_not_num
    la r2, tok_value
    lw r0, 0(r2)
    pop r1
    jmp (r1)
ro_not_num:
    ; IDENT?
    lc r2, 3
    ceq r0, r2
    brf ro_default
    la r2, sym_find
    jal r1, (r2)
    pop r1
    jmp (r1)
ro_default:
    lc r0, 0
    pop r1
    jmp (r1)

; ============================================================
; patch_symbols — fix data/global offsets after pass 1
; ============================================================

; patch_symbols — add code_size to SYM_DATA, code_size+data_size to SYM_GLOBAL
; Non-leaf. Clobbers: r0, r1, r2.
patch_symbols:
    push r1
    la r2, sym_count
    lw r0, 0(r2)
    ceq r0, z
    brf ps_start
    pop r1
    jmp (r1)
ps_start:
    la r2, sym_count
    lw r0, 0(r2)
    la r2, ps_count
    sw r0, 0(r2)
    la r0, sym_table
    la r2, ps_ptr
    sw r0, 0(r2)
    lc r0, 0
    la r2, ps_index
    sw r0, 0(r2)

ps_loop:
    ; Check index < count
    la r2, ps_index
    lw r0, 0(r2)
    push r0
    la r2, ps_count
    lw r2, 0(r2)
    pop r0
    clu r0, r2
    brf ps_done

    ; Load type (word 1 at offset 3)
    la r2, ps_ptr
    lw r2, 0(r2)
    lw r0, 3(r2)
    ; Check SYM_DATA (4)
    lc r2, 4
    ceq r0, r2
    brf ps_not_data
    ; Patch: value = code_buf + code_size + data_offset (absolute addr)
    la r2, ps_ptr
    lw r2, 0(r2)
    lw r0, 6(r2)
    push r2
    la r2, code_size
    lw r2, 0(r2)
    add r0, r2
    la r2, code_buf
    add r0, r2
    pop r2
    sw r0, 6(r2)
    la r0, ps_next
    jmp (r0)
ps_not_data:
    ; Check SYM_GLOBAL (3)
    lc r2, 3
    ceq r0, r2
    brf ps_next
    ; Patch: value = globals_seg + word_offset * 3 (absolute addr)
    la r2, ps_ptr
    lw r2, 0(r2)
    lw r0, 6(r2)
    push r2
    ; r0 = word_offset; multiply by 3
    mov r2, r0
    add r0, r0
    add r0, r2
    ; r0 = word_offset * 3
    la r2, globals_seg
    add r0, r2
    pop r2
    sw r0, 6(r2)

ps_next:
    ; Advance
    la r2, ps_ptr
    lw r0, 0(r2)
    add r0, 9
    sw r0, 0(r2)
    la r2, ps_index
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    la r0, ps_loop
    jmp (r0)

ps_done:
    pop r1
    jmp (r1)

; ============================================================
; dump_bytecode — print assembled bytes to UART
; ============================================================
; Non-leaf. Clobbers: r0, r1, r2.
dump_bytecode:
    push r1
    ; Print header
    la r0, msg_code
    la r2, uart_puts
    jal r1, (r2)

    ; Calculate byte count: code_ptr - code_buf
    la r2, code_ptr
    lw r0, 0(r2)
    la r2, code_buf
    sub r0, r2
    ceq r0, z
    brf db_has_bytes
    ; Empty — just newline
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    pop r1
    jmp (r1)

db_has_bytes:
    la r2, db_count
    sw r0, 0(r2)
    la r0, code_buf
    la r2, db_ptr
    sw r0, 0(r2)

db_loop:
    la r2, db_count
    lw r0, 0(r2)
    ceq r0, z
    brf db_print
    ; Done — newline
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    pop r1
    jmp (r1)

db_print:
    ; Load byte
    la r2, db_ptr
    lw r2, 0(r2)
    lbu r0, 0(r2)
    ; Print as decimal
    la r2, print_num
    jal r1, (r2)
    ; Print space
    lc r0, 32
    la r2, uart_putc
    jal r1, (r2)
    ; Advance pointer
    la r2, db_ptr
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    ; Decrement count
    la r2, db_count
    lw r0, 0(r2)
    add r0, -1
    sw r0, 0(r2)
    la r0, db_loop
    jmp (r0)

; ============================================================
; print_token — print current token to UART (debug output)
; ============================================================
; Non-leaf. Clobbers: r0, r1, r2, fp.
print_token:
    push r1
    la r2, tok_type
    lbu r0, 0(r2)

    ; Type 0: EOF
    ceq r0, z
    brf pt_not_eof
    la r0, pt_eof
    jmp (r0)
pt_not_eof:
    ; Type 1: NL
    lc r2, 1
    ceq r0, r2
    brf pt_not_nl
    la r0, pt_nl
    jmp (r0)
pt_not_nl:
    ; Type 2: NUM
    lc r2, 2
    ceq r0, r2
    brf pt_not_num
    la r0, pt_num
    jmp (r0)
pt_not_num:
    ; Type 3: IDENT
    lc r2, 3
    ceq r0, r2
    brf pt_not_id
    la r0, pt_ident
    jmp (r0)
pt_not_id:
    ; Type 4: DIR
    lc r2, 4
    ceq r0, r2
    brf pt_not_dir
    la r0, pt_dir
    jmp (r0)
pt_not_dir:
    ; Type 5: LABEL
    lc r2, 5
    ceq r0, r2
    brf pt_not_lbl
    la r0, pt_label
    jmp (r0)
pt_not_lbl:
    ; Type 6: COMMA (default)
    la r0, pt_comma
    jmp (r0)

pt_eof:
    la r0, msg_eof
    la r2, uart_puts
    jal r1, (r2)
    pop r1
    jmp (r1)

pt_nl:
    la r0, msg_nl
    la r2, uart_puts
    jal r1, (r2)
    pop r1
    jmp (r1)

pt_num:
    la r0, msg_num
    la r2, uart_puts
    jal r1, (r2)
    ; Print number value
    la r2, tok_value
    lw r0, 0(r2)
    la r2, print_num
    jal r1, (r2)
    ; Print newline
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    pop r1
    jmp (r1)

pt_ident:
    la r0, msg_id
    la r2, uart_puts
    jal r1, (r2)
    la r0, tok_buf
    la r2, uart_puts
    jal r1, (r2)
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    pop r1
    jmp (r1)

pt_dir:
    la r0, msg_dir
    la r2, uart_puts
    jal r1, (r2)
    la r0, tok_buf
    la r2, uart_puts
    jal r1, (r2)
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    pop r1
    jmp (r1)

pt_label:
    la r0, msg_lbl
    la r2, uart_puts
    jal r1, (r2)
    la r0, tok_buf
    la r2, uart_puts
    jal r1, (r2)
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    pop r1
    jmp (r1)

pt_comma:
    la r0, msg_com
    la r2, uart_puts
    jal r1, (r2)
    pop r1
    jmp (r1)

; ============================================================
; print_num — print signed 24-bit integer to UART
; ============================================================
; r0 = value to print
; Non-leaf. Clobbers: r0, r1, r2, fp.
print_num:
    push r1
    ; Handle zero
    ceq r0, z
    brf pnum_not_zero
    la r0, pnum_zero
    jmp (r0)
pnum_not_zero:
    ; Handle negative
    cls r0, z
    brf pnum_positive
    ; Print '-'
    push r0
    lc r0, 45
    la r2, uart_putc
    jal r1, (r2)
    pop r0
    ; Negate: r0 = 0 - r0
    lc r2, 0
    sub r2, r0
    mov r0, r2

pnum_positive:
    ; Store value in num_val
    la r2, num_val
    sw r0, 0(r2)
    ; Push sentinel (0) onto stack
    lc r0, 0
    push r0

    ; Extract digits: divide by 10, push remainders
pnum_extract:
    la r2, num_val
    lw r0, 0(r2)
    ceq r0, z
    brt pnum_output
    ; div10: divides num_val by 10, returns remainder in r0
    la r2, div10
    jal r1, (r2)
    ; r0 = remainder, convert to ASCII
    add r0, 48
    push r0
    bra pnum_extract

    ; Pop and print digits until sentinel (0)
pnum_output:
    pop r0
    ceq r0, z
    brt pnum_ret
    la r2, uart_putc
    jal r1, (r2)
    bra pnum_output

pnum_ret:
    pop r1
    jmp (r1)

pnum_zero:
    lc r0, 48
    la r2, uart_putc
    jal r1, (r2)
    pop r1
    jmp (r1)

; ============================================================
; div10 — divide num_val by 10 using repeated subtraction
; ============================================================
; Updates num_val with quotient, returns remainder (0-9) in r0.
; Leaf function. Clobbers: r0, r2. Preserves: r1.
div10:
    ; Load dividend and init quotient
    la r2, num_val
    lw r0, 0(r2)
    push r0
    la r2, num_div
    lc r0, 0
    sw r0, 0(r2)
    pop r0
    ; Repeated subtraction
d10_loop:
    lc r2, 10
    clu r0, r2
    brt d10_done
    add r0, -10
    ; Increment quotient
    push r0
    la r2, num_div
    lw r0, 0(r2)
    add r0, 1
    sw r0, 0(r2)
    pop r0
    bra d10_loop
d10_done:
    ; r0 = remainder; store quotient to num_val
    push r0
    la r2, num_div
    lw r0, 0(r2)
    la r2, num_val
    sw r0, 0(r2)
    pop r0
    jmp (r1)


; ============================================================
; P-Code Virtual Machine
; ============================================================

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

    ; 2. Advance pc by 2 (skip slot operand)
    lw r0, 0(fp)
    add r0, 2
    ; Save return_pc to xcall_temps
    la r2, xcall_temps
    sw r0, 0(r2)            ; xcall_temps[0] = return_pc

    ; 3. Look up IRT: target = mem[irt_base + slot * 3]
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

; sys READ_SWITCH (id=6): read switch state, push onto eval stack
; sys DUMP_STATE (id=8): print vm_state to UART for debugging
sys_dump_state:
    la r0, vm_state
    push r0
    pop fp
    la r0, dump_s_vm
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 0(fp)
    la r2, uart_put_hex24
    jal r1, (r2)
    la r0, dump_s_esp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 3(fp)
    la r2, uart_put_hex24
    jal r1, (r2)
    la r0, dump_s_csp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 6(fp)
    la r2, uart_put_hex24
    jal r1, (r2)
    la r0, dump_s_fp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 9(fp)
    la r2, uart_put_hex24
    jal r1, (r2)
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    la r0, dump_s_gp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 12(fp)
    la r2, uart_put_hex24
    jal r1, (r2)
    la r0, dump_s_hp
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 15(fp)
    la r2, uart_put_hex24
    jal r1, (r2)
    la r0, dump_s_code
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 18(fp)
    la r2, uart_put_hex24
    jal r1, (r2)
    la r0, dump_s_irt
    la r2, uart_puts
    jal r1, (r2)
    lw r0, 27(fp)
    la r2, uart_put_hex24
    jal r1, (r2)
    la r0, dump_s_u
    la r2, uart_puts
    jal r1, (r2)
    lbu r0, 33(fp)
    la r2, uart_put_hex8
    jal r1, (r2)
    lc r0, 10
    la r2, uart_putc
    jal r1, (r2)
    la r0, vm_loop
    jmp (r0)

dump_s_vm:
    .byte 86, 77, 58, 32, 112, 99, 61, 0
dump_s_esp:
    .byte 32, 101, 115, 112, 61, 0
dump_s_csp:
    .byte 32, 99, 115, 112, 61, 0
dump_s_fp:
    .byte 32, 102, 112, 61, 0
dump_s_gp:
    .byte 32, 32, 32, 32, 103, 112, 61, 0
dump_s_hp:
    .byte 32, 104, 112, 61, 0
dump_s_code:
    .byte 32, 99, 111, 100, 101, 61, 0
dump_s_irt:
    .byte 32, 105, 114, 116, 61, 0
dump_s_u:
    .byte 32, 117, 61, 0

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
; Mnemonic table
; ============================================================
; Format: null-terminated string, opcode byte, operand type byte
; End sentinel: single 0 byte
;
; Operand types: 0=NONE, 1=IMM8, 2=IMM24, 3=D8_A24, 4=D8_O8

mnem_table:
    ; "halt" opcode=0 type=NONE
    .byte 104, 97, 108, 116, 0, 0, 0
    ; "push" opcode=1 type=IMM24
    .byte 112, 117, 115, 104, 0, 1, 2
    ; "push_s" opcode=2 type=IMM8
    .byte 112, 117, 115, 104, 95, 115, 0, 2, 1
    ; "dup" opcode=3 type=NONE
    .byte 100, 117, 112, 0, 3, 0
    ; "drop" opcode=4 type=NONE
    .byte 100, 114, 111, 112, 0, 4, 0
    ; "swap" opcode=5 type=NONE
    .byte 115, 119, 97, 112, 0, 5, 0
    ; "over" opcode=6 type=NONE
    .byte 111, 118, 101, 114, 0, 6, 0
    ; "add" opcode=16 type=NONE
    .byte 97, 100, 100, 0, 16, 0
    ; "sub" opcode=17 type=NONE
    .byte 115, 117, 98, 0, 17, 0
    ; "mul" opcode=18 type=NONE
    .byte 109, 117, 108, 0, 18, 0
    ; "div" opcode=19 type=NONE
    .byte 100, 105, 118, 0, 19, 0
    ; "mod" opcode=20 type=NONE
    .byte 109, 111, 100, 0, 20, 0
    ; "neg" opcode=21 type=NONE
    .byte 110, 101, 103, 0, 21, 0
    ; "and" opcode=22 type=NONE
    .byte 97, 110, 100, 0, 22, 0
    ; "or" opcode=23 type=NONE
    .byte 111, 114, 0, 23, 0
    ; "xor" opcode=24 type=NONE
    .byte 120, 111, 114, 0, 24, 0
    ; "not" opcode=25 type=NONE
    .byte 110, 111, 116, 0, 25, 0
    ; "shl" opcode=26 type=NONE
    .byte 115, 104, 108, 0, 26, 0
    ; "shr" opcode=27 type=NONE
    .byte 115, 104, 114, 0, 27, 0
    ; "eq" opcode=32 type=NONE
    .byte 101, 113, 0, 32, 0
    ; "ne" opcode=33 type=NONE
    .byte 110, 101, 0, 33, 0
    ; "lt" opcode=34 type=NONE
    .byte 108, 116, 0, 34, 0
    ; "le" opcode=35 type=NONE
    .byte 108, 101, 0, 35, 0
    ; "gt" opcode=36 type=NONE
    .byte 103, 116, 0, 36, 0
    ; "ge" opcode=37 type=NONE
    .byte 103, 101, 0, 37, 0
    ; "jmp" opcode=48 type=IMM24
    .byte 106, 109, 112, 0, 48, 2
    ; "jz" opcode=49 type=IMM24
    .byte 106, 122, 0, 49, 2
    ; "jnz" opcode=50 type=IMM24
    .byte 106, 110, 122, 0, 50, 2
    ; "call" opcode=51 type=IMM24
    .byte 99, 97, 108, 108, 0, 51, 2
    ; "ret" opcode=52 type=IMM8
    .byte 114, 101, 116, 0, 52, 1
    ; "calln" opcode=53 type=D8_A24
    .byte 99, 97, 108, 108, 110, 0, 53, 3
    ; "trap" opcode=54 type=IMM8
    .byte 116, 114, 97, 112, 0, 54, 1
    ; "enter" opcode=64 type=IMM8
    .byte 101, 110, 116, 101, 114, 0, 64, 1
    ; "leave" opcode=65 type=NONE
    .byte 108, 101, 97, 118, 101, 0, 65, 0
    ; "loadl" opcode=66 type=IMM8
    .byte 108, 111, 97, 100, 108, 0, 66, 1
    ; "storel" opcode=67 type=IMM8
    .byte 115, 116, 111, 114, 101, 108, 0, 67, 1
    ; "loadg" opcode=68 type=IMM24
    .byte 108, 111, 97, 100, 103, 0, 68, 2
    ; "storeg" opcode=69 type=IMM24
    .byte 115, 116, 111, 114, 101, 103, 0, 69, 2
    ; "addrl" opcode=70 type=IMM8
    .byte 97, 100, 100, 114, 108, 0, 70, 1
    ; "addrg" opcode=71 type=IMM24
    .byte 97, 100, 100, 114, 103, 0, 71, 2
    ; "loada" opcode=72 type=IMM8
    .byte 108, 111, 97, 100, 97, 0, 72, 1
    ; "storea" opcode=73 type=IMM8
    .byte 115, 116, 111, 114, 101, 97, 0, 73, 1
    ; "loadn" opcode=74 type=D8_O8
    .byte 108, 111, 97, 100, 110, 0, 74, 4
    ; "storen" opcode=75 type=D8_O8
    .byte 115, 116, 111, 114, 101, 110, 0, 75, 4
    ; "load" opcode=80 type=NONE
    .byte 108, 111, 97, 100, 0, 80, 0
    ; "store" opcode=81 type=NONE
    .byte 115, 116, 111, 114, 101, 0, 81, 0
    ; "loadb" opcode=82 type=NONE
    .byte 108, 111, 97, 100, 98, 0, 82, 0
    ; "storeb" opcode=83 type=NONE
    .byte 115, 116, 111, 114, 101, 98, 0, 83, 0
    ; "sys" opcode=96 type=IMM8
    .byte 115, 121, 115, 0, 96, 1
    ; "memcpy" opcode=112 type=NONE
    .byte 109, 101, 109, 99, 112, 121, 0, 112, 0
    ; "memset" opcode=113 type=NONE
    .byte 109, 101, 109, 115, 101, 116, 0, 113, 0
    ; "memcmp" opcode=114 type=NONE
    .byte 109, 101, 109, 99, 109, 112, 0, 114, 0
    ; "jmp_ind" opcode=115 type=NONE
    .byte 106, 109, 112, 95, 105, 110, 100, 0, 115, 0
    ; "xcall" opcode=116 type=IMM16
    .byte 120, 99, 97, 108, 108, 0, 116, 5
    ; "xloadg" opcode=117 type=D8_O8
    .byte 120, 108, 111, 97, 100, 103, 0, 117, 4
    ; "xstoreg" opcode=118 type=D8_O8
    .byte 120, 115, 116, 111, 114, 101, 103, 0, 118, 4
    ; End sentinel
    .byte 0

; ============================================================
; Directive name strings
; ============================================================
dir_const_str:
    .byte 99, 111, 110, 115, 116, 0
    ; "const\0"
dir_global_str:
    .byte 103, 108, 111, 98, 97, 108, 0
    ; "global\0"
dir_data_str:
    .byte 100, 97, 116, 97, 0
    ; "data\0"
dir_proc_str:
    .byte 112, 114, 111, 99, 0
    ; "proc\0"
dir_end_str:
    .byte 101, 110, 100, 0
    ; "end\0"

; ============================================================
; String constants
; ============================================================
msg_boot:
    .byte 80, 65, 83, 77, 10, 0
    ; "PASM\n\0"

msg_done:
    .byte 68, 79, 78, 69, 10, 0
    ; "DONE\n\0"

msg_code:
    .byte 67, 79, 68, 69, 32, 0
    ; "CODE \0"

msg_err_mnem:
    .byte 69, 82, 82, 58, 32, 0
    ; "ERR: \0"

msg_err_sym:
    .byte 83, 89, 77, 63, 32, 0
    ; "SYM? \0"

msg_sym_full:
    .byte 70, 85, 76, 76, 10, 0
    ; "FULL\n\0"

msg_eof:
    .byte 69, 79, 70, 10, 0
    ; "EOF\n\0"

msg_nl:
    .byte 78, 76, 10, 0
    ; "NL\n\0"

msg_num:
    .byte 78, 85, 77, 32, 0
    ; "NUM \0"

msg_id:
    .byte 73, 68, 32, 0
    ; "ID \0"

msg_dir:
    .byte 68, 73, 82, 32, 0
    ; "DIR \0"

msg_lbl:
    .byte 76, 66, 76, 32, 0
    ; "LBL \0"

msg_com:
    .byte 67, 79, 77, 10, 0
    ; "COM\n\0"

; ============================================================
; Lexer state
; ============================================================
lex_char:
    .byte 0

; ============================================================
; Token output
; ============================================================
tok_type:
    .byte 0

tok_len:
    .byte 0

tok_value:
    .word 0

tok_buf:
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    ; 32 bytes for token string

; ============================================================
; Temporary variables
; ============================================================
tok_ptr:
    .word 0

num_val:
    .word 0

num_div:
    .word 0

num_neg:
    .byte 0

; ============================================================
; Parser state
; ============================================================
pass_num:
    .byte 0

code_addr:
    .word 0

code_size:
    .word 0

global_offset:
    .word 0

data_offset:
    .word 0

total_data_size:
    .word 0

cur_opcode:
    .byte 0

cur_optype:
    .byte 0

dd_count:
    .word 0

; ============================================================
; Symbol table parameters (for sym_add)
; ============================================================
sym_add_name:
    .word 0

sym_add_type:
    .byte 0

sym_add_val:
    .word 0

; Temp for sym_add
sa_entry:
    .word 0

; Temps for sym_find
sf_count:
    .word 0

sf_index:
    .word 0

sf_ptr:
    .word 0

; Temps for sym_name_copy
snc_src:
    .word 0

; Temps for str_eq
str_eq_a:
    .word 0

str_eq_b:
    .word 0

; Temps for mnem_lookup
mnem_ptr:
    .word 0

; Temps for read_all_input
rai_ptr:
    .word 0

; Temps for dump_bytecode
db_count:
    .word 0

db_ptr:
    .word 0

; Temps for patch_symbols
ps_count:
    .word 0

ps_index:
    .word 0

ps_ptr:
    .word 0

; ============================================================
; Symbol table (max 128 entries, 9 bytes each = 1152 bytes)
; ============================================================
sym_count:
    .word 0

sym_table:
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
    ; 1152 bytes

; ============================================================
; Name pool (2048 bytes for symbol name strings)
; ============================================================
name_pool_ptr:
    .word 0

name_pool:
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
    ; 2048 bytes

; ============================================================
; Input buffer (16384 bytes for source input)
; ============================================================
input_len:
    .word 0

input_pos:
    .word 0

input_buf:
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
    ; 16384 bytes

; ============================================================
; Code+data output buffer (2048 bytes)
; Pass 2 writes code starting at code_buf, data at code_buf + code_size
; ============================================================
code_ptr:
    .word 0

code_buf:
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
    ; 2048 bytes

; ============================================================
; Data output buffer (512 bytes)
; ============================================================
data_ptr:
    .word 0

data_buf:
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
    ; 512 bytes

; ============================================================
; VM string constants
; ============================================================
msg_vm_boot:
    .byte 82, 85, 78, 10, 0
    ; "RUN\n\0"

msg_halted:
    .byte 72, 65, 76, 84, 10, 0
    ; "HALT\n\0"

msg_trap_prefix:
    .byte 84, 82, 65, 80, 32, 0
    ; "TRAP \0" (space, no newline — code digit and \n printed separately)

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
; Temporary storage for ret handler (5 words = 15 bytes)
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
; Temporary storage for sys dispatch (1 word = 3 bytes)
; ============================================================
sys_id_temp:
    .word 0

; ============================================================
; Temporary storage for nonlocal handlers (3 words = 9 bytes)
; ============================================================
nonlocal_temps:
    .word 0
    ; [0] depth
    .word 0
    ; [3] off (or static link for calln)
    .word 0
    ; [6] value (for storen)

; Temporary storage for xcall handler (2 words = 6 bytes)
xcall_temps:
    .word 0
    ; [0] return_pc
    .word 0
    ; [3] target_pc

; ============================================================
; heap_limit — heap allocation ceiling.
; Default: 0x00F000 (~40KB usable heap above heap_seg).
; The heap uses bare SRAM — no pre-allocated data needed.
; sys ALLOC traps (TRAP 5) when hp >= this value.
heap_limit:
    .word 0x00F000

; VM memory segments
; ============================================================

; Globals segment (8 words = 24 bytes)
globals_seg:
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0

; Call stack (grows upward, 768 bytes for nested/recursive frames)
call_stack:
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    ; 256 words = 768 bytes

; Eval stack (grows upward, 768 bytes)
eval_stack:
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    ; 256 words = 768 bytes

; Heap (bump-allocated upward from heap_seg toward heap_limit)
; No pre-allocated data — uses available SRAM between here and heap_limit.
; Default heap_limit is 0x00F000 (~40KB usable heap for typical layouts).
; Patch heap_limit for more/less heap as needed.
heap_seg:
