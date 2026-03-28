; t02-arith.spc — Arithmetic test
; Expected output: *\n

.proc main 0
    push 7
    push 6
    mul
    sys 1
    push_s 10
    sys 1
    halt
.end
