; t15-jmp_ind.spc — JMP_IND indirect jump test
; Expected output: ABOK
; Tests: basic indirect jump, chained indirect jump, computed target

.proc main 0
    ; Test 1: basic indirect jump — push target address, jmp_ind
    push target_a
    jmp_ind

    ; Should not reach here
    push_s 88       ; 'X'
    sys 1
    halt

target_a:
    push_s 65       ; 'A'
    sys 1

    ; Test 2: chained indirect jump — jump through second target
    push target_b
    jmp_ind

    ; Should not reach here
    push_s 88       ; 'X'
    sys 1
    halt

target_b:
    push_s 66       ; 'B'
    sys 1

    ; Test 3: computed target via arithmetic
    ; Push base address (target_ok) and add 0 to simulate computed target
    push target_ok
    push_s 0
    add
    jmp_ind

    ; Should not reach here
    push_s 88       ; 'X'
    sys 1
    halt

target_ok:
    push_s 79       ; 'O'
    sys 1
    push_s 75       ; 'K'
    sys 1

done:
    push_s 10
    sys 1
    halt
.end
