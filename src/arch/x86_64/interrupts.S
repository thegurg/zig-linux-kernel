/* CPU exception entry stubs.
 *
 * Every stub normalises the stack frame to:
 *     [rsp+0]  vector
 *     [rsp+8]  error code (synthesised as zero when the CPU pushes none)
 *     [rsp+16] RIP
 *     ...
 * then jumps to isr_common, which preserves the caller-saved registers and
 * calls the Zig dispatcher. The dispatcher may return (breakpoint) or never
 * return (fatal exception).
 */

.text

.macro ISR_NOERR num
    .globl isr_\num
isr_\num:
    pushq $0
    pushq $\num
    jmp isr_common
.endm

.macro ISR_ERR num
    .globl isr_\num
isr_\num:
    pushq $\num
    jmp isr_common
.endm

ISR_NOERR 0    /* #DE */
ISR_NOERR 1    /* #DB */
ISR_NOERR 2    /* NMI */
ISR_NOERR 3    /* #BP */
ISR_NOERR 4    /* #OF */
ISR_NOERR 5    /* #BR */
ISR_NOERR 6    /* #UD */
ISR_NOERR 7    /* #NM */
ISR_ERR   8    /* #DF */
ISR_NOERR 9
ISR_ERR   10   /* #TS */
ISR_ERR   11   /* #NP */
ISR_ERR   12   /* #SS */
ISR_ERR   13   /* #GP */
ISR_ERR   14   /* #PF */
ISR_NOERR 15
ISR_NOERR 16   /* #MF */
ISR_ERR   17   /* #AC */
ISR_NOERR 18   /* #MC */
ISR_NOERR 19   /* #XM */
ISR_NOERR 20   /* #VE */
ISR_ERR   21   /* #CP */
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28   /* #HV */
ISR_ERR   29   /* #VC */
ISR_ERR   30   /* #SX */
ISR_NOERR 31

.globl isr_common
.type isr_common, @function
isr_common:
    cld
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12

    /* C ABI requires 16-byte stack alignment at the call site. r12 holds the
     * saved-register base, and the dispatcher preserves r12 as a callee-saved
     * register. The frame starts 10 registers (80 bytes) above it. */
    movq %rsp, %r12
    andq $-16, %rsp
    leaq 80(%r12), %rdi
    call isr_dispatch

    movq %r12, %rsp
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rax
    addq $16, %rsp         /* drop vector + error code */
    iretq
.size isr_common, .-isr_common

.section .rodata
.align 8
.globl isr_stub_table
isr_stub_table:
    .quad isr_0,  isr_1,  isr_2,  isr_3,  isr_4,  isr_5,  isr_6,  isr_7
    .quad isr_8,  isr_9,  isr_10, isr_11, isr_12, isr_13, isr_14, isr_15
    .quad isr_16, isr_17, isr_18, isr_19, isr_20, isr_21, isr_22, isr_23
    .quad isr_24, isr_25, isr_26, isr_27, isr_28, isr_29, isr_30, isr_31

.section .note.GNU-stack,"",@progbits
