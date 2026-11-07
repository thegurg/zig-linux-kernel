/* Application-processor entry stub for Limine's MP protocol.
 *
 * Limine hands control to `ap_entry` with RDI pointing at this CPU's
 * `limine_mp_info`, using Limine's page tables and boot stack. The stub:
 *   1. switches to the kernel-owned stack recorded in `extra_argument`;
 *   2. enables SSE and CR0.WP before entering any Zig code, because CR4 and
 *      CR0 are per-CPU and the compiler may emit SSE as soon as `ap_main`
 *      starts;
 *   3. switches to the kernel PML4 and flushes global translations (a CR3
 *      write alone does not evict them);
 *   4. tail-calls the Zig AP main routine.
 */

.text
.globl ap_entry
.type ap_entry, @function
ap_entry:
    movq 24(%rdi), %rax        /* extra_argument: per-CPU descriptor */
    movq %rdi, %rsi            /* second arg: limine_mp_info */
    movq (%rax), %rsp          /* first field: kernel stack top */
    movq %rax, %rdi            /* first arg: per-CPU descriptor */

    /* Enable SSE: clear CR0.EM/TS, set CR0.MP/NE, then CR4.OSFXSR/OSXMMEXCPT. */
    movq %cr0, %rax
    andq $-13, %rax            /* ~(1 << 2 | 1 << 3) */
    orq  $34, %rax             /* 1 << 1 | 1 << 5 */
    movq %rax, %cr0

    movq %cr4, %rax
    orq  $1536, %rax           /* 1 << 9 | 1 << 10 */
    movq %rax, %cr4
    fninit

    /* Match the BSP: enforce read-only pages in ring 0. */
    movq %cr0, %rax
    orq  $65536, %rax          /* 1 << 16 */
    movq %rax, %cr0

    /* CR3 writes do not evict global translations. Clear CR4.PGE across the
     * switch, then restore the original CR4 value (which may or may not have
     * PGE set). */
    movq %cr4, %rcx
    movq %rcx, %rax
    andq $-129, %rax           /* ~(1 << 7) */
    movq %rax, %cr4
    movq ap_kernel_cr3(%rip), %rax
    movq %rax, %cr3
    movq %rcx, %cr4

    cld
    call ap_main

1:
    cli
    hlt
    jmp 1b
.size ap_entry, .-ap_entry

.section .note.GNU-stack,"",@progbits
