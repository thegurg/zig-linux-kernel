/* M16 test-only user program.
 *
 * The kernel enters `_start` in ring 3 with the test mode in RDI. The program
 * uses only the `int 0x80` syscall ABI documented in src/syscall.zig and never
 * returns: every path ends in the exit syscall.
 */

.set SYS_WRITE,      1
.set SYS_EXIT,       2
.set SYS_YIELD,      3
.set SYS_SLEEP_MS,   4
.set SYS_GETPID,     5

.set USER_DATA,      0x500000
.set USER_EXTRA,     0x600000

.section .text
.global _start
.type _start, @function
_start:
    movq %rdi, %r12                 /* RDI: initial test mode */
    cmpq $0, %r12
    je mode_basic
    cmpq $1, %r12
    je mode_null
    cmpq $2, %r12
    je mode_data
    cmpq $3, %r12
    je mode_spin
    cmpq $4, %r12
    je mode_badptr
    cmpq $5, %r12
    je mode_probe
    cmpq $6, %r12
    je mode_extra
    cmpq $7, %r12
    je mode_extra_wait
    movq $99, %rdi
    call sys_exit

/* write(1, message, length), then getpid, yield, and sleepMs. */
mode_basic:
    leaq message_write(%rip), %rdi
    movq $message_write_end - message_write, %rsi
    call sys_write
    testq %rax, %rax
    js failure

    call sys_getpid
    testq %rax, %rax
    jle failure

    call sys_yield
    movq $10, %rdi
    call sys_sleep_ms

    leaq message_slept(%rip), %rdi
    movq $message_slept_end - message_slept, %rsi
    call sys_write
    testq %rax, %rax
    js failure

    movq $42, %rdi
    call sys_exit

/* Dereference NULL. The kernel must kill this task, not the whole system. */
mode_null:
    xorq %rax, %rax
    movq (%rax), %rax
    movq $98, %rdi
    call sys_exit

/* Exit with the private data page's first qword. */
mode_data:
    movabsq $USER_DATA, %rax
    movq (%rax), %rax
    movq %rax, %rdi
    call sys_exit

/* Busy-loop without syscalls until the kernel writes the stop flag. */
mode_spin:
    movabsq $USER_DATA, %r13
    movq $0, (%r13)
1:
    incq (%r13)
    movq 8(%r13), %rax
    testq %rax, %rax
    jz 1b
    xorq %rdi, %rdi
    call sys_exit

/* Invalid user pointers must fail cleanly and leave the task alive. */
mode_badptr:
    movq $1, %rax
    movq $1, %rdi
    movq $0xdead0000, %rsi
    movq $4, %rdx
    int $0x80
    testq %rax, %rax
    jns failure

    movq $1, %rax
    movq $1, %rdi
    movabsq $0x0000800000000000, %rsi
    movq $4, %rdx
    int $0x80
    testq %rax, %rax
    jns failure

    leaq message_badptr(%rip), %rdi
    movq $message_badptr_end - message_badptr, %rsi
    call sys_write
    testq %rax, %rax
    js failure

    xorq %rdi, %rdi
    call sys_exit

/* Read an address mapped only in the other task's address space. */
mode_probe:
    movabsq $USER_EXTRA, %rax
    movq (%rax), %rax
    movq $97, %rdi
    call sys_exit

/* Exit with this task's private extra page. */
mode_extra:
    movabsq $USER_EXTRA, %rax
    movq (%rax), %rax
    movq %rax, %rdi
    call sys_exit

/* Read the extra page, stay alive long enough for another task to probe it,
 * then exit with the value. */
mode_extra_wait:
    movabsq $USER_EXTRA, %rax
    movq (%rax), %r13
    movq $100, %rdi
    call sys_sleep_ms
    movq %r13, %rdi
    call sys_exit

failure:
    movq $99, %rdi
    call sys_exit

/* RDI = buffer, RSI = length. Returns the syscall result in RAX. */
sys_write:
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq $1, %rdi
    movq $SYS_WRITE, %rax
    int $0x80
    ret

sys_getpid:
    movq $SYS_GETPID, %rax
    int $0x80
    ret

sys_yield:
    movq $SYS_YIELD, %rax
    int $0x80
    ret

sys_sleep_ms:
    movq $SYS_SLEEP_MS, %rax
    int $0x80
    ret

sys_exit:
    movq $SYS_EXIT, %rax
    int $0x80
1:
    hlt
    jmp 1b

.section .rodata
message_write:
    .ascii "m16: user write ok\n"
message_write_end:
message_slept:
    .ascii "m16: user sleep ok\n"
message_slept_end:
message_badptr:
    .ascii "m16: user badptr rejected\n"
message_badptr_end:

.section .note.GNU-stack,"",@progbits
