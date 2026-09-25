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
 * FreeRTOS port for FROST, C half: critical sections, yield via ecall, the
 * mtime tick, and the initial task-stack layout. The trap handler and the
 * context switch itself are in port_frost_asm.S.
 */

#include "FreeRTOS.h"
#include "mmio.h"
#include "task.h"
#include <stdint.h>

/* Critical-section nesting depth. Not static: port_frost_asm.S saves and restores it as
 * part of each task's context. */
UBaseType_t uxCriticalNesting = 0;
static volatile uint32_t ulPortYieldPending = 0;

/* Next mtimecmp value */
static uint64_t ullNextTime = 0;
/* mtime advances once per core cycle, so a tick is configCPU_CLOCK_HZ / configTICK_RATE_HZ
 * cycles. */
static const uint64_t ullTimerIncrementForOneTick =
    (uint64_t) (configCPU_CLOCK_HZ / configTICK_RATE_HZ);

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
    /* ecall from M-mode traps with mcause = 11; the trap handler treats that as a yield
     * and switches context. */
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

/* Arm mtimecmp for the first tick and enable the timer interrupt. mstatus.MIE stays clear, as
 * vTaskStartScheduler left it: the first task's mret sets it from the frame's MPIE, so no tick
 * can be taken before a task context is loaded. */
static void prvSetupTimerInterrupt(void)
{
    uint32_t low = MTIME_LO;
    uint32_t high = MTIME_HI;
    uint64_t ullCurrentTime = ((uint64_t) high << 32) | low;

    ullNextTime = ullCurrentTime + ullTimerIncrementForOneTick;

    /* Park the high word at all-ones first so no intermediate 64-bit compare value lies
     * below mtime and fires early. */
    MTIMECMP_HI = 0xFFFFFFFF;
    MTIMECMP_LO = (uint32_t) (ullNextTime & 0xFFFFFFFF);
    MTIMECMP_HI = (uint32_t) (ullNextTime >> 32);

    /* Enable timer interrupt in mie (bit 7 = MTIE). */
    uint32_t mie_val = 0x80;
    __asm volatile("csrs mie, %0" ::"r"(mie_val));
}

/*-----------------------------------------------------------*/

/* Tick interrupt, called from the trap handler with the interrupted code's critical-section
 * depth. A task switch while that depth is nonzero would preempt the critical section, so the
 * switch is left pending for vPortExitCritical. */
void vPortTimerTickHandler(UBaseType_t uxInterruptedNesting)
{
    ullNextTime += ullTimerIncrementForOneTick;

    /* High word first, as in prvSetupTimerInterrupt */
    MTIMECMP_HI = 0xFFFFFFFF;
    MTIMECMP_LO = (uint32_t) (ullNextTime & 0xFFFFFFFF);
    MTIMECMP_HI = (uint32_t) (ullNextTime >> 32);

    if (xTaskIncrementTick() != pdFALSE) {
        if (uxInterruptedNesting == 0U) {
            vTaskSwitchContext();
        } else {
            ulPortYieldPending = 1U;
        }
    }
}

/*-----------------------------------------------------------*/

/* Idle hook: not called, configUSE_IDLE_HOOK is 0 */
void vApplicationIdleHook(void)
{
    /* nothing to do */
}

/*-----------------------------------------------------------*/

/* Tick hook: not called, configUSE_TICK_HOOK is 0 */
void vApplicationTickHook(void)
{
    /* nothing to do */
}

/*-----------------------------------------------------------*/

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

/* Build a new task's initial stack frame in the layout the trap handler restores */
StackType_t *
pxPortInitialiseStack(StackType_t *pxTopOfStack, TaskFunction_t pxCode, void *pvParameters)
{

    /* Lay out a context as port_frost_asm.S saves it: 32 XLEN-wide slots, the 256 bytes
     * (portCONTEXT_SIZE) that it restores (high to low address):
     *   slot 31: padding
     *   slot 30: uxCriticalNesting
     *   slot 29: mstatus
     *   slot 28: mepc
     *   slots 27..1: x31 (t6) down to x5 (t0)
     *   slot 0: x1 (ra)
     * The kernel passes a 16-byte aligned pxTopOfStack, so the task starts with sp at
     * pxTopOfStack, 16-byte aligned as the psABI requires. */

    /* Padding, never read */
    pxTopOfStack--;
    *pxTopOfStack = 0; /* slot 31 */

    /* uxCriticalNesting = 0: the task starts outside any critical section */
    pxTopOfStack--;
    *pxTopOfStack = 0; /* slot 30 */

    /* mstatus: MPP=11 (M-mode), MPIE=1, MIE=0. mret copies MPIE into MIE, so the task
     * starts with interrupts enabled. FS=0 (Off): the context switch saves no FP state, and
     * an FP instruction in a task traps as illegal. */
    pxTopOfStack--;
    *pxTopOfStack = 0x00001880; /* slot 29 */

    /* mepc: the task function */
    pxTopOfStack--;
    *pxTopOfStack = (StackType_t) pxCode; /* slot 28 */

    /* x31 down to x6 (slots 27..2): don't care */
    pxTopOfStack -= 26;

    /* x5 (t0): don't care */
    pxTopOfStack--;
    *pxTopOfStack = 0;

    /* x1 (ra): don't care for initial entry */
    pxTopOfStack--;
    *pxTopOfStack = 0;

    /* pvParameters goes in a0 (x10), slot 6 */
    pxTopOfStack[6] = (StackType_t) pvParameters; /* a0 */

    return pxTopOfStack;
}
