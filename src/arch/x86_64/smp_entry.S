/* Application-processor entry stub for Limine's MP protocol.
 *
 * Limine hands control to `ap_entry` with RDI pointing at this CPU's
 * `limine_mp_info`, using Limine's page tables and boot stack. Switch to the
 * kernel-owned stack recorded in `extra_argument` (offset 24), then switch to
 * the kernel's PML4 and call the Zig AP main routine.
 */

.text
.globl ap_entry
.type ap_entry, @function
ap_entry:
    movq 24(%rdi), %rax        /* extra_argument: per-CPU descriptor */
    movq %rdi, %rsi            /* second arg: limine_mp_info */
    movq (%rax), %rsp          /* first field: kernel stack top */
    movq %rax, %rdi            /* first arg: per-CPU descriptor */
    movq ap_kernel_cr3(%rip), %rax
    movq %rax, %cr3
    cld
    call ap_main

1:
    cli
    hlt
    jmp 1b
.size ap_entry, .-ap_entry

.section .note.GNU-stack,"",@progbits
