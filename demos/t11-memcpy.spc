; t11-memcpy.spc — MEMCPY opcode test
; Expected output: ABCABC

.data src 65, 66, 67, 0, 0, 0
.data dst 0, 0, 0, 0, 0, 0

.proc main 0
    ; Zero-length copy (should be a no-op)
    push src
    push dst
    push_s 0
    memcpy
    ; Copy 3 bytes from src to dst (non-overlapping)
    push src
    push dst
    push_s 3
    memcpy
    ; Print dst[0..2]
    push dst
    loadb
    sys 1
    push dst
    push_s 1
    add
    loadb
    sys 1
    push dst
    push_s 2
    add
    loadb
    sys 1
    ; Verify src not corrupted: print src[0..2]
    push src
    loadb
    sys 1
    push src
    push_s 1
    add
    loadb
    sys 1
    push src
    push_s 2
    add
    loadb
    sys 1
    push_s 10
    sys 1
    halt
.end
