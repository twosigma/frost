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
 * FreeRTOS demo for FROST. A producer and a higher-priority consumer pass
 * NUM_ITEMS values through a depth-3 queue, sharing the UART under a mutex,
 * while two worker tasks hammer one counter with amoadd.w and yield every 64
 * iterations; the 1 ms tick also time-slices the equal-priority tasks. The
 * consumer then checks that a tick taken inside a critical section defers its
 * task switch to the end of that section, checks both tallies, and prints
 * <<PASS>> or <<FAIL>>.
 */

#include "FreeRTOS.h"
#include "csr.h"
#include "queue.h"
#include "semphr.h"
#include "task.h"
#include "uart.h"

#define TASK_STACK_SIZE (512)
#define ATOMIC_TASK_STACK_SIZE (256)
#define QUEUE_LENGTH (3)
#define NUM_ITEMS (5)
#define ATOMIC_WORKER_TASKS (2U)
#define ATOMIC_ITERATIONS_PER_WORKER (4000U)

extern void freertos_risc_v_trap_handler(void);

/* Shared resources */
static QueueHandle_t xDataQueue = NULL;
static SemaphoreHandle_t xUartMutex = NULL;
static TaskHandle_t xConsumerTaskHandle = NULL;

/* Counters for demonstration */
static volatile uint32_t ulProducerCount = 0;
static volatile uint32_t ulConsumerCount = 0;
static volatile uint32_t ulAtomicCounter = 0;
static const uint32_t ulAtomicWorkerIds[ATOMIC_WORKER_TASKS] = {1U, 2U};
static volatile uint32_t ulHelperRuns = 0;

/*-----------------------------------------------------------*/
/* UART output under the mutex */

static void safe_print(const char *msg)
{
    if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
        uart_puts(msg);
        xSemaphoreGive(xUartMutex);
    }
}

/*-----------------------------------------------------------*/
/* Producer Task - generates data and sends to queue */

static void vProducerTask(void *pvParameters)
{
    (void) pvParameters;
    uint32_t ulValue;

    safe_print("[Producer] Task started\r\n");

    for (ulValue = 1; ulValue <= NUM_ITEMS; ulValue++) {
        if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
            uart_puts("[Producer] Sending item ");
            uart_putchar('0' + ulValue);
            uart_puts(" to queue...\r\n");
            xSemaphoreGive(xUartMutex);
        }

        /* Count before sending: the higher-priority consumer may preempt as soon as the
         * item lands. The send blocks while the queue is full. */
        ulProducerCount++;
        if (xQueueSend(xDataQueue, &ulValue, portMAX_DELAY) == pdPASS) {
            if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
                uart_puts("[Producer] Item ");
                uart_putchar('0' + ulValue);
                uart_puts(" sent (queue may wake consumer)\r\n");
                xSemaphoreGive(xUartMutex);
            }
        }

        /* Give the same-priority atomic workers a turn between items */
        taskYIELD();
    }

    safe_print("[Producer] All items sent, task exiting\r\n");
    vTaskDelete(NULL);
}

/*-----------------------------------------------------------*/
/* Atomic increment helper (A extension) */

static inline void atomic_inc_amo(volatile uint32_t *target)
{
    uint32_t one = 1U;
    __asm volatile("amoadd.w zero, %1, (%0)" : : "r"(target), "r"(one) : "memory");
}

/*-----------------------------------------------------------*/
/* Atomic worker task - stress A extension under preemption */

static void vAtomicWorkerTask(void *pvParameters)
{
    (void) pvParameters;
    uint32_t i;

    for (i = 0; i < ATOMIC_ITERATIONS_PER_WORKER; i++) {
        atomic_inc_amo(&ulAtomicCounter);

        /* Force frequent interleaving across tasks. */
        if ((i & 0x3FU) == 0U) {
            taskYIELD();
        }
    }

    if (xConsumerTaskHandle != NULL) {
        xTaskNotifyGive(xConsumerTaskHandle);
    }

    vTaskDelete(NULL);
}

/*-----------------------------------------------------------*/
/* Tick inside a critical section */

/* Outcome of prvTickInCriticalSection */
typedef enum {
    eTickCheckNotRun,   /* the helper task could not be created */
    eTickCheckLost,     /* the switch the tick asked for never ran */
    eTickCheckDeferred, /* the switch ran once the section ended */
} TickCheckResult_t;

/* Stays ready at the consumer's priority, so each tick asks for a time-slice switch */
static void vTickHelperTask(void *pvParameters)
{
    (void) pvParameters;

    for (;;) {
        ulHelperRuns++;
        taskYIELD();
    }
}

/* Re-enable interrupts inside a critical section and wait for a tick while an
 * equal-priority task is ready. The tick must not switch tasks inside the
 * section, and the switch it asks for must run once the section ends. A switch
 * inside the section, or a second tick in it, prints <<FAIL>> and stops. */
static TickCheckResult_t prvTickInCriticalSection(void)
{
    TaskHandle_t xSelf = xTaskGetCurrentTaskHandle();
    TaskHandle_t xHelper = NULL;
    TickType_t xStart;
    uint32_t ulRunsBefore;
    uint32_t ulAttempt;
    TickCheckResult_t eResult;

    /* The helper's stack comes from the heap, which holds the finished tasks'
     * stacks until the idle task frees them, so retry after a tick. */
    for (ulAttempt = 0U; xTaskCreate(vTickHelperTask,
                                     "Helper",
                                     ATOMIC_TASK_STACK_SIZE,
                                     NULL,
                                     tskIDLE_PRIORITY + 2,
                                     &xHelper) != pdPASS;
         ulAttempt++) {
        if (ulAttempt == 10U) {
            safe_print("[Consumer] Helper task creation failed\r\n");
            return eTickCheckNotRun;
        }
        vTaskDelay(1);
    }

    taskENTER_CRITICAL();
    ulRunsBefore = ulHelperRuns;
    /* Read the count while interrupts are still off, so the wait ends at the first tick
     * taken in the section, even one already pending when interrupts come on. */
    xStart = xTaskGetTickCount();
    portENABLE_INTERRUPTS();
    while (xTaskGetTickCount() == xStart) {
    }
    portDISABLE_INTERRUPTS();
    /* No further ticks until the checks are done, so only the switch this tick
     * asked for can run the helper. */
    csr_clear(mie, MIE_MTIE);
    if ((TickType_t) (xTaskGetTickCount() - xStart) != 1U) {
        /* A second tick, taken only if the next one is already due when the first
         * returns, could undo a switch made by the first and hide it from the checks
         * below. */
        uart_puts("[Consumer] More than one tick in the critical section\r\n");
        uart_puts("\r\nFAIL\r\n<<FAIL>>\r\n");
        for (;;) {
        }
    }
    if ((xTaskGetCurrentTaskHandle() != xSelf) || (ulHelperRuns != ulRunsBefore)) {
        /* The section was preempted, or pxCurrentTCB no longer names this task */
        uart_puts("[Consumer] Tick in a critical section switched tasks\r\n");
        uart_puts("\r\nFAIL\r\n<<FAIL>>\r\n");
        for (;;) {
        }
    }
    taskEXIT_CRITICAL();

    eResult = (ulHelperRuns != ulRunsBefore) ? eTickCheckDeferred : eTickCheckLost;
    csr_set(mie, MIE_MTIE);
    vTaskDelete(xHelper);
    return eResult;
}

/*-----------------------------------------------------------*/
/* Consumer Task - receives data from queue */

static void vConsumerTask(void *pvParameters)
{
    (void) pvParameters;
    uint32_t ulReceived;
    uint32_t i;
    BaseType_t xQueueOk;
    BaseType_t xAtomicOk;
    TickCheckResult_t eTickCheck;
    const uint32_t ulAtomicExpected = ATOMIC_WORKER_TASKS * ATOMIC_ITERATIONS_PER_WORKER;

    safe_print("[Consumer] Task started (higher priority)\r\n");

    while (ulConsumerCount < NUM_ITEMS) {
        safe_print("[Consumer] Waiting for queue data...\r\n");

        /* Receive from queue - blocks if empty */
        if (xQueueReceive(xDataQueue, &ulReceived, portMAX_DELAY) == pdPASS) {
            ulConsumerCount++;
            if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
                uart_puts("[Consumer] Received item ");
                uart_putchar('0' + ulReceived);
                uart_puts(" from queue\r\n");
                xSemaphoreGive(xUartMutex);
            }
        }
    }

    safe_print("[Consumer] Waiting for atomic worker completion...\r\n");
    /* pdFALSE takes one notification per call, so both workers count even if
     * both notified before the first take. */
    for (i = 0; i < ATOMIC_WORKER_TASKS; i++) {
        (void) ulTaskNotifyTake(pdFALSE, portMAX_DELAY);
    }

    safe_print("[Consumer] Waiting for a tick inside a critical section...\r\n");
    eTickCheck = prvTickInCriticalSection();

    xQueueOk = (ulProducerCount == NUM_ITEMS) && (ulConsumerCount == NUM_ITEMS);
    xAtomicOk = (ulAtomicCounter == ulAtomicExpected);

    /* Print summary */
    if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
        uart_puts("\r\n");
        uart_puts("=== Demo Complete ===\r\n");
        uart_printf("Producer sent: %lu items\r\n", (unsigned long) ulProducerCount);
        uart_printf("Consumer received: %lu items\r\n", (unsigned long) ulConsumerCount);
        uart_printf("Atomic counter: %lu/%lu\r\n",
                    (unsigned long) ulAtomicCounter,
                    (unsigned long) ulAtomicExpected);
        uart_printf("Ticks: %lu\r\n", (unsigned long) xTaskGetTickCount());
        uart_puts("Tick in a critical section: ");
        if (eTickCheck == eTickCheckDeferred) {
            uart_puts("switch deferred\r\n");
        } else if (eTickCheck == eTickCheckLost) {
            uart_puts("switch lost\r\n");
        } else {
            uart_puts("not run\r\n");
        }
        uart_puts("All checks: ");
        if (xQueueOk == pdTRUE && xAtomicOk == pdTRUE && eTickCheck == eTickCheckDeferred) {
            uart_puts("Working!\r\n");
            uart_puts("\r\nPASS\r\n");
            uart_puts("<<PASS>>\r\n");
        } else {
            uart_puts("FAILED\r\n");
            uart_puts("\r\nFAIL\r\n");
            uart_puts("<<FAIL>>\r\n");
        }
        xSemaphoreGive(xUartMutex);
    }

    /* Disable interrupts and halt */
    __asm volatile("csrci mstatus, 0x08");
    for (;;) {
    }
}

/*-----------------------------------------------------------*/
/* Trap handler setup */

static void prvSetupTrapHandler(void)
{
    __asm volatile("csrw mtvec, %0" ::"r"(freertos_risc_v_trap_handler));
}

/*-----------------------------------------------------------*/
/* Main entry point */

int main(void)
{
    uart_puts("\r\n");
    uart_puts("========================================\r\n");
    uart_puts("  FreeRTOS Demo for FROST RISC-V CPU\r\n");
    uart_puts("========================================\r\n");
    uart_puts("Features demonstrated:\r\n");
    uart_puts("  - Multiple concurrent tasks\r\n");
    uart_puts("  - Inter-task queue communication\r\n");
    uart_puts("  - Mutex protecting shared UART\r\n");
    uart_puts("  - Preemptive priority scheduling\r\n");
    uart_puts("  - Tick-driven time slicing\r\n");
    uart_puts("  - Blocking on queue empty/full\r\n");
    uart_puts("========================================\r\n\r\n");

    prvSetupTrapHandler();

    /* Create the mutex for UART protection */
    xUartMutex = xSemaphoreCreateMutex();
    if (xUartMutex == NULL) {
        uart_puts("[ERROR] Mutex creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created UART mutex\r\n");

    /* Create the data queue */
    xDataQueue = xQueueCreate(QUEUE_LENGTH, sizeof(uint32_t));
    if (xDataQueue == NULL) {
        uart_puts("[ERROR] Queue creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created data queue (depth=3)\r\n");

    /* Create producer task (priority 1) */
    if (xTaskCreate(vProducerTask, "Producer", TASK_STACK_SIZE, NULL, tskIDLE_PRIORITY + 1, NULL) !=
        pdPASS) {
        uart_puts("[ERROR] Producer task creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created Producer task (priority 1)\r\n");

    /* Create consumer task (priority 2: preempts the producer whenever the queue has data) */
    if (xTaskCreate(vConsumerTask,
                    "Consumer",
                    TASK_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    &xConsumerTaskHandle) != pdPASS) {
        uart_puts("[ERROR] Consumer task creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created Consumer task (priority 2)\r\n");

    /* Create atomic stress workers (priority 1) */
    if (xTaskCreate(vAtomicWorkerTask,
                    "Atomic1",
                    ATOMIC_TASK_STACK_SIZE,
                    (void *) &ulAtomicWorkerIds[0],
                    tskIDLE_PRIORITY + 1,
                    NULL) != pdPASS) {
        uart_puts("[ERROR] Atomic1 task creation failed\r\n");
        for (;;)
            ;
    }

    if (xTaskCreate(vAtomicWorkerTask,
                    "Atomic2",
                    ATOMIC_TASK_STACK_SIZE,
                    (void *) &ulAtomicWorkerIds[1],
                    tskIDLE_PRIORITY + 1,
                    NULL) != pdPASS) {
        uart_puts("[ERROR] Atomic2 task creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created Atomic workers (priority 1)\r\n");

    uart_puts("[Main] Starting scheduler...\r\n\r\n");

    /* Start the scheduler - never returns */
    vTaskStartScheduler();

    /* Should never reach here */
    uart_puts("[ERROR] Scheduler returned!\r\n");
    for (;;)
        ;
    return 0;
}

/*-----------------------------------------------------------*/
/* Exception Handlers */

void freertos_risc_v_application_exception_handler(void)
{
    unsigned long mcause, mepc;
    __asm volatile("csrr %0, mcause" : "=r"(mcause));
    __asm volatile("csrr %0, mepc" : "=r"(mepc));
    uart_printf("\r\n[EXCEPTION] cause=%lu at PC=0x%016lx\r\n", mcause, mepc);
    for (;;)
        ;
}

void freertos_risc_v_application_interrupt_handler(void)
{
    uart_puts("\r\n[UNHANDLED IRQ]\r\n");
    for (;;)
        ;
}

void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void) xTask;
    (void) pcTaskName;
    uart_puts("[STACK OVERFLOW]\r\n");
    for (;;)
        ;
}

void vApplicationMallocFailedHook(void)
{
    uart_puts("[MALLOC FAILED]\r\n");
    for (;;)
        ;
}
