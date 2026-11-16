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


/* Vector stores ordered against fetch, page walks and the DMA doorbell.
 * DMA copies overlap vector reads and writes on shared and separate lines.
 * Racing reads must see a complete old or new image of each sector.
 */
#include "csr.h"
#include "dma_engine.h"
#include "uart.h"
#include <stdint.h>

#define SRC 0x83400000ul
#define DST 0x83410000ul
#define COPY 0x83420000ul
#define ROOT 0x83430000ul
#define L1 0x83431000ul
#define L0 0x83432000ul
#define OLD 0x83440000ul
#define NEW 0x83441000ul
#define VA 0x00400000ul
#define PTE(pa) (((pa) >> 12) << 10)
static unsigned long bytes;
static unsigned failures;
static volatile uint64_t *const src = (volatile uint64_t *) SRC;
static volatile uint64_t *const dst = (volatile uint64_t *) DST;
static volatile uint64_t *const copy = (volatile uint64_t *) COPY;

static void check(int ok, const char *name)
{
    if (!ok)
        failures++;
    uart_printf("%s %s\n", name, ok ? "OK" : "FAIL");
}
static void load_group(void)
{
    __asm__ volatile(".insn r 0x07, 0, 0x71, x8, %0, x8" : : "r"(src) : "memory");
}
static uint64_t pattern(unsigned long i)
{
    return 0x6b5a493827160000ull + i;
}
static unsigned long dma_done(void)
{
    unsigned long status = 0;
    for (unsigned long n = 0; n < 100000; n++) {
        status = dma_engine_status();
        if (!(status & DMA_ENGINE_STATUS_BUSY))
            break;
    }
    check((status & (DMA_ENGINE_STATUS_BUSY | DMA_ENGINE_STATUS_DONE | DMA_ENGINE_STATUS_ERROR)) ==
              DMA_ENGINE_STATUS_DONE,
          "DMA completion");
    dma_engine_ack();
    return status;
}
static void fetch_order(void)
{
    for (unsigned long i = 0; i < bytes / 8; i++) {
        src[i] = 0x0000001300000013ull;
        dst[i] = 0x0000001300000013ull;
    }
    /* addi a0,zero,42 (or 13); jalr zero,ra,0 */
    src[bytes / 8 - 1] = 0x0000806702a00513ull;
    dst[bytes / 8 - 1] = 0x0000806700d00513ull;
    __asm__ volatile("fence.i" ::: "memory");
    unsigned long (*fn)(void) = (unsigned long (*)(void))(DST + bytes - 8);
    check(fn() == 13, "old instruction image");
    load_group();
    unsigned long result;
    __asm__ volatile(".insn r 0x27, 0, 0x71, x8, %1, x8\n"
                     "fence.i\n"
                     "jalr ra, %2, 0\n"
                     "mv %0, a0"
                     : "=r"(result)
                     : "r"(dst), "r"(fn)
                     : "a0", "ra", "memory");
    check(result == 42, "vector store -> fence.i -> fetch");
}
static void walk_order(void)
{
    volatile uint64_t *root = (volatile uint64_t *) ROOT;
    volatile uint64_t *l1 = (volatile uint64_t *) L1;
    volatile uint64_t *l0 = (volatile uint64_t *) L0;
    for (unsigned i = 0; i < 512; i++)
        root[i] = l1[i] = l0[i] = 0;
    root[0] = PTE(L1) | 1;
    root[2] = PTE(0x80000000ul) | 0xcf; /* identity-mapped cached DDR */
    l1[2] = PTE(L0) | 1;
    for (unsigned long i = 0; i < bytes / 8; i++) {
        l0[i] = PTE(OLD) | 0xc7;
        src[i] = PTE(NEW) | 0xc7;
    }
    *(volatile uint64_t *) OLD = 13;
    *(volatile uint64_t *) NEW = 42;
    load_group();
    unsigned long saved = csr_read(mstatus);
    unsigned long status = (saved & ~0x1800ul) | 0x20800ul; /* MPRV, MPP=S */
    unsigned long va = VA + (bytes / 8 - 1) * 4096;
    unsigned long result;
    csr_write(satp, (8ul << 60) | (ROOT >> 12));
    __asm__ volatile("sfence.vma\n"
                     "csrw mstatus, %3\n"
                     ".insn r 0x27, 0, 0x71, x8, %1, x8\n"
                     "sfence.vma\n"
                     "ld %0, 0(%2)\n"
                     "csrw mstatus, %4"
                     : "=&r"(result)
                     : "r"(l0), "r"(va), "r"(status), "r"(saved)
                     : "memory");
    csr_write(satp, 0);
    __asm__ volatile("sfence.vma" ::: "memory");
    check(result == 42, "vector PTE store -> sfence.vma -> walk");
}
static void doorbell_order(void)
{
    for (unsigned long i = 0; i < bytes / 8; i++) {
        src[i] = pattern(i);
        dst[i] = copy[i] = 0;
    }
    load_group();
    /* Read the last sector first: a premature doorbell observes stale data
     * even when the VMU has already installed earlier sectors. */
    dma_engine_setup(DST + bytes - 32, COPY, 32, DMA_ENGINE_MODE_COPY, 0, 0, 0);
    __asm__ volatile(".insn r 0x27, 0, 0x71, x8, %0, x8\n"
                     "fence w, o\n"
                     "sw %2, 0(%1)"
                     :
                     : "r"(dst), "r"(dma_engine_reg(DMA_ENGINE_CTRL)), "r"(DMA_ENGINE_CTRL_START)
                     : "memory");
    dma_done();
    int ok = 1;
    for (unsigned long i = 0; i < 4; i++)
        ok &= copy[i] == pattern(bytes / 8 - 4 + i);
    check(ok, "vector store -> fence w,o -> DMA START");
}
static void concurrent_dma(unsigned mode)
{
    const unsigned long count = 4096 / 8;
    const uint64_t old_xor = 0x1122334455667788ull;
    for (unsigned long i = 0; i < count; i++) {
        src[i] = pattern(i);
        dst[i] = mode == 2 ? pattern(i) ^ old_xor : 0;
        copy[i] = 0;
    }
    __asm__ volatile("fence rw, ow" ::: "memory");
    dma_engine_setup(SRC, DST, 4096, DMA_ENGINE_MODE_COPY, 0, 0, 0);
    dma_engine_start();
    for (unsigned long offset = 0; offset < 4096; offset += bytes) {
        void *from = (void *) ((mode == 2 ? DST : SRC) + offset);
        void *to = (void *) ((mode == 1 ? DST : COPY) + offset);
        __asm__ volatile(".insn r 0x07, 0, 0x71, x8, %0, x8\n"
                         ".insn r 0x27, 0, 0x71, x8, %1, x8"
                         :
                         : "r"(from), "r"(to)
                         : "memory");
    }
    __asm__ volatile("fence rw, rw" ::: "memory");
    dma_done();
    int ok = 1;
    for (unsigned long i = 0; i < count; i++) {
        ok &= dst[i] == pattern(i);
        if (mode == 0)
            ok &= copy[i] == pattern(i);
    }
    if (mode == 2) {
        /* Each home read observes one complete old or new sector. Different
         * sectors may legally observe different sides of the DMA write. */
        for (unsigned long i = 0; i < count; i += 4) {
            uint64_t seen_xor = copy[i] ^ pattern(i);
            ok &= seen_xor == 0 || seen_xor == old_xor;
            for (unsigned long j = 1; j < 4; j++)
                ok &= copy[i + j] == (pattern(i + j) ^ seen_xor);
        }
    }
    check(ok,
          mode == 2   ? "DMA write/vector load sector images"
          : mode == 1 ? "DMA/vector shared lines"
                      : "DMA/vector separate lines");
}
static void dma_read_race(void)
{
    for (unsigned long i = 0; i < bytes / 8; i++) {
        src[i] = pattern(i);
        dst[i] = copy[i] = 0;
    }
    load_group();
    dma_engine_setup(DST, COPY, bytes, DMA_ENGINE_MODE_COPY, 0, 0, 0);
    /* With no fence between the vector store and START, each DMA sector
     * may observe the old zero image or the complete vector-store image. */
    __asm__ volatile(".insn r 0x27, 0, 0x71, x8, %0, x8\n"
                     "sw %2, 0(%1)"
                     :
                     : "r"(dst), "r"(dma_engine_reg(DMA_ENGINE_CTRL)), "r"(DMA_ENGINE_CTRL_START)
                     : "memory");
    dma_done();
    __asm__ volatile("fence rw, rw" ::: "memory");
    int ok = 1;
    for (unsigned long i = 0; i < bytes / 8; i += 4) {
        int old = copy[i] == 0;
        for (unsigned long j = 0; j < 4; j++) {
            ok &= copy[i + j] == (old ? 0 : pattern(i + j));
            ok &= dst[i + j] == pattern(i + j);
        }
    }
    check(ok, "vector store/DMA read sector images");
}
int main(void)
{
    csr_set(mstatus, 3ul << 9);
    unsigned long vlenb;
    __asm__ volatile("csrr %0, 0xc22" : "=r"(vlenb));
    bytes = 8 * vlenb;
    uart_printf("vec_order_test VLEN=%lu\n", 8 * vlenb);
    fetch_order();
    walk_order();
    doorbell_order();
    concurrent_dma(1);
    concurrent_dma(0);
    concurrent_dma(2);
    dma_read_race();
    uart_printf(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
