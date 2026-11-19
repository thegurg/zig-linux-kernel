//! Virtual memory manager: our own 4-level page tables.
//!
//! M1c replaces Limine's page tables with a minimal set of our own:
//!   * the kernel image, mapped at its linked higher-half address;
//!   * a direct map of physical memory at Limine's HHDM offset, built from
//!     2 MiB pages so it only needs one page directory per GiB;
//!   * a reserved virtual range for the kernel heap (mapped lazily by
//!     `heap.zig`).
//!
//! Page-table frames come from the PMM and are accessed through the HHDM.
//! The HHDM is available both before the switch (Limine's tables) and after
//! it (our tables), so the same helper works throughout.

const std = @import("std");
const limine = @import("../limine.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const pmm = @import("pmm.zig");
const sync = @import("../sync.zig");

pub const page_size: u64 = 4096;
pub const huge_page_size: u64 = 2 * 1024 * 1024;

pub const present: u64 = 1 << 0;
pub const writable: u64 = 1 << 1;
pub const user: u64 = 1 << 2;
pub const write_through: u64 = 1 << 3;
pub const cache_disable: u64 = 1 << 4;
pub const accessed: u64 = 1 << 5;
pub const dirty: u64 = 1 << 6;
pub const huge: u64 = 1 << 7;
pub const global: u64 = 1 << 8;
/// No-execute leaf bit. EFER.NXE must be enabled before this bit is used.
pub const execute_disable: u64 = 1 << 63;

/// Physical-address bits in a 4-level paging entry (bits 12..51).
pub const address_mask: u64 = 0x000f_ffff_ffff_f000;

pub const kernel_rw: u64 = present | writable;
pub const kernel_ro: u64 = present;

/// Highest canonical address in the lower (user) half. The low half stays
/// empty in the kernel's own PML4 and is populated only in per-task roots.
pub const user_max_address: u64 = 0x0000_8000_0000_0000;
pub const user_rw: u64 = present | writable | user;
pub const user_ro: u64 = present | user;
/// User code: readable and executable, never writable.
pub const user_rx: u64 = present | user;
/// User read-only data: readable but not writable or executable.
pub const user_ro_nx: u64 = present | user | execute_disable;
/// User writable data and stacks: never executable.
pub const user_rw_nx: u64 = present | writable | user | execute_disable;

const PageTable = [512]u64;

const huge_1g_mask: u64 = ~@as(u64, (1 << 30) - 1);
const huge_2m_mask: u64 = ~@as(u64, (1 << 21) - 1);

pub const InitError = error{
    NoHhdm,
    NoExecutableAddress,
    FiveLevelPaging,
    BadKernelRange,
    BadKernelMapping,
    NoNoExecute,
    OutOfMemory,
};

pub const Stats = struct {
    active: bool,
    pml4_phys: u64,
    hhdm_offset: u64,
    kernel_phys_base: u64,
    kernel_virt_base: u64,
    kernel_bytes: u64,
    hhdm_bytes: u64,
};

extern const __kernel_start: u8;
extern const __kernel_requests_end: u8;
extern const __kernel_text_start: u8;
extern const __kernel_text_end: u8;
extern const __kernel_rodata_start: u8;
extern const __kernel_rodata_end: u8;
extern const __kernel_data_start: u8;
extern const __kernel_end: u8;

var hhdm_offset: u64 = 0;
var pml4_phys: u64 = 0;
var kernel_phys_base: u64 = 0;
var kernel_virt_base: u64 = 0;
var kernel_bytes: u64 = 0;
var initialized = false;
var address_spaces_created: u64 = 0;
var address_spaces_destroyed: u64 = 0;

/// Serializes page-table mutation once the APs can touch the VMM. The lock is
/// not taken during `init`, because the tables are still private to the BSP.
var table_lock: sync.IrqSpinLock = .{};

/// Called after a mapping is removed so the scheduler can invalidate remote
/// TLBs. The hook is invoked after `table_lock` is released, so a remote CPU
/// spinning on the VMM lock can still take the shootdown IPI.
pub const TlbShootdownFn = *const fn (virt: u64) void;
var tlb_shootdown_handler: ?TlbShootdownFn = null;

pub fn setTlbShootdownHandler(handler: TlbShootdownFn) void {
    tlb_shootdown_handler = handler;
}

pub fn init() InitError!void {
    if (initialized) return;

    // NX is a hard requirement for the user W^X policy. Enable it before any
    // page table is built so no NX leaf can be installed with NXE clear.
    if (!cpu.enableNx()) return error.NoNoExecute;

    hhdm_offset = limine.hhdmOffset() orelse return error.NoHhdm;
    const executable = limine.executableAddress() orelse return error.NoExecutableAddress;
    kernel_phys_base = executable.physical_base;
    kernel_virt_base = executable.virtual_base;

    // M1c builds 4-level tables. `paging_mode_request` asks Limine for 4-level
    // paging; the CR4 check catches a bootloader that ignored the request.
    if (limine.pagingMode()) |mode| {
        if (mode.mode != 0) return error.FiveLevelPaging;
    }
    if ((readCr4() & (1 << 12)) != 0) return error.FiveLevelPaging;

    const kernel_start = symbolAddress(&__kernel_start);
    const kernel_end = symbolAddress(&__kernel_end);
    if (kernel_start < kernel_virt_base or kernel_end <= kernel_start) {
        return error.BadKernelRange;
    }

    pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
    zeroFrame(pml4_phys);

    if (!mapHhdm()) return error.OutOfMemory;
    if (!mapKernelRange(kernel_start, symbolAddress(&__kernel_requests_end), kernel_rw)) {
        return error.OutOfMemory;
    }
    if (!mapKernelRange(symbolAddress(&__kernel_text_start), symbolAddress(&__kernel_text_end), kernel_ro)) {
        return error.OutOfMemory;
    }
    if (!mapKernelRange(symbolAddress(&__kernel_rodata_start), symbolAddress(&__kernel_rodata_end), kernel_ro)) {
        return error.OutOfMemory;
    }
    if (!mapKernelRange(symbolAddress(&__kernel_data_start), kernel_end, kernel_rw)) {
        return error.OutOfMemory;
    }

    // Catch a bad physical-base/offset before switching CR3, which would
    // otherwise turn the first instruction fetch into a triple fault.
    const check_virt = symbolAddress(&__kernel_text_start);
    const check_phys = kernel_phys_base + (check_virt - kernel_virt_base);
    if (translate(check_virt) != check_phys) return error.BadKernelMapping;
    if (translate(hhdm_offset) != 0) return error.BadKernelMapping;

    markFramebufferUncached();

    const first = std.mem.alignBackward(u64, kernel_start, page_size);
    const last = std.mem.alignForward(u64, kernel_end, page_size);
    kernel_bytes = last - first;

    enableWriteProtect();
    loadCr3(pml4_phys);
    flushGlobalTlb();
    initialized = true;
}

pub fn stats() Stats {
    return .{
        .active = initialized,
        .pml4_phys = pml4_phys,
        .hhdm_offset = hhdm_offset,
        .kernel_phys_base = kernel_phys_base,
        .kernel_virt_base = kernel_virt_base,
        .kernel_bytes = kernel_bytes,
        .hhdm_bytes = pmm.max_physical_address,
    };
}

pub fn currentPml4() u64 {
    return readCr3() & address_mask;
}

pub fn hhdmOffset() u64 {
    return hhdm_offset;
}

/// Physical address backing a kernel-image virtual address. Only valid inside
/// the image range; used by the smoke test to verify the kernel mapping.
pub fn kernelPhysical(virt: u64) ?u64 {
    if (virt < kernel_virt_base) return null;
    return kernel_phys_base + (virt - kernel_virt_base);
}

pub fn kernelPml4() u64 {
    return pml4_phys;
}

pub const AddressSpaceStats = struct {
    created: u64,
    destroyed: u64,
};

pub fn addressSpaceStats() AddressSpaceStats {
    return .{
        .created = @atomicLoad(u64, &address_spaces_created, .monotonic),
        .destroyed = @atomicLoad(u64, &address_spaces_destroyed, .monotonic),
    };
}

/// Create a private low-half PML4 whose high half shares the kernel's page
/// tables. The kernel/HHDM/heap mappings are all in the high half, so ring 3
/// address spaces only ever gain private low-half entries.
pub fn createAddressSpace() ?u64 {
    if (!initialized or pml4_phys == 0) return null;

    const phys = pmm.allocPage() orelse return null;
    zeroFrame(phys);

    const kernel_table = tableAt(pml4_phys);
    const user_table = tableAt(phys);
    for (256..512) |index| user_table[index] = kernel_table[index];

    _ = @atomicRmw(u64, &address_spaces_created, .Add, 1, .monotonic);
    return phys;
}

/// Free every low-half leaf and page table, then the PML4 itself. The caller
/// must have switched CR3 away from `root` first. Shares in the high half are
/// never touched.
pub fn destroyAddressSpace(root: u64) void {
    if (!initialized or root == 0 or root == pml4_phys or root % page_size != 0) return;

    const pml4 = tableAt(root);
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const pml4e = pml4[i];
        if ((pml4e & present) == 0) continue;
        if ((pml4e & huge) != 0) {
            _ = pmm.freePage(pml4e & address_mask);
            pml4[i] = 0;
            continue;
        }

        const pdpt = tableAt(pml4e & address_mask);
        var j: usize = 0;
        while (j < 512) : (j += 1) {
            const pdpte = pdpt[j];
            if ((pdpte & present) == 0) continue;
            if ((pdpte & huge) != 0) {
                _ = pmm.freePage(pdpte & address_mask);
                continue;
            }

            const pd = tableAt(pdpte & address_mask);
            var k: usize = 0;
            while (k < 512) : (k += 1) {
                const pde = pd[k];
                if ((pde & present) == 0) continue;
                if ((pde & huge) != 0) {
                    _ = pmm.freePage(pde & address_mask);
                    continue;
                }

                const pt = tableAt(pde & address_mask);
                for (pt) |pte| {
                    if ((pte & present) != 0) _ = pmm.freePage(pte & address_mask);
                }
                _ = pmm.freePage(pde & address_mask);
            }
            _ = pmm.freePage(pdpte & address_mask);
        }
        _ = pmm.freePage(pml4e & address_mask);
        pml4[i] = 0;
    }

    _ = pmm.freePage(root);
    _ = @atomicRmw(u64, &address_spaces_destroyed, .Add, 1, .monotonic);
}

/// Map a page in an arbitrary PML4. `flags` must include at least `present`;
/// user mappings also propagate the user bit through every intermediate table.
pub fn mapPageIn(root: u64, virt: u64, phys: u64, flags: u64) bool {
    if (!initialized) return mapPageInLocked(root, virt, phys, flags);

    const guard = table_lock.acquire();
    defer guard.release();
    return mapPageInLocked(root, virt, phys, flags);
}

fn mapPageInLocked(root: u64, virt: u64, phys: u64, flags: u64) bool {
    if (root == 0 or root % page_size != 0) return false;
    if (virt % page_size != 0 or phys % page_size != 0) return false;
    if ((phys & ~address_mask) != 0) return false;
    if ((flags & user) != 0 and virt >= user_max_address) return false;

    const extra = flags & user;
    const pml4 = tableAt(root);
    const pdpt_phys = ensureTableIn(&pml4[pml4Index(virt)], extra) orelse return false;
    const pdpt = tableAt(pdpt_phys);
    const pdpte = &pdpt[pdptIndex(virt)];
    if ((pdpte.* & present) != 0 and (pdpte.* & huge) != 0) return false;

    const pd_phys = ensureTableIn(pdpte, extra) orelse return false;
    const pd = tableAt(pd_phys);
    const pde = &pd[pdIndex(virt)];
    if ((pde.* & present) != 0 and (pde.* & huge) != 0) return false;

    const pt_phys = ensureTableIn(pde, extra) orelse return false;
    const pt = tableAt(pt_phys);
    const pte = &pt[ptIndex(virt)];
    if ((pte.* & present) != 0) return false;

    pte.* = (phys & address_mask) | flags | present;
    if (initialized and root == currentPml4()) invlpg(virt);
    return true;
}

pub fn mapUserPage(root: u64, virt: u64, phys: u64, writable_page: bool) bool {
    return mapUserPageFlags(root, virt, phys, if (writable_page) user_rw_nx else user_ro_nx);
}

/// Map one user leaf with explicit flags. `flags` must include `user`; NX is
/// preserved verbatim, so callers choose RX, RO+NX, or RW+NX.
pub fn mapUserPageFlags(root: u64, virt: u64, phys: u64, flags: u64) bool {
    return mapPageIn(root, virt, phys, flags | user);
}

pub fn mapPage(virt: u64, phys: u64, flags: u64) bool {
    return mapPageIn(pml4_phys, virt, phys, flags);
}

pub fn unmapPage(virt: u64) bool {
    var removed = false;
    if (initialized) {
        const guard = table_lock.acquire();
        removed = unmapPageLocked(virt);
        guard.release();
    } else {
        removed = unmapPageLocked(virt);
    }

    if (removed) {
        if (tlb_shootdown_handler) |handler| handler(virt);
    }
    return removed;
}

fn unmapPageLocked(virt: u64) bool {
    if (pml4_phys == 0 or virt % page_size != 0) return false;

    const pml4 = tableAt(pml4_phys);
    const pml4e = pml4[pml4Index(virt)];
    if ((pml4e & present) == 0 or (pml4e & huge) != 0) return false;

    const pdpt = tableAt(pml4e & address_mask);
    const pdpte = pdpt[pdptIndex(virt)];
    if ((pdpte & present) == 0 or (pdpte & huge) != 0) return false;

    const pd = tableAt(pdpte & address_mask);
    const pde = pd[pdIndex(virt)];
    if ((pde & present) == 0 or (pde & huge) != 0) return false;

    const pt = tableAt(pde & address_mask);
    const pte = &pt[ptIndex(virt)];
    if ((pte.* & present) == 0) return false;

    pte.* = 0;
    if (initialized) invlpg(virt);
    return true;
}

pub fn translate(virt: u64) ?u64 {
    return translateIn(pml4_phys, virt);
}

/// Translate through an arbitrary PML4 root.
pub fn translateIn(root: u64, virt: u64) ?u64 {
    return translateImpl(root, virt, false);
}

/// Translate a low-half user address and require the user bit on every level.
pub fn translateUserIn(root: u64, virt: u64) ?u64 {
    return translateImpl(root, virt, true);
}

fn translateImpl(root: u64, virt: u64, require_user: bool) ?u64 {
    if (root == 0) return null;

    const need: u64 = if (require_user) present | user else present;
    const pml4 = tableAt(root);
    const pml4e = pml4[pml4Index(virt)];
    if ((pml4e & need) != need) return null;

    const pdpt = tableAt(pml4e & address_mask);
    const pdpte = pdpt[pdptIndex(virt)];
    if ((pdpte & need) != need) return null;
    if ((pdpte & huge) != 0) {
        return (pdpte & address_mask & huge_1g_mask) + (virt & ~huge_1g_mask);
    }

    const pd = tableAt(pdpte & address_mask);
    const pde = pd[pdIndex(virt)];
    if ((pde & need) != need) return null;
    if ((pde & huge) != 0) {
        return (pde & address_mask & huge_2m_mask) + (virt & ~huge_2m_mask);
    }

    const pt = tableAt(pde & address_mask);
    const pte = pt[ptIndex(virt)];
    if ((pte & need) != need) return null;
    return (pte & address_mask) + (virt & (page_size - 1));
}

pub const UserCopyError = error{ InvalidUserRange, NotMapped };

/// Reject addresses outside the canonical low half, including ranges that wrap
/// past it. A zero length is always accepted.
pub fn validateUserRange(virt: u64, len: usize) UserCopyError!void {
    if (len == 0) return;
    if (virt >= user_max_address) return error.InvalidUserRange;
    if (len > user_max_address - virt) return error.InvalidUserRange;
}

/// Copy from a user address into kernel memory. Every page is translated and
/// validated before it is read, so an unmapped or non-canonical pointer returns
/// an error instead of faulting in the kernel.
pub fn copyFromUser(dst: []u8, src: u64) UserCopyError!void {
    try validateUserRange(src, dst.len);
    if (dst.len == 0) return;

    const root = currentPml4();
    var copied: usize = 0;
    while (copied < dst.len) {
        const virt = src + @as(u64, @intCast(copied));
        const phys = translateUserIn(root, virt) orelse return error.NotMapped;
        const room: usize = @intCast(page_size - (virt & (page_size - 1)));
        const chunk = @min(dst.len - copied, room);
        const source: [*]const u8 = @ptrFromInt(hhdm_offset + phys);
        @memcpy(dst[copied..][0..chunk], source[0..chunk]);
        copied += chunk;
    }
}

/// Copy from kernel memory to a validated user address.
pub fn copyToUser(dst: u64, src: []const u8) UserCopyError!void {
    try validateUserRange(dst, src.len);
    if (src.len == 0) return;

    const root = currentPml4();
    var copied: usize = 0;
    while (copied < src.len) {
        const virt = dst + @as(u64, @intCast(copied));
        const phys = translateUserIn(root, virt) orelse return error.NotMapped;
        const room: usize = @intCast(page_size - (virt & (page_size - 1)));
        const chunk = @min(src.len - copied, room);
        const target: [*]u8 = @ptrFromInt(hhdm_offset + phys);
        @memcpy(target[0..chunk], src[copied..][0..chunk]);
        copied += chunk;
    }
}

fn mapHhdm() bool {
    if (hhdm_offset % (1 << 30) != 0) return false;

    const pml4 = tableAt(pml4_phys);
    const pdpt_phys = ensureTable(&pml4[pml4Index(hhdm_offset)]) orelse return false;
    const pdpt = tableAt(pdpt_phys);

    var phys: u64 = 0;
    while (phys < pmm.max_physical_address) : (phys += 1 << 30) {
        const pdpt_index = pdptIndex(hhdm_offset + phys);
        if ((pdpt[pdpt_index] & present) != 0) return false;

        const pd_phys = allocTable() orelse return false;
        pdpt[pdpt_index] = pd_phys | present | writable;
        const pd = tableAt(pd_phys);

        var index: usize = 0;
        while (index < 512) : (index += 1) {
            const chunk = phys + @as(u64, @intCast(index)) * huge_page_size;
            if (chunk >= pmm.max_physical_address) break;
            pd[index] = chunk | present | writable | huge;
        }
    }
    return true;
}

fn mapKernelRange(start: u64, end: u64, flags: u64) bool {
    if (end <= start) return true;
    if (start < kernel_virt_base) return false;

    const first = std.mem.alignBackward(u64, start, page_size);
    const last = std.mem.alignForward(u64, end, page_size);

    var virt = first;
    while (virt < last) : (virt += page_size) {
        const phys = kernel_phys_base + (virt - kernel_virt_base);
        if (!mapPage(virt, phys, flags)) return false;
    }
    return true;
}

/// Mark the 2 MiB HHDM chunk(s) covering `[phys, phys + size)` uncached.
///
/// The HHDM is built from 2 MiB pages, so the whole chunk containing the LAPIC
/// window is marked with PCD. This is only called while the mapping is still
/// local to the bootstrap processor (LAPIC init), but it also handles already
/// split page tables for completeness.
pub fn markUncached(phys: u64, size: u64) bool {
    if (pml4_phys == 0 or size == 0) return false;
    if (phys >= pmm.max_physical_address) return false;

    const first = std.mem.alignBackward(u64, phys, huge_page_size);
    const last = std.mem.alignForward(u64, phys +| size, huge_page_size);
    var changed = false;

    var chunk = first;
    while (chunk < last and chunk < pmm.max_physical_address) : (chunk += huge_page_size) {
        const virt = hhdm_offset + chunk;
        const pml4 = tableAt(pml4_phys);
        const pml4e = pml4[pml4Index(virt)];
        if ((pml4e & present) == 0) continue;

        const pdpt = tableAt(pml4e & address_mask);
        const pdpte = pdpt[pdptIndex(virt)];
        if ((pdpte & present) == 0 or (pdpte & huge) != 0) continue;

        const pd = tableAt(pdpte & address_mask);
        const pde = &pd[pdIndex(virt)];
        if ((pde.* & present) == 0) continue;

        if ((pde.* & huge) != 0) {
            pde.* |= cache_disable;
            changed = true;
            continue;
        }

        const pt = tableAt(pde.* & address_mask);
        for (pt[0..]) |*pte| {
            if ((pte.* & present) != 0) {
                pte.* |= cache_disable;
                changed = true;
            }
        }
    }

    if (changed and initialized) invlpg(hhdm_offset + phys);
    return true;
}

fn markFramebufferUncached() void {
    const fb = limine.framebuffer() orelse return;
    const address = fb.address orelse return;
    const fb_virt = @intFromPtr(address);
    if (fb_virt < hhdm_offset) return;

    const fb_phys = fb_virt - hhdm_offset;
    if (fb_phys >= pmm.max_physical_address) return;
    const size = fb.pitch * fb.height;
    if (size == 0) return;

    const first = std.mem.alignBackward(u64, fb_phys, huge_page_size);
    const last = std.mem.alignForward(u64, fb_phys + size, huge_page_size);

    var phys = first;
    while (phys < last and phys < pmm.max_physical_address) : (phys += huge_page_size) {
        const virt = hhdm_offset + phys;
        const pml4 = tableAt(pml4_phys);
        const pml4e = pml4[pml4Index(virt)];
        if ((pml4e & present) == 0) continue;

        const pdpt = tableAt(pml4e & address_mask);
        const pdpte = pdpt[pdptIndex(virt)];
        if ((pdpte & present) == 0 or (pdpte & huge) != 0) continue;

        const pd = tableAt(pdpte & address_mask);
        const pde = &pd[pdIndex(virt)];
        if ((pde.* & present) == 0 or (pde.* & huge) == 0) continue;
        pde.* |= cache_disable;
    }
}

fn ensureTable(entry: *u64) ?u64 {
    return ensureTableIn(entry, 0);
}

/// Ensure a next-level table exists. `extra` carries the user bit for user
/// mappings; it is applied to newly allocated tables and OR-ed into tables that
/// already exist, so user pages cannot hide behind supervisor-only parents.
fn ensureTableIn(entry: *u64, extra: u64) ?u64 {
    if ((entry.* & present) != 0) {
        if ((entry.* & huge) != 0) return null;
        if ((extra & user) != 0) entry.* |= user;
        return entry.* & address_mask;
    }

    const phys = allocTable() orelse return null;
    entry.* = phys | present | writable | extra;
    return phys;
}

fn allocTable() ?u64 {
    const phys = pmm.allocPage() orelse return null;
    zeroFrame(phys);
    return phys;
}

fn tableAt(phys: u64) *PageTable {
    return @ptrFromInt(hhdm_offset + phys);
}

fn zeroFrame(phys: u64) void {
    @memset(tableAt(phys)[0..], 0);
}

fn symbolAddress(symbol: *const u8) u64 {
    return @intCast(@intFromPtr(symbol));
}

fn pml4Index(virt: u64) usize {
    return @intCast((virt >> 39) & 0x1ff);
}

fn pdptIndex(virt: u64) usize {
    return @intCast((virt >> 30) & 0x1ff);
}

fn pdIndex(virt: u64) usize {
    return @intCast((virt >> 21) & 0x1ff);
}

fn ptIndex(virt: u64) usize {
    return @intCast((virt >> 12) & 0x1ff);
}

fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[value]"
        : [value] "=r" (-> u64),
    );
}

fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
}

fn loadCr3(value: u64) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// Install a PML4 root. A CR3 write flushes non-global TLB entries; the
/// high-half kernel mappings are shared and may stay global.
pub fn switchAddressSpace(root: u64) void {
    if (root == 0 or root % page_size != 0) return;
    loadCr3(root);
}

pub fn switchToKernelAddressSpace() void {
    if (pml4_phys != 0) loadCr3(pml4_phys);
}

fn writeCr4(value: u64) void {
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// A CR3 write does not evict global translations. Limine may have used them
/// for the kernel/HHDM, so clear PGE once to flush the global TLB as well.
fn flushGlobalTlb() void {
    const cr4 = readCr4();
    if ((cr4 & (1 << 7)) != 0) {
        writeCr4(cr4 & ~@as(u64, 1 << 7));
        writeCr4(cr4);
    }
}

fn invlpg(virt: u64) void {
    asm volatile ("invlpg (%[virt])"
        :
        : [virt] "r" (virt),
        : .{ .memory = true });
}

fn enableWriteProtect() void {
    var cr0: u64 = asm volatile ("mov %%cr0, %[value]"
        : [value] "=r" (-> u64),
    );
    cr0 |= 1 << 16;
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (cr0),
        : .{ .memory = true });
}
