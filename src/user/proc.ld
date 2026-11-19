/* Link the M17 process test program as a general ET_EXEC image.
 * Code, read-only data, and writable data each get their own page-aligned
 * PT_LOAD segment so the loader can apply RX, RO+NX, and RW+NX permissions. */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);   /* read + execute */
    rodata PT_LOAD FLAGS(4); /* read */
    data PT_LOAD FLAGS(6);   /* read + write */
}

SECTIONS
{
    . = 0x400000;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(0x1000);
    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(0x1000);
    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data
}
