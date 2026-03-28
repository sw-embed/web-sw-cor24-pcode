; t03-globals.spc — Global variable test
; Expected output: AB\n

.global counter 1

.proc main 0
    ; Store 65 ('A') in counter
    push 65
    push counter
    store
    ; Load and print it
    push counter
    load
    sys 1
    ; Increment counter
    push counter
    load
    push 1
    add
    push counter
    store
    ; Load and print 'B'
    push counter
    load
    sys 1
    ; Newline
    push_s 10
    sys 1
    halt
.end
