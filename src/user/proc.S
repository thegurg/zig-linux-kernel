/* M17 process test program.
 *
 * The kernel enters `_start` with a SysV-style stack:
 *   argc, argv[0..argc-1], NULL, envp[0..], NULL
 * and 16-byte alignment. The program validates the stack layout, then selects
 * a test mode from the first character of argv[1]. Every path exits through
 * the int 0x80 ABI from src/syscall.zig.
 */

.set SYS_WRITE,      1
.set SYS_EXIT,       2
.set SYS_SLEEP_MS,   4

.set STACK_GUARD,    0x7fffa000

.section .text
.global _start
.type _start, @function
_start:
    movq (%rsp), %r12               /* argc */
    leaq 8(%rsp), %r13              /* argv */
    leaq 8(%r13,%r12,8), %r15       /* envp = &argv[argc + 1] */

    cmpq $2, %r12
    jl failure

    cmpq $0, (%r13,%r12,8)          /* argv[argc] == NULL */
    jne failure
    cmpq $0, (%r13)                 /* argv[0] != NULL */
    je failure

    movq 8(%r13), %rax              /* argv[1] */
    testq %rax, %rax
    jz failure
    movzbl (%rax), %r14d

    cmpb $'b', %r14b
    je mode_basic
    cmpb $'s', %r14b
    je mode_sleep
    cmpb $'i', %r14b
    je mode_instant
    cmpb $'n', %r14b
    je mode_nx
    cmpb $'g', %r14b
    je mode_guard
    jmp failure

/* Print argv[0], argv[1], and envp[0], then exit 42. */
mode_basic:
    leaq message_argv(%rip), %rdi
    call write_cstr
    movq (%r13), %rdi
    call write_cstr
    leaq message_comma(%rip), %rdi
    call write_cstr
    movq 8(%r13), %rdi
    call write_cstr
    leaq message_env(%rip), %rdi
    call write_cstr
    movq (%r15), %rdi
    call write_cstr
    leaq message_newline(%rip), %rdi
    call write_cstr

    movq $42, %rdi
    call sys_exit

/* Sleep long enough for a wait timeout to be observed. */
mode_sleep:
    movq $50, %rdi
    call sys_sleep_ms
    movq $43, %rdi
    call sys_exit

mode_instant:
    movq $44, %rdi
    call sys_exit

/* Jump into a writable, non-executable data page. */
mode_nx:
    leaq message_nx(%rip), %rdi
    call write_cstr
    leaq nx_payload(%rip), %rax
    jmp *%rax

/* Write to the unmapped guard page below the process stack. */
mode_guard:
    leaq message_guard(%rip), %rdi
    call write_cstr
    movabsq $STACK_GUARD, %rax
    movq $1, (%rax)
    movq $95, %rdi
    call sys_exit

failure:
    movq $99, %rdi
    call sys_exit

/* RDI = NUL-terminated string. Uses the write syscall. */
write_cstr:
    movq %rdi, %rsi
    xorq %rdx, %rdx
1:
    cmpb $0, (%rsi,%rdx)
    je 2f
    incq %rdx
    jmp 1b
2:
    movq $1, %rdi
    movq $SYS_WRITE, %rax
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
message_argv:
    .asciz "m17: proc argv="
message_comma:
    .asciz ","
message_env:
    .asciz " env="
message_newline:
    .asciz "\n"
message_nx:
    .asciz "m17: proc nx attempt\n"
message_guard:
    .asciz "m17: proc guard attempt\n"

.section .data
/* This byte lives in an RW+NX segment. Fetching it must fault. */
.align 8
nx_payload:
    .byte 0xf4

.section .note.GNU-stack,"",@progbits
