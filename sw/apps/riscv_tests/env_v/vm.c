// Frost riscv-tests virtual environment kernel: the upstream env/v/vm.c
// (demand-paged Sv39 user pages under a supervisor kernel mapped at the
// top of the address space) with its HTIF tohost console replaced by the
// Frost UART, and Frost's Svade A/D-bit handling exercised by the fault
// handler exactly as upstream wrote it (the kernel sets A on the first
// fault and D on the first store fault).
//
// See LICENSE in riscv-tests for the upstream license.

#include <stdint.h>
#include <string.h>

#include "riscv_test.h"

#define SATP_MODE_CHOICE SATP_MODE_SV39

void trap_entry();
void pop_tf(trapframe_t*);

#define pa2kva(pa) ((void*)(pa) - DRAM_BASE - MEGAPAGE_SIZE)
#define uva2kva(pa) ((void*)(pa) - MEGAPAGE_SIZE)

#define flush_page(addr) asm volatile ("sfence.vma %0" : : "r" (addr) : "memory")

// The UART: physical while the kernel still runs untranslated in M-mode
// (vm_boot), through the kernel's device megapage once translation is on
// (every trap handler runs in S-mode at the kernel VA).
#define UART_PA 0x40000000UL
#define UART_KVA (0xFFFFFFFFFFC00000UL)
static int translated;

static void cputchar(int x)
{
  volatile uint8_t* uart = (volatile uint8_t*)(translated ? UART_KVA : UART_PA);
  *uart = (uint8_t)x;
}

static void cputstring(const char* s)
{
  while (*s)
    cputchar(*s++);
}

void printhex(uint64_t x)
{
  char str[17];
  for (int i = 0; i < 16; i++)
  {
    str[15-i] = (x & 0xF) + ((x & 0xF) < 10 ? '0' : 'a'-10);
    x >>= 4;
  }
  str[16] = 0;

  cputstring(str);
}

static void terminate(int code)
{
  // The user-ecall pass/fail arg (a0). Frost's riscv_test.h RVTEST_PASS uses
  // a0 = 0; the upstream env/v uses a0 = 1; RVTEST_FAIL uses (TESTNUM << 1) | 1
  // (odd, >= 3). Treat either pass convention as success.
  if (code == 0 || code == 1) {
    cputstring("<<PASS>>\n");
  } else {
    cputstring("#");
    printhex((uint64_t)code >> 1);
    cputstring(" <<FAIL>>\n");
  }
  while (1);
}

void wtf()
{
  terminate(841 << 1);
}

#define stringify1(x) #x
#define stringify(x) stringify1(x)
#define assert(x) do { \
  if (x) break; \
  cputstring("Assertion failed: " stringify(x) "\n"); \
  terminate(3 << 1); \
} while(0)

#define l1pt pt[0]
#define user_l2pt pt[1]
#define NPT 4
#define kernel_l2pt pt[2]
#define user_llpt pt[3]
pte_t pt[NPT][PTES_PER_PT] __attribute__((aligned(PGSIZE)));

typedef struct { pte_t addr; void* next; } freelist_t;

freelist_t user_mapping[MAX_TEST_PAGES];
freelist_t freelist_nodes[MAX_TEST_PAGES];
freelist_t *freelist_head, *freelist_tail;

static void evict(unsigned long addr)
{
  assert(addr >= PGSIZE && addr < MAX_TEST_PAGES * PGSIZE);
  addr = addr/PGSIZE*PGSIZE;

  freelist_t* node = &user_mapping[addr/PGSIZE];
  if (node->addr)
  {
    // check accessed and dirty bits
    assert(user_llpt[addr/PGSIZE] & PTE_A);
    uintptr_t sstatus = set_csr(sstatus, SSTATUS_SUM);
    if (memcmp((void*)addr, uva2kva(addr), PGSIZE)) {
      assert(user_llpt[addr/PGSIZE] & PTE_D);
      memcpy(uva2kva(addr), (void*)addr, PGSIZE);
    }
    write_csr(sstatus, sstatus);

    user_mapping[addr/PGSIZE].addr = 0;

    if (freelist_tail == 0)
      freelist_head = freelist_tail = node;
    else
    {
      freelist_tail->next = node;
      freelist_tail = node;
    }
  }
}

extern int pf_filter(uintptr_t addr, uintptr_t *pte, int *copy);
extern int trap_filter(trapframe_t *tf);

void handle_fault(uintptr_t addr, uintptr_t cause)
{
  uintptr_t filter_encodings = 0;
  int copy_page = 1;

  assert(addr >= PGSIZE && addr < MAX_TEST_PAGES * PGSIZE);
  addr = addr/PGSIZE*PGSIZE;

  if (user_llpt[addr/PGSIZE]) {
    if (!(user_llpt[addr/PGSIZE] & PTE_A)) {
      user_llpt[addr/PGSIZE] |= PTE_A;
    } else {
      assert(!(user_llpt[addr/PGSIZE] & PTE_D) && cause == CAUSE_STORE_PAGE_FAULT);
      user_llpt[addr/PGSIZE] |= PTE_D;
    }
    flush_page(addr);
    return;
  }

  freelist_t* node = freelist_head;
  assert(node);
  freelist_head = node->next;
  if (freelist_head == freelist_tail)
    freelist_tail = 0;

  uintptr_t new_pte = (node->addr >> PGSHIFT << PTE_PPN_SHIFT) | PTE_V | PTE_U | PTE_R | PTE_W | PTE_X;

  if (pf_filter(addr, &filter_encodings, &copy_page)) {
      new_pte = (node->addr >> PGSHIFT << PTE_PPN_SHIFT) | filter_encodings;
  }

  user_llpt[addr/PGSIZE] = new_pte | PTE_A | PTE_D;
  flush_page(addr);

  assert(user_mapping[addr/PGSIZE].addr == 0);
  user_mapping[addr/PGSIZE] = *node;

  uintptr_t sstatus = set_csr(sstatus, SSTATUS_SUM);
  memcpy((void*)addr, uva2kva(addr), PGSIZE);
  write_csr(sstatus, sstatus);

  user_llpt[addr/PGSIZE] = new_pte;
  flush_page(addr);

  asm volatile ("fence.i");
}

void handle_trap(trapframe_t* tf)
{
  if (trap_filter(tf)) {
    pop_tf(tf);
  }

  if (tf->cause == CAUSE_USER_ECALL)
  {
    int n = tf->gpr[10];

    for (long i = 1; i < MAX_TEST_PAGES; i++)
      evict(i*PGSIZE);

    terminate(n);
  }
  else if (tf->cause == CAUSE_ILLEGAL_INSTRUCTION)
  {
    assert(tf->epc % 4 == 0);

    int* fssr;
    asm ("jal %0, 1f; fssr x0; 1:" : "=r"(fssr));

    if (*(int*)tf->epc == *fssr)
      terminate(1); // FP test on non-FP hardware.  "succeed."
    else
      assert(!"illegal instruction");
    tf->epc += 4;
  }
  else if (tf->cause == CAUSE_FETCH_PAGE_FAULT || tf->cause == CAUSE_LOAD_PAGE_FAULT || tf->cause == CAUSE_STORE_PAGE_FAULT)
    handle_fault(tf->badvaddr, tf->cause);
  else
    assert(!"unexpected exception");

  pop_tf(tf);
}

void vm_boot(uintptr_t test_addr)
{
  uint64_t random = ENTROPY;
  if (read_csr(mhartid) > 0)
    while (1);

  _Static_assert(SIZEOF_TRAPFRAME_T == sizeof(trapframe_t), "???");

#if (MAX_TEST_PAGES > PTES_PER_PT) || (DRAM_BASE % MEGAPAGE_SIZE) != 0
# error
#endif
  // map user to lowermost megapage
  l1pt[0] = ((pte_t)user_l2pt >> PGSHIFT << PTE_PPN_SHIFT) | PTE_V;
  // map kernel to uppermost megapage, and the device quadrant (UART) to
  // the megapage below it
  l1pt[PTES_PER_PT-1] = ((pte_t)kernel_l2pt >> PGSHIFT << PTE_PPN_SHIFT) | PTE_V;
  kernel_l2pt[PTES_PER_PT-1] = (DRAM_BASE/RISCV_PGSIZE << PTE_PPN_SHIFT) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
  kernel_l2pt[PTES_PER_PT-2] = (UART_PA/RISCV_PGSIZE << PTE_PPN_SHIFT) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
  user_l2pt[0] = ((pte_t)user_llpt >> PGSHIFT << PTE_PPN_SHIFT) | PTE_V;

  uintptr_t vm_choice = SATP_MODE_CHOICE;
  uintptr_t satp_value = ((uintptr_t)l1pt >> PGSHIFT)
                        | (vm_choice * (SATP_MODE & ~(SATP_MODE<<1)));
  write_csr(satp, satp_value);
  if (read_csr(satp) != satp_value)
    assert(!"unsupported satp mode");
  flush_page(DRAM_BASE);

  // Set up PMPs if present, ignoring illegal instruction trap if not.
  uintptr_t pmpc = PMP_NAPOT | PMP_R | PMP_W | PMP_X;
  uintptr_t pmpa = ((uintptr_t)1 << 53) - 1;
  asm volatile ("la t0, 1f\n\t"
                "csrrw t0, mtvec, t0\n\t"
                "csrw pmpaddr0, %1\n\t"
                "csrw pmpcfg0, %0\n\t"
                ".align 2\n\t"
                "1: csrw mtvec, t0"
                : : "r" (pmpc), "r" (pmpa) : "t0");

  // set up supervisor trap handling
  write_csr(stvec, pa2kva(trap_entry));
  write_csr(sscratch, pa2kva(read_csr(mscratch)));
  write_csr(medeleg,
    (1 << CAUSE_USER_ECALL) |
    (1 << CAUSE_FETCH_PAGE_FAULT) |
    (1 << CAUSE_LOAD_PAGE_FAULT) |
    (1 << CAUSE_STORE_PAGE_FAULT));
  // FPU on; accelerator on; vector unit on
  write_csr(mstatus, MSTATUS_FS | MSTATUS_XS | MSTATUS_VS);
  write_csr(mie, 0);

  random = 1 + (random % MAX_TEST_PAGES);
  freelist_head = pa2kva((void*)&freelist_nodes[0]);
  freelist_tail = pa2kva(&freelist_nodes[MAX_TEST_PAGES-1]);
  for (long i = 0; i < MAX_TEST_PAGES; i++)
  {
    freelist_nodes[i].addr = DRAM_BASE + (MAX_TEST_PAGES + random)*PGSIZE;
    freelist_nodes[i].next = pa2kva(&freelist_nodes[i+1]);
    random = LFSR_NEXT(random);
  }
  freelist_nodes[MAX_TEST_PAGES-1].next = 0;

  // From here on every kernel entry is a translated S-mode trap.
  translated = 1;
  asm volatile ("fence" ::: "memory");

  trapframe_t tf;
  memset(&tf, 0, sizeof(tf));
  tf.epc = test_addr - DRAM_BASE;
  pop_tf(&tf);
}
