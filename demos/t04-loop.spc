; t04-loop.spc — Loop and procedure call test
; Expected output: 54321\n

.proc main 0
    push 5
    call countdown
    push_s 10
    sys 1
    halt
.end

.proc countdown 1
    loada 0
    storel 0
loop:
    loadl 0
    dup
    jz done
    ; Print digit: value + 48
    push_s 48
    add
    sys 1
    ; Decrement
    loadl 0
    push 1
    sub
    storel 0
    jmp loop
done:
    drop
    ret 1
.end
