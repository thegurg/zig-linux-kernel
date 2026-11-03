/* zig-kernel linker script for x86_64 higher-half with Limine.
 *
 * Every PT_LOAD segment starts on its own page and carries its own permissions:
 * Limine rejects images where segments with different permissions share a page
 * (the .limine_requests section must stay writable because Limine stores
 * response pointers there).
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
    limine PT_LOAD FLAGS(6); /* read + write */
    text PT_LOAD FLAGS(5);   /* read + execute */
    rodata PT_LOAD FLAGS(4); /* read */
    data PT_LOAD FLAGS(6);   /* read + write */
}

SECTIONS
{
    . = 0xffffffff80000000;
    __kernel_start = .;

    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :limine
    __kernel_requests_end = .;

    . = ALIGN(0x1000);
    __kernel_text_start = .;
    .text : {
        *(.text .text.*)
    } :text
    __kernel_text_end = .;

    . = ALIGN(0x1000);
    __kernel_rodata_start = .;
    .rodata : {
        *(.rodata .rodata.*)
        *(.rodata.cst*)
    } :rodata
    __kernel_rodata_end = .;

    . = ALIGN(0x1000);
    __kernel_data_start = .;
    .data : {
        *(.data .data.*)
        *(.data.rel.ro*)
    } :data

    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    } :data
    __kernel_end = .;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
