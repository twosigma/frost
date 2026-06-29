/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * Directed reproducer for the procfs /proc lookup failure seen on hardware.
 *
 * The Linux failure shows proc_get_inode() receiving a pointer that looks like
 * a proc_dir_entry.subdir_node, not the proc_dir_entry base. The hot epilogue in
 * pde_subdir_find() subtracts the rb_node offset from s1, then returns it via
 * a0 shortly before restoring the caller's s1.
 */

#include <stdint.h>

#include "uart.h"

#define ITERATIONS 64u
#define PDE_VIS_ITERATIONS 16u
#define PDE_VIS_CHURN_BYTES (16u * 1024u)
#define PDE_SUBDIR_NODE_OFFSET 80u
#define PDE_SUBDIR_ROOT_OFFSET 76u
#define PDE_REFCOUNT_OFFSET 4u
#define PDE_NLINK_OFFSET 48u
#define PDE_UID_OFFSET 52u
#define PDE_GID_OFFSET 56u
#define PDE_NAME_OFFSET 92u
#define PDE_MODE_OFFSET 96u
#define PDE_FLAGS_OFFSET 98u
#define PDE_NAMELEN_OFFSET 99u
#define PDE_INLINE_NAME_OFFSET 100u
#define RB_RIGHT_OFFSET 4u
#define RB_LEFT_OFFSET 8u
#define RB_NAME_OFFSET 12u
#define RB_NAMELEN_OFFSET 19u
#define MULTI_PDE_COUNT 5u
#define PDE_MODE_REG_0444 0x8124u

static uint8_t root_pde[128] __attribute__((aligned(64)));
static uint8_t entry_pde[128] __attribute__((aligned(64)));
static uint8_t multi_pdes[MULTI_PDE_COUNT][128] __attribute__((aligned(64)));
static uint8_t fake_dir[32] __attribute__((aligned(64)));
static uint8_t fake_dentry[40] __attribute__((aligned(64)));
static uint8_t s2l_area[64 * 1024] __attribute__((aligned(64)));
static const char version_name[] = "version";
static const char cmdline_name[] = "cmdline";
static const char loadavg_name[] = "loadavg";
static const char maps_name[] = "maps";
static const char meminfo_name[] = "meminfo";

static volatile uintptr_t observed_de;
static volatile uintptr_t observed_sb;
static volatile uint32_t observed_ref_old;
static volatile uint32_t observed_mode;
static volatile uint32_t observed_namelen;

static void churn_cache(uint32_t seed);

__attribute__((noinline, naked, used, aligned(4))) static uintptr_t
epilogue_repro(uintptr_t node, uintptr_t salt2, uintptr_t salt3)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sw   s0, 24(sp)\n"
                     "sw   ra, 28(sp)\n"
                     "sw   s1, 20(sp)\n"
                     "sw   s2, 16(sp)\n"
                     "sw   s3, 12(sp)\n"
                     "addi s0, sp, 32\n"
                     "mv   s1, a0\n"
                     "mv   s2, a1\n"
                     "mv   s3, a2\n"
                     "xor  a5, s2, s3\n"
                     "andi a5, a5, 1\n"
                     "beqz a5, 1f\n"
                     "addi s1, s1, 0\n"
                     "1:\n"
                     "lw   ra, 28(sp)\n"
                     "lw   s0, 24(sp)\n"
                     "addi s1, s1, -80\n"
                     "lw   s2, 16(sp)\n"
                     "lw   s3, 12(sp)\n"
                     "mv   a0, s1\n"
                     "lw   s1, 20(sp)\n"
                     "addi sp, sp, 32\n"
                     "ret\n");
}

__attribute__((noinline, naked, used, aligned(4))) static uintptr_t
epilogue_direct_a0(uintptr_t node, uintptr_t salt2, uintptr_t salt3)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sw   s0, 24(sp)\n"
                     "sw   ra, 28(sp)\n"
                     "sw   s1, 20(sp)\n"
                     "sw   s2, 16(sp)\n"
                     "sw   s3, 12(sp)\n"
                     "addi s0, sp, 32\n"
                     "mv   s1, a0\n"
                     "mv   s2, a1\n"
                     "mv   s3, a2\n"
                     "xor  a5, s2, s3\n"
                     "andi a5, a5, 1\n"
                     "beqz a5, 1f\n"
                     "addi s1, s1, 0\n"
                     "1:\n"
                     "lw   ra, 28(sp)\n"
                     "lw   s0, 24(sp)\n"
                     "addi a0, s1, -80\n"
                     "lw   s2, 16(sp)\n"
                     "lw   s3, 12(sp)\n"
                     "lw   s1, 20(sp)\n"
                     "addi sp, sp, 32\n"
                     "ret\n");
}

static volatile uintptr_t sink;
static volatile uint32_t s2l_sink;

__attribute__((noinline, used)) static uint32_t halfword_s2l(uint8_t *ptr, uint32_t value)
{
    uint32_t out;

    __asm__ volatile("sh  %[value], 0(%[ptr])\n"
                     "lhu %[out], 0(%[ptr])\n"
                     : [out] "=r"(out)
                     : [ptr] "r"(ptr), [value] "r"(value)
                     : "memory");
    return out;
}

__attribute__((noinline, used)) static uint32_t amo_halfword_s2l(uint8_t *ptr, uint32_t value)
{
    uint32_t out;

    __asm__ volatile("li t0, 1\n"
                     "addi t1, %[ptr], 4\n"
                     "amoadd.w zero, t0, (t1)\n"
                     "sh  %[value], 0(%[ptr])\n"
                     "lhu %[out], 0(%[ptr])\n"
                     : [out] "=r"(out)
                     : [ptr] "r"(ptr), [value] "r"(value)
                     : "t0", "t1", "memory");
    return out;
}

__attribute__((noinline, used)) static uint32_t word_s2l(uint8_t *ptr, uint32_t value)
{
    uint32_t out;

    __asm__ volatile("sw %[value], 0(%[ptr])\n"
                     "lw %[out], 0(%[ptr])\n"
                     : [out] "=r"(out)
                     : [ptr] "r"(ptr), [value] "r"(value)
                     : "memory");
    return out;
}

__attribute__((noinline, used)) static int
hazard_memcmp(const void *lhs, const void *rhs, uint32_t len)
{
    const uint8_t *a = (const uint8_t *) lhs;
    const uint8_t *b = (const uint8_t *) rhs;

    for (uint32_t i = 0; i < len; i++) {
        if (a[i] != b[i]) {
            return (int) a[i] - (int) b[i];
        }
    }
    return 0;
}

__attribute__((noinline, used)) static uintptr_t fake_proc_get_inode(uintptr_t sb, uintptr_t de)
{
    uint32_t mode;

    __asm__ volatile("lhu %0, 96(%1)" : "=r"(mode) : "r"(de) : "memory");
    observed_sb = sb;
    observed_de = de;
    observed_mode = mode;
    observed_namelen = *(volatile uint8_t *) (uintptr_t) (de + PDE_NAMELEN_OFFSET);
    return 0x12345678u;
}

__attribute__((noinline, naked, used, aligned(4))) static void pde_init_version_asm(uintptr_t de)
{
    __asm__ volatile("addi t0, a0, 100\n"
                     "sw   t0, 92(a0)\n"
                     "li   t1, 0x73726576\n" /* "vers" */
                     "sw   t1, 100(a0)\n"
                     "li   t1, 0x006e6f69\n" /* "ion\\0" */
                     "sw   t1, 104(a0)\n"
                     "li   t1, 1\n"
                     "sw   t1, 4(a0)\n"
                     "addi t2, a0, 8\n"
                     "sw   t2, 8(a0)\n"
                     "li   t3, 0x8124\n"
                     "sh   t3, 96(a0)\n"
                     "sw   t1, 48(a0)\n"
                     "sw   zero, 76(a0)\n"
                     "li   t4, 7\n"
                     "sb   t4, 99(a0)\n"
                     "sw   t2, 12(a0)\n"
                     "sw   zero, 52(a0)\n"
                     "sw   zero, 56(a0)\n"
                     "ret\n");
}

__attribute__((noinline, naked, used, aligned(4))) static uintptr_t
pde_subdir_find_asm(uintptr_t de, const char *name, uint32_t len)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sw   s0, 24(sp)\n"
                     "sw   ra, 28(sp)\n"
                     "sw   s1, 20(sp)\n"
                     "addi s0, sp, 32\n"
                     "lw   s1, 76(a0)\n"
                     "beqz s1, 4f\n"
                     "sw   s2, 16(sp)\n"
                     "sw   s3, 12(sp)\n"
                     "mv   s2, a2\n"
                     "mv   s3, a1\n"
                     "1:\n"
                     "lbu  a5, 19(s1)\n"
                     "mv   a2, s2\n"
                     "mv   a0, s3\n"
                     "bltu s2, a5, 5f\n"
                     "bltu a5, s2, 2f\n"
                     "lw   a1, 12(s1)\n"
                     "call hazard_memcmp\n"
                     "bltz a0, 5f\n"
                     "beqz a0, 6f\n"
                     "2:\n"
                     "lw   s1, 4(s1)\n"
                     "bnez s1, 1b\n"
                     "3:\n"
                     "lw   s2, 16(sp)\n"
                     "lw   s3, 12(sp)\n"
                     "4:\n"
                     "lw   ra, 28(sp)\n"
                     "lw   s0, 24(sp)\n"
                     "mv   a0, s1\n"
                     "lw   s1, 20(sp)\n"
                     "addi sp, sp, 32\n"
                     "ret\n"
                     "5:\n"
                     "lw   s1, 8(s1)\n"
                     "bnez s1, 1b\n"
                     "j    3b\n"
                     "6:\n"
                     "lw   ra, 28(sp)\n"
                     "lw   s0, 24(sp)\n"
                     "addi s1, s1, -80\n"
                     "lw   s2, 16(sp)\n"
                     "lw   s3, 12(sp)\n"
                     "mv   a0, s1\n"
                     "lw   s1, 20(sp)\n"
                     "addi sp, sp, 32\n"
                     "ret\n");
}

__attribute__((noinline, naked, used, aligned(4))) static uintptr_t
proc_lookup_de_asm(uintptr_t dir, uintptr_t dentry, uintptr_t de)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sw   s0, 24(sp)\n"
                     "sw   s1, 20(sp)\n"
                     "sw   s2, 16(sp)\n"
                     "sw   ra, 28(sp)\n"
                     "addi s0, sp, 32\n"
                     "mv   s2, a0\n"
                     "mv   s1, a1\n"
                     "mv   a0, a2\n"
                     "lw   a2, 28(a1)\n"
                     "lw   a1, 32(a1)\n"
                     "call pde_subdir_find_asm\n"
                     "beqz a0, 1f\n"
                     "mv   a5, a0\n"
                     "li   a1, 1\n"
                     "addi a0, a0, 4\n"
                     "amoadd.w a4, a1, (a0)\n"
                     "la   t0, observed_ref_old\n"
                     "sw   a4, 0(t0)\n"
                     "lw   a0, 20(s2)\n"
                     "mv   a1, a5\n"
                     "sw   a5, -20(s0)\n"
                     "call fake_proc_get_inode\n"
                     "j    2f\n"
                     "1:\n"
                     "li   a0, -2\n"
                     "2:\n"
                     "lw   ra, 28(sp)\n"
                     "lw   s0, 24(sp)\n"
                     "lw   s1, 20(sp)\n"
                     "lw   s2, 16(sp)\n"
                     "addi sp, sp, 32\n"
                     "ret\n");
}

static int run_one(const char *name, uintptr_t (*fn)(uintptr_t, uintptr_t, uintptr_t))
{
    for (uint32_t i = 0; i < ITERATIONS; i++) {
        uintptr_t node = 0x80c60050u + ((uintptr_t) i << 6);
        uintptr_t expected = node - 80u;
        uintptr_t got = fn(node, 0x13572468u + i, 0x24681357u ^ i);
        sink ^= got;
        if (got != expected) {
            uart_printf("%s FAIL i=%u node=0x%08lx got=0x%08lx expected=0x%08lx\n",
                        name,
                        (unsigned) i,
                        (unsigned long) node,
                        (unsigned long) got,
                        (unsigned long) expected);
            return -1;
        }
    }
    uart_printf("%s PASS\n", name);
    return 0;
}

static void write32(uint8_t *base, uint32_t offset, uintptr_t value)
{
    *(volatile uintptr_t *) (void *) (base + offset) = value;
}

static uintptr_t read32(uint8_t *base, uint32_t offset)
{
    return *(volatile uintptr_t *) (void *) (base + offset);
}

static void clear_bytes(uint8_t *base, uint32_t size)
{
    for (uint32_t i = 0; i < size; i++) {
        base[i] = 0;
    }
}

static uint32_t small_strlen(const char *name)
{
    uint32_t len = 0;

    while (name[len] != '\0') {
        len++;
    }
    return len;
}

static uintptr_t multi_base(uint32_t idx)
{
    return (uintptr_t) multi_pdes[idx];
}

static uintptr_t multi_node(uint32_t idx)
{
    return multi_base(idx) + PDE_SUBDIR_NODE_OFFSET;
}

static const char *multi_inline_name(uint32_t idx)
{
    return (const char *) (const void *) (multi_pdes[idx] + PDE_INLINE_NAME_OFFSET);
}

static const char *known_pde_name(uintptr_t de)
{
    for (uint32_t i = 0; i < MULTI_PDE_COUNT; i++) {
        if (de == multi_base(i)) {
            return multi_inline_name(i);
        }
        if (de == multi_node(i)) {
            return "NODE_PTR";
        }
    }
    return "UNKNOWN";
}

static void init_multi_pde(uint32_t idx, const char *name)
{
    uint8_t *de = multi_pdes[idx];
    uint32_t len = small_strlen(name);

    clear_bytes(de, sizeof(multi_pdes[idx]));
    write32(de, PDE_REFCOUNT_OFFSET, 1u);
    write32(de, PDE_NAME_OFFSET, multi_base(idx) + PDE_INLINE_NAME_OFFSET);
    for (uint32_t i = 0; i <= len; i++) {
        de[PDE_INLINE_NAME_OFFSET + i] = (uint8_t) name[i];
    }
    *(volatile uint16_t *) (void *) (de + PDE_MODE_OFFSET) = PDE_MODE_REG_0444;
    de[PDE_NAMELEN_OFFSET] = (uint8_t) len;
    write32(de, PDE_NLINK_OFFSET, 1u);
}

static void set_rb_links(uint32_t idx, int32_t right_idx, int32_t left_idx)
{
    uint8_t *de = multi_pdes[idx];

    write32(de,
            PDE_SUBDIR_NODE_OFFSET + RB_RIGHT_OFFSET,
            right_idx >= 0 ? multi_node((uint32_t) right_idx) : 0u);
    write32(de,
            PDE_SUBDIR_NODE_OFFSET + RB_LEFT_OFFSET,
            left_idx >= 0 ? multi_node((uint32_t) left_idx) : 0u);
}

enum {
    MULTI_CMDLINE = 0,
    MULTI_LOADAVG = 1,
    MULTI_MAPS = 2,
    MULTI_MEMINFO = 3,
    MULTI_VERSION = 4,
};

struct multi_lookup_case {
    const char *name;
    uint32_t idx;
};

static const struct multi_lookup_case multi_lookup_cases[] = {
    {version_name, MULTI_VERSION},
    {cmdline_name, MULTI_CMDLINE},
    {loadavg_name, MULTI_LOADAVG},
    {maps_name, MULTI_MAPS},
    {meminfo_name, MULTI_MEMINFO},
};

static void setup_multi_proc_tree(void)
{
    clear_bytes(root_pde, sizeof(root_pde));
    clear_bytes(fake_dir, sizeof(fake_dir));
    clear_bytes(fake_dentry, sizeof(fake_dentry));

    init_multi_pde(MULTI_CMDLINE, cmdline_name);
    init_multi_pde(MULTI_LOADAVG, loadavg_name);
    init_multi_pde(MULTI_MAPS, maps_name);
    init_multi_pde(MULTI_MEMINFO, meminfo_name);
    init_multi_pde(MULTI_VERSION, version_name);

    /*
     * A small rb-tree keyed (namelen, then name) like /proc root.  set_rb_links
     * takes (node, RIGHT, LEFT).  The lookup walk (pde_subdir_find_asm) is
     * LENGTH-FIRST: a search name shorter than the node descends LEFT, longer
     * descends RIGHT.  "maps" (len 4) is shorter than every other node (len 7),
     * so it must live on the left spine to be reachable: loadavg.left=cmdline,
     * cmdline.left=maps.  (It used to be meminfo.left — i.e. inside loadavg's
     * RIGHT subtree — which a len-4 query can NEVER reach, because the len-7
     * root sends every len-4 query LEFT into the cmdline subtree, hits
     * cmdline.left=NULL, and returns 0.  That made the "maps" lookup assert fail
     * by tree construction, not by any RTL fault.)
     */
    write32(root_pde, PDE_SUBDIR_ROOT_OFFSET, multi_node(MULTI_LOADAVG));
    set_rb_links(MULTI_LOADAVG, MULTI_MEMINFO, MULTI_CMDLINE);
    set_rb_links(MULTI_MEMINFO, MULTI_VERSION, -1);
    set_rb_links(MULTI_CMDLINE, -1, MULTI_MAPS);
    set_rb_links(MULTI_MAPS, -1, -1);
    set_rb_links(MULTI_VERSION, -1, -1);

    write32(fake_dir, 20u, 0xcafef00du);
}

static int
run_multi_lookup_case(const char *test_name, uint32_t iter, const struct multi_lookup_case *lookup)
{
    uint32_t len = small_strlen(lookup->name);
    uintptr_t expected = multi_base(lookup->idx);
    uintptr_t expected_node = multi_node(lookup->idx);
    uint8_t *expected_pde = multi_pdes[lookup->idx];

    observed_de = 0;
    observed_sb = 0;
    observed_ref_old = 0xdeadbeefu;
    observed_mode = 0xdeadbeefu;
    observed_namelen = 0xdeadbeefu;
    write32(fake_dentry, 28u, len);
    write32(fake_dentry, 32u, (uintptr_t) lookup->name);

    uintptr_t direct = pde_subdir_find_asm((uintptr_t) root_pde, lookup->name, len);
    uintptr_t ret =
        proc_lookup_de_asm((uintptr_t) fake_dir, (uintptr_t) fake_dentry, (uintptr_t) root_pde);
    uint32_t ref_now = (uint32_t) read32(expected_pde, PDE_REFCOUNT_OFFSET);

    sink ^= direct ^ ret;
    if (direct != expected || observed_de != expected || observed_sb != 0xcafef00du ||
        observed_ref_old != 1u || ref_now != 2u || observed_mode != PDE_MODE_REG_0444 ||
        observed_namelen != len) {
        uart_printf("%s FAIL i=%u query=%s direct=0x%08lx expected=0x%08lx node=0x%08lx\n",
                    test_name,
                    (unsigned) iter,
                    lookup->name,
                    (unsigned long) direct,
                    (unsigned long) expected,
                    (unsigned long) expected_node);
        uart_printf("%s obs_de=0x%08lx obs_name=%s sb=0x%08lx mode=0x%04lx len=%lu old=0x%08lx "
                    "ref=0x%08lx ret=0x%08lx\n",
                    test_name,
                    (unsigned long) observed_de,
                    known_pde_name(observed_de),
                    (unsigned long) observed_sb,
                    (unsigned long) observed_mode,
                    (unsigned long) observed_namelen,
                    (unsigned long) observed_ref_old,
                    (unsigned long) ref_now,
                    (unsigned long) ret);
        return -1;
    }
    return 0;
}

static int run_multi_lookup_repro_variant(const char *name, int churn)
{
    const uint32_t case_count =
        (uint32_t) (sizeof(multi_lookup_cases) / sizeof(multi_lookup_cases[0]));

    for (uint32_t i = 0; i < PDE_VIS_ITERATIONS; i++) {
        if (churn) {
            churn_cache(i + 0x200u);
        }
        for (uint32_t c = 0; c < case_count; c++) {
            setup_multi_proc_tree();
            if (run_multi_lookup_case(name, i, &multi_lookup_cases[c]) != 0) {
                return -1;
            }
        }
    }

    uart_printf("%s PASS\n", name);
    return 0;
}

static int run_multi_lookup_repro(void)
{
    if (run_multi_lookup_repro_variant("multi_lookup_immediate", 0) != 0) {
        return -1;
    }
    if (run_multi_lookup_repro_variant("multi_lookup_churn", 1) != 0) {
        return -1;
    }
    return 0;
}

static void setup_fake_proc_tree(void)
{
    for (uint32_t i = 0; i < sizeof(root_pde); i++) {
        root_pde[i] = 0;
        entry_pde[i] = 0;
    }
    for (uint32_t i = 0; i < sizeof(fake_dir); i++) {
        fake_dir[i] = 0;
    }
    for (uint32_t i = 0; i < sizeof(fake_dentry); i++) {
        fake_dentry[i] = 0;
    }

    uintptr_t entry_base = (uintptr_t) entry_pde;
    uintptr_t entry_node = entry_base + PDE_SUBDIR_NODE_OFFSET;

    write32(root_pde, PDE_SUBDIR_ROOT_OFFSET, entry_node);
    write32(entry_pde, PDE_REFCOUNT_OFFSET, 1u);
    write32(entry_pde, PDE_SUBDIR_NODE_OFFSET + RB_RIGHT_OFFSET, 0u);
    write32(entry_pde, PDE_SUBDIR_NODE_OFFSET + RB_LEFT_OFFSET, 0u);
    write32(entry_pde, PDE_SUBDIR_NODE_OFFSET + RB_NAME_OFFSET, (uintptr_t) version_name);
    entry_pde[PDE_SUBDIR_NODE_OFFSET + RB_NAMELEN_OFFSET] = 7u;

    write32(fake_dir, 20u, 0xcafef00du);
    write32(fake_dentry, 28u, 7u);
    write32(fake_dentry, 32u, (uintptr_t) version_name);
}

static int run_lookup_repro(void)
{
    uintptr_t entry_base = (uintptr_t) entry_pde;
    uintptr_t entry_node = entry_base + PDE_SUBDIR_NODE_OFFSET;

    for (uint32_t i = 0; i < ITERATIONS; i++) {
        setup_fake_proc_tree();
        observed_de = 0;
        observed_sb = 0;

        uintptr_t direct = pde_subdir_find_asm((uintptr_t) root_pde, version_name, 7u);
        if (direct != entry_base) {
            uart_printf("pde_subdir_find_asm FAIL i=%u got=0x%08lx expected=0x%08lx node=0x%08lx\n",
                        (unsigned) i,
                        (unsigned long) direct,
                        (unsigned long) entry_base,
                        (unsigned long) entry_node);
            return -1;
        }

        uintptr_t ret =
            proc_lookup_de_asm((uintptr_t) fake_dir, (uintptr_t) fake_dentry, (uintptr_t) root_pde);
        sink ^= ret;
        if (observed_de != entry_base) {
            uart_printf("proc_lookup_de_asm FAIL i=%u observed_de=0x%08lx expected=0x%08lx "
                        "node=0x%08lx ret=0x%08lx\n",
                        (unsigned) i,
                        (unsigned long) observed_de,
                        (unsigned long) entry_base,
                        (unsigned long) entry_node,
                        (unsigned long) ret);
            return -1;
        }
        if (observed_sb != 0xcafef00du) {
            uart_printf("proc_lookup_de_asm SB FAIL i=%u observed_sb=0x%08lx\n",
                        (unsigned) i,
                        (unsigned long) observed_sb);
            return -1;
        }
        if (read32(entry_pde, PDE_REFCOUNT_OFFSET) != 2u) {
            uart_printf(
                "proc_lookup_de_asm REF FAIL i=%u ref=0x%08lx node_right=0x%08lx\n",
                (unsigned) i,
                (unsigned long) read32(entry_pde, PDE_REFCOUNT_OFFSET),
                (unsigned long) read32(entry_pde, PDE_SUBDIR_NODE_OFFSET + RB_RIGHT_OFFSET));
            return -1;
        }
    }

    uart_printf("proc_lookup_de_asm PASS\n");
    return 0;
}

static void setup_pde_visibility_tree(void)
{
    for (uint32_t i = 0; i < sizeof(root_pde); i++) {
        root_pde[i] = 0;
        entry_pde[i] = 0;
    }
    for (uint32_t i = 0; i < sizeof(fake_dir); i++) {
        fake_dir[i] = 0;
    }
    for (uint32_t i = 0; i < sizeof(fake_dentry); i++) {
        fake_dentry[i] = 0;
    }

    uintptr_t entry_base = (uintptr_t) entry_pde;
    uintptr_t entry_node = entry_base + PDE_SUBDIR_NODE_OFFSET;

    pde_init_version_asm(entry_base);
    write32(root_pde, PDE_SUBDIR_ROOT_OFFSET, entry_node);
    write32(fake_dir, 20u, 0xcafef00du);
    write32(fake_dentry, 28u, 7u);
    write32(fake_dentry, 32u, (uintptr_t) version_name);
}

static void churn_cache(uint32_t seed)
{
    for (uint32_t i = 0; i < PDE_VIS_CHURN_BYTES; i += 64u) {
        volatile uint32_t *word = (volatile uint32_t *) (void *) (s2l_area + i);
        uint32_t value = *word ^ (seed + i + 0x9e3779b9u);
        *word = value;
        seed ^= *word + (seed << 5) + (seed >> 2);
    }
    s2l_sink ^= seed;
}

static int
check_pde_visibility_result(const char *name, uint32_t i, uintptr_t direct, uintptr_t ret)
{
    uintptr_t entry_base = (uintptr_t) entry_pde;
    uintptr_t entry_node = entry_base + PDE_SUBDIR_NODE_OFFSET;
    uint32_t ref_now = (uint32_t) read32(entry_pde, PDE_REFCOUNT_OFFSET);

    if (direct != entry_base) {
        uart_printf("%s FIND FAIL i=%u got=0x%08lx expected=0x%08lx node=0x%08lx namelen=%u\n",
                    name,
                    (unsigned) i,
                    (unsigned long) direct,
                    (unsigned long) entry_base,
                    (unsigned long) entry_node,
                    (unsigned) entry_pde[PDE_NAMELEN_OFFSET]);
        return -1;
    }
    if (observed_de != entry_base) {
        uart_printf("%s DE FAIL i=%u observed_de=0x%08lx expected=0x%08lx ret=0x%08lx\n",
                    name,
                    (unsigned) i,
                    (unsigned long) observed_de,
                    (unsigned long) entry_base,
                    (unsigned long) ret);
        return -1;
    }
    if (observed_sb != 0xcafef00du) {
        uart_printf("%s SB FAIL i=%u observed_sb=0x%08lx\n",
                    name,
                    (unsigned) i,
                    (unsigned long) observed_sb);
        return -1;
    }
    if (observed_ref_old != 1u || ref_now != 2u) {
        uart_printf("%s REF FAIL i=%u old=0x%08lx now=0x%08lx mode_mem=0x%04x namelen=%u\n",
                    name,
                    (unsigned) i,
                    (unsigned long) observed_ref_old,
                    (unsigned long) ref_now,
                    (unsigned) (*(volatile uint16_t *) (void *) (entry_pde + PDE_MODE_OFFSET)),
                    (unsigned) entry_pde[PDE_NAMELEN_OFFSET]);
        return -1;
    }
    if (observed_mode != 0x8124u || observed_namelen != 7u) {
        uart_printf("%s MODE FAIL i=%u mode=0x%04lx namelen=%lu ref_old=0x%08lx ref_now=0x%08lx "
                    "word96=0x%08lx\n",
                    name,
                    (unsigned) i,
                    (unsigned long) observed_mode,
                    (unsigned long) observed_namelen,
                    (unsigned long) observed_ref_old,
                    (unsigned long) ref_now,
                    (unsigned long) read32(entry_pde, PDE_MODE_OFFSET));
        return -1;
    }
    return 0;
}

static int run_pde_visibility_repro_variant(const char *name, int churn)
{
    for (uint32_t i = 0; i < PDE_VIS_ITERATIONS; i++) {
        setup_pde_visibility_tree();
        observed_de = 0;
        observed_sb = 0;
        observed_ref_old = 0xdeadbeefu;
        observed_mode = 0xdeadbeefu;
        observed_namelen = 0xdeadbeefu;

        if (churn) {
            churn_cache(i);
        }

        uintptr_t direct = pde_subdir_find_asm((uintptr_t) root_pde, version_name, 7u);
        uintptr_t ret =
            proc_lookup_de_asm((uintptr_t) fake_dir, (uintptr_t) fake_dentry, (uintptr_t) root_pde);
        sink ^= direct ^ ret;
        if (check_pde_visibility_result(name, i, direct, ret) != 0) {
            return -1;
        }
    }

    uart_printf("%s PASS\n", name);
    return 0;
}

static int run_pde_visibility_repro(void)
{
    if (run_pde_visibility_repro_variant("pde_visibility_immediate", 0) != 0) {
        return -1;
    }
    if (run_pde_visibility_repro_variant("pde_visibility_churn", 1) != 0) {
        return -1;
    }
    return 0;
}

static int run_store_load_repro(void)
{
    for (uint32_t i = 0; i < ITERATIONS; i++) {
        uint8_t *ptr = s2l_area + (i * 256u);
        uint32_t value = 0x8000u | ((i * 37u + 0x16du) & 0x7fffu);
        uint32_t got = halfword_s2l(ptr, value);
        s2l_sink ^= got;
        if (got != (value & 0xffffu)) {
            uart_printf("halfword_s2l FAIL i=%u ptr=0x%08lx got=0x%08lx expected=0x%08lx\n",
                        (unsigned) i,
                        (unsigned long) (uintptr_t) ptr,
                        (unsigned long) got,
                        (unsigned long) (value & 0xffffu));
            return -1;
        }
    }
    uart_printf("halfword_s2l PASS\n");

    for (uint32_t i = 0; i < ITERATIONS; i++) {
        uint8_t *ptr = s2l_area + 0x4000u + (i * 256u);
        uint32_t value = 0x40000000u | (i * 0x10203u) | 0x5a5u;
        uint32_t got = word_s2l(ptr, value);
        s2l_sink ^= got;
        if (got != value) {
            uart_printf("word_s2l FAIL i=%u ptr=0x%08lx got=0x%08lx expected=0x%08lx\n",
                        (unsigned) i,
                        (unsigned long) (uintptr_t) ptr,
                        (unsigned long) got,
                        (unsigned long) value);
            return -1;
        }
    }
    uart_printf("word_s2l PASS\n");

    for (uint32_t i = 0; i < ITERATIONS; i++) {
        uint8_t *ptr = s2l_area + 0x8000u + (i * 256u);
        uint32_t value = 0x9000u | ((i * 53u + 0x55u) & 0x6fffu);
        uint32_t got = amo_halfword_s2l(ptr, value);
        s2l_sink ^= got;
        if (got != (value & 0xffffu)) {
            uart_printf("amo_halfword_s2l FAIL i=%u ptr=0x%08lx got=0x%08lx expected=0x%08lx\n",
                        (unsigned) i,
                        (unsigned long) (uintptr_t) ptr,
                        (unsigned long) got,
                        (unsigned long) (value & 0xffffu));
            return -1;
        }
    }
    uart_printf("amo_halfword_s2l PASS\n");
    return 0;
}

int main(void)
{
    uart_printf("\n=== pde_return_hazard ===\n");
    if (run_one("epilogue_repro", epilogue_repro) != 0) {
        uart_printf("<<FAIL>>\n");
        for (;;) {
        }
    }
    if (run_one("epilogue_direct_a0", epilogue_direct_a0) != 0) {
        uart_printf("<<FAIL>>\n");
        for (;;) {
        }
    }
    if (run_lookup_repro() != 0) {
        uart_printf("<<FAIL>>\n");
        for (;;) {
        }
    }
    if (run_multi_lookup_repro() != 0) {
        uart_printf("<<FAIL>>\n");
        for (;;) {
        }
    }
    if (run_pde_visibility_repro() != 0) {
        uart_printf("<<FAIL>>\n");
        for (;;) {
        }
    }
    if (run_store_load_repro() != 0) {
        uart_printf("<<FAIL>>\n");
        for (;;) {
        }
    }
    uart_printf("sink=0x%08lx\n", (unsigned long) sink);
    uart_printf("s2l_sink=0x%08lx\n", (unsigned long) s2l_sink);
    uart_printf("<<PASS>>\n");
    for (;;) {
    }
}
