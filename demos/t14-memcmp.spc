; t14-memcmp.spc — MEMCMP opcode test
; Expected output: OKLTOKGT
; Tests: equal, less-than, greater-than, zero-length

.data buf_a 65, 66, 67, 0, 0, 0
.data buf_b 65, 66, 67, 0, 0, 0
.data buf_c 65, 66, 68, 0, 0, 0

.proc main 0
    ; Test 1: equal buffers (a == b) — should push 0
    push buf_a
    push buf_b
    push_s 3
    memcmp
    push_s 0
    eq
    ; Print "OK" if equal, "NO" otherwise
    jz t1_fail
    push_s 79       ; 'O'
    sys 1
    push_s 75       ; 'K'
    sys 1
    jmp t2
t1_fail:
    push_s 78       ; 'N'
    sys 1
    push_s 79       ; 'O'
    sys 1

t2:
    ; Test 2: a < c (buf_a="ABC" vs buf_c="ABD") — should push negative
    push buf_a
    push buf_c
    push_s 3
    memcmp
    ; result should be negative (-1), check < 0
    push_s 0
    lt
    jz t2_fail
    push_s 76       ; 'L'
    sys 1
    push_s 84       ; 'T'
    sys 1
    jmp t3
t2_fail:
    push_s 78       ; 'N'
    sys 1
    push_s 79       ; 'O'
    sys 1

t3:
    ; Test 3: zero-length compare — should push 0 (equal)
    push buf_a
    push buf_c
    push_s 0
    memcmp
    push_s 0
    eq
    jz t3_fail
    push_s 79       ; 'O'
    sys 1
    push_s 75       ; 'K'
    sys 1
    jmp t4
t3_fail:
    push_s 78       ; 'N'
    sys 1
    push_s 79       ; 'O'
    sys 1

t4:
    ; Test 4: c > a (buf_c="ABD" vs buf_a="ABC") — should push positive
    push buf_c
    push buf_a
    push_s 3
    memcmp
    ; result should be positive (1), check > 0
    push_s 0
    gt
    jz t4_fail
    push_s 71       ; 'G'
    sys 1
    push_s 84       ; 'T'
    sys 1
    jmp done
t4_fail:
    push_s 78       ; 'N'
    sys 1
    push_s 79       ; 'O'
    sys 1

done:
    push_s 10
    sys 1
    halt
.end
