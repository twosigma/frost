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
 * FROST-specific FreeRTOS port C code
 *
 * Implements port functions required by FreeRTOS kernel.
 */

#include "FreeRTOS.h"
#include "mmio.h"
#include "task.h"
#include <stdint.h>

/* Critical section nesting counter - NOT static so trap handler can access */
UBaseType_t uxCriticalNesting = 0;
static volatile uint32_t ulPortYieldPending = 0;

/* Timer tick interval */
static uint64_t ullNextTime = 0;
/* Multiply by 100 to account for SIM_TIMER_SPEEDUP and give task time to run */
static const uint64_t ullTimerIncrementForOneTick =
    (uint64_t) (configCPU_CLOCK_HZ / configTICK_RATE_HZ) * 100;

/*-----------------------------------------------------------*/

void vPortEnterCritical(void)
{
    portDISABLE_INTERRUPTS();
    uxCriticalNesting++;
}

/*-----------------------------------------------------------*/

void vPortExitCritical(void)
{
    uxCriticalNesting--;
    if (uxCriticalNesting == 0) {
        portENABLE_INTERRUPTS();
        if (ulPortYieldPending != 0U) {
            ulPortYieldPending = 0U;
            vPortYield();
        }
    }
}

/*-----------------------------------------------------------*/

void vPortYield(void)
{
    /* Trigger a synchronous trap via ECALL to force context switch.
     * The trap handler will handle mcause=11 (environment call from M-mode)
     * and perform the context switch. */
    __asm volatile("ecall");
}

/*-----------------------------------------------------------*/

void vPortYieldWithinAPI(void)
{
    if (uxCriticalNesting != 0U) {
        ulPortYieldPending = 1U;
    } else {
        vPortYield();
    }
}

/*-----------------------------------------------------------*/

/* Set up timer for next tick */
static void prvSetupTimerInterrupt(void)
{
    /* Read current mtime */
    uint32_t low = MTIME_LO;
    uint32_t high = MTIME_HI;
    uint64_t ullCurrentTime = ((uint64_t) high << 32) | low;

    /* Set next compare time */
    ullNextTime = ullCurrentTime + ullTimerIncrementForOneTick;

    /* Write to mtimecmp (high word first to avoid spurious interrupt) */
    MTIMECMP_HI = 0xFFFFFFFF; /* Prevent spurious interrupt */
    MTIMECMP_LO = (uint32_t) (ullNextTime & 0xFFFFFFFF);
    MTIMECMP_HI = (uint32_t) (ullNextTime >> 32);

    /* Enable timer interrupt in mie (bit 7 = MTIE). */
    uint32_t mie_val = 0x80;
    __asm volatile("csrs mie, %0" ::"r"(mie_val));

    /* Enable global interrupts in mstatus (bit 3 = MIE) */
    __asm volatile("csrsi mstatus, 0x08");
}

/*-----------------------------------------------------------*/

/* Debug helper - print hex value */
static void print_hex(uint32_t val)
{
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 7; i >= 0; i--) {
        UART_TX = hex[(val >> (i * 4)) & 0xF];
    }
}

/* Debug: called from trap handler to print context info */
void vPortDebugTrap(uint32_t mepc, uint32_t mcause, uint32_t sp)
{
    (void) sp;
    UART_TX = '[';
    if (mcause == 11) {
        UART_TX = 'Y'; /* Yield */
    } else if (mcause == 0x80000007) {
        UART_TX = 'T'; /* Timer */
    } else {
        UART_TX = '?';
    }
    UART_TX = ':';
    print_hex(mepc);
    UART_TX = ']';
}

/* Debug: print mepc being restored */
void vPortDebugRestore(uint32_t mepc)
{
    UART_TX = '<';
    print_hex(mepc);
    UART_TX = '>';
}

/* Debug: print TCB pointer */
extern void *volatile pxCurrentTCB;
void vPortDebugTCB(char marker)
{
    UART_TX = marker;
    print_hex((uint32_t) pxCurrentTCB);
}

/* Debug: print RA value */
void vPortDebugRA(uint32_t ra)
{
    UART_TX = 'R';
    print_hex(ra);
}

/* Timer interrupt handler - called from trap handler */
void vPortTimerTickHandler(void)
{
    /* Update next timer compare value */
    ullNextTime += ullTimerIncrementForOneTick;

    /* Write to mtimecmp (high word first) */
    MTIMECMP_HI = 0xFFFFFFFF;
    MTIMECMP_LO = (uint32_t) (ullNextTime & 0xFFFFFFFF);
    MTIMECMP_HI = (uint32_t) (ullNextTime >> 32);

    /* Increment FreeRTOS tick */
    if (xTaskIncrementTick() != pdFALSE) {
        /* Need to context switch */
        vTaskSwitchContext();
    }
}

/*-----------------------------------------------------------*/

/* Idle task hook - required by FreeRTOS */
void vApplicationIdleHook(void)
{
    /* Do nothing - just let CPU idle */
}

/*-----------------------------------------------------------*/

/* Tick hook - required by FreeRTOS */
void vApplicationTickHook(void)
{
    /* Do nothing for minimal demo */
}

/*-----------------------------------------------------------*/

/* External symbol: pointer to current TCB */
extern void *volatile pxCurrentTCB;

/* Defined in port_frost_asm.S */
extern void xPortStartFirstTask(void);

BaseType_t xPortStartScheduler(void)
{
    /* Set up timer interrupt for first tick */
    prvSetupTimerInterrupt();

    /* Load first task context and start it (never returns) */
    xPortStartFirstTask();

    /* Should never get here */
    return pdFALSE;
}

/*-----------------------------------------------------------*/

void vPortEndScheduler(void)
{
    /* Not implemented for embedded targets */
}

/*-----------------------------------------------------------*/

/* Stack initialization - called by FreeRTOS to prepare task stack */
StackType_t *
pxPortInitialiseStack(StackType_t *pxTopOfStack, TaskFunction_t pxCode, void *pvParameters)
{

    /* Simulate a context as saved by the trap handler
     * Stack layout (from high to low address):
     * - mstatus
     * - mepc
     * - x31 (t6)
     * - x30 (t5)
     * ...
     * - x1 (ra)
     */

    /* Initial uxCriticalNesting = 0 (not in critical section) */
    pxTopOfStack--;
    *pxTopOfStack = 0; /* uxCriticalNesting at offset 30*4 */

    /* Initial mstatus: MPIE=1, MPP=11 (M-mode), MIE=0
     * When MRET executes, it will set MIE from MPIE (enabling interrupts) */
    pxTopOfStack--;
    *pxTopOfStack = 0x00001880; /* mstatus at offset 29*4 */

    /* Initial PC: task function */
    pxTopOfStack--;
    *pxTopOfStack = (StackType_t) pxCode; /* mepc at offset 28*4 */

    /* x31-x6 (t6-t1): don't care */
    pxTopOfStack -= 26;

    /* x5 (t0): don't care */
    pxTopOfStack--;
    *pxTopOfStack = 0;

    /* x1 (ra): don't care for initial entry */
    pxTopOfStack--;
    *pxTopOfStack = 0;

    /* Now set up argument in the right position
     * According to RISC-V calling convention, a0 is at position 6 from ra */
    pxTopOfStack[6] = (StackType_t) pvParameters; /* a0 */

    return pxTopOfStack;
}
