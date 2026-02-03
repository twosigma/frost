# Baremetal RISC-V C Library

A minimal C library for baremetal RISC-V applications, providing essential low-level functionality without external dependencies.

## Components

### UART Communication (`uart.h`, `uart.c`)

**Transmit functions:**
- **uart_putchar()**: Transmit a single character (handles CR+LF conversion)
- **uart_puts()**: Transmit null-terminated strings
- **uart_printf()**: Minimal printf implementation supporting:
  - `%c` - character
  - `%s` - string
  - `%d`, `%ld`, `%lld` - signed decimal integers
  - `%u`, `%lu`, `%llu` - unsigned decimal integers
  - `%x`, `%X` - hexadecimal (32-bit)
  - `%%` - literal percent
  - Field width and zero-padding (e.g., `%08x`)

**Receive functions:**
- **uart_rx_available()**: Check if received data is available (returns 0 or 1)
- **uart_getchar()**: Blocking read of single character (waits until data available)
- **uart_getchar_nonblocking()**: Non-blocking read (returns -1 if no data)
- **uart_getline()**: Read a line with echo and backspace support

### String Operations (`string.h`, `string.c`)
- **memset()**: Fill memory with a constant byte
- **memcpy()**: Copy memory area
- **memmove()**: Copy memory area (handles overlapping regions)
- **memcmp()**: Compare two memory regions
- **strlen()**: Calculate string length
- **strncpy()**: Copy string with length limit
- **strcmp()**: Compare two strings lexicographically
- **strncmp()**: Compare up to n characters of two strings
- **strchr()**: Find first occurrence of character in string
- **strstr()**: Find first occurrence of substring in string

### Character Classification (`ctype.h`, `ctype.c`)
- **isdigit()**: Check if character is a decimal digit (0-9)
- **isalpha()**: Check if character is an alphabetic letter (a-z or A-Z)
- **isupper()**: Check if character is an uppercase letter (A-Z)
- **islower()**: Check if character is a lowercase letter (a-z)
- **isspace()**: Check if character is whitespace (space, tab, newline, etc.)
- **toupper()**: Convert character to uppercase
- **tolower()**: Convert character to lowercase

### Standard Library (`stdlib.h`, `stdlib.c`)
- **strtol()**: Convert string to long integer with base support (2-36, or 0 for auto-detect)
- **atoi()**: Convert string to integer (base 10)
- **atol()**: Convert string to long (base 10)

### Integer Limits (`limits.h`)
- **INT_MIN**, **INT_MAX**: Minimum and maximum values for int
- **LONG_MIN**, **LONG_MAX**: Minimum and maximum values for long

### Memory Allocation (`memory.h`, `memory.c`)
Arena allocator and malloc/free for dynamic memory management:
- **arena_alloc()**: Create arena from heap with specified capacity
- **arena_push()**: Allocate bytes with 8-byte alignment
- **arena_push_zero()**: Allocate and zero-initialize
- **arena_push_align()**: Allocate with custom alignment
- **arena_pop()**: Deallocate bytes from arena end
- **arena_clear()**: Reset arena position (bulk free)
- **arena_release()**: Release arena (currently noop)
- **malloc()**: First-fit freelist allocator with 8-byte alignment
- **free()**: Return memory to freelist

### Timer Functions (`timer.h`)
- **read_timer()**: Read 32-bit hardware timer counter
- **read_timer64()**: Read full 64-bit hardware timer counter (for long benchmarks)
- **delay_ticks()**: Delay for specified timer ticks
- **delay_1_second()**: Delay for one second (uses FPGA_CPU_CLK_FREQ)
- Default clock frequency: 300 MHz (override with FPGA_CPU_CLK_FREQ macro)
- Note: Use `read_timer64()` for benchmarks longer than ~13 seconds to avoid 32-bit overflow

### FIFO Interface (`fifo.h`)
- **fifo0_write()**, **fifo1_write()**: Write 32-bit words to FIFOs
- **fifo0_read()**, **fifo1_read()**: Read 32-bit words from FIFOs
- FIFO addresses provided by linker script

### FIX Protocol Support (`fix.h`, `fix.c`)
- **parse_timestamp()**: Parse FIX timestamp (YYYYMMDD-HH:MM:SS.mmm)
- **parse_price()**: Parse decimal price to fixed-point representation
- Fixed-point price structure with configurable scale (default: 8)
- Common FIX tag enumerations

### Trap Handling (`trap.h`)
Machine-mode trap handling utilities for RTOS support:
- **set_trap_handler()**: Configure trap vector address
- **enable_interrupts()** / **disable_interrupts()**: Control global interrupt enable (mstatus.MIE)
- **enable_timer_interrupt()**: Enable machine timer interrupt (mie.MTIE)
- **rdmtime()**: Read 64-bit machine timer
- **set_timer_cmp()**: Set timer compare value (mtimecmp)
- **trigger_software_interrupt()** / **clear_software_interrupt()**: Control MSIP
- **wfi()**: Wait for interrupt (low-power idle)
- **ecall()** / **ebreak()**: Environment call and breakpoint instructions

### CSR Access (`csr.h`)
Control and Status Register macros for M-mode CSRs:
- **csr_read()** / **csr_write()**: Direct CSR access
- **csr_set()** / **csr_clear()**: Atomic bit manipulation
- **rdcycle64()** / **rdinstret64()**: 64-bit counter reads
- M-mode CSR definitions: mstatus, mie, mip, mtvec, mepc, mcause, mtval, mscratch

## Memory-Mapped I/O

The library uses MMIO registers defined by the linker script:
- `UART_ADDR`: UART transmit register (write-only)
- `UART_RX_DATA_ADDR`: UART receive data (read pops byte from FIFO)
- `UART_RX_STATUS_ADDR`: UART RX status (bit 0 = data available)
- `TIMER_ADDR`: Hardware timer counter (Zicntr CSR alias)
- `FIFO0_ADDR`, `FIFO1_ADDR`: FIFO registers
- `MTIME_ADDR`: Machine timer (64-bit, CLINT-compatible)
- `MTIMECMP_ADDR`: Timer compare register (64-bit)
- `MSIP_ADDR`: Machine software interrupt pending

## Usage

Include the appropriate headers and link with the library:

```c
#include "uart.h"
#include "timer.h"

int main(void) {
    uart_printf("System starting...\n");
    delay_1_second();
    uart_printf("Ready!\n");
    return 0;
}
```

## Configuration

Key compile-time configurations:
- `FPGA_CPU_CLK_FREQ`: CPU clock frequency in Hz (default: 300000000)
- `TARGET_SCALE`: Fixed-point decimal scale for FIX prices (default: 8)

## Dependencies

- Requires a RISC-V toolchain with C standard library headers (`stdint.h`, `stddef.h`, `stdbool.h`, `stdarg.h`)
- Linker script must provide memory-mapped addresses for hardware registers

## Notes

- All functions are optimized for size and simplicity
- Dynamic memory via arena allocator and malloc/free (8KB heap)
- Thread-safe for single-core systems
- Suitable for bare-metal embedded RISC-V applications
