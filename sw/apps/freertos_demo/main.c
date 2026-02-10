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
 * FreeRTOS Demo for FROST RISC-V Processor
 *
 * Demonstrates:
 *   - Multiple concurrent tasks
 *   - Inter-task communication via queues
 *   - Mutex for shared resource protection
 *   - Preemptive scheduling with priorities
 *   - Blocking/yielding behavior
 */

#include "FreeRTOS.h"
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

/*-----------------------------------------------------------*/
/* Safe UART output with mutex protection */

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
        /* Show we're about to send */
        if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
            uart_puts("[Producer] Sending item ");
            uart_putchar('0' + ulValue);
            uart_puts(" to queue...\r\n");
            xSemaphoreGive(xUartMutex);
        }

        /* Send to queue - may block if full */
        /* Increment count before send since consumer may preempt immediately */
        ulProducerCount++;
        if (xQueueSend(xDataQueue, &ulValue, portMAX_DELAY) == pdPASS) {
            if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
                uart_puts("[Producer] Item ");
                uart_putchar('0' + ulValue);
                uart_puts(" sent (queue may wake consumer)\r\n");
                xSemaphoreGive(xUartMutex);
            }
        }

        /* Yield to demonstrate cooperative scheduling */
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
/* Consumer Task - receives data from queue */

static void vConsumerTask(void *pvParameters)
{
    (void) pvParameters;
    uint32_t ulReceived;
    uint32_t i;
    BaseType_t xQueueOk;
    BaseType_t xAtomicOk;
    const uint32_t ulAtomicExpected = ATOMIC_WORKER_TASKS * ATOMIC_ITERATIONS_PER_WORKER;

    safe_print("[Consumer] Task started (higher priority)\r\n");

    while (ulConsumerCount < NUM_ITEMS) {
        /* Show we're waiting */
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
    for (i = 0; i < ATOMIC_WORKER_TASKS; i++) {
        (void) ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    }

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
        uart_puts("Queue + Mutex + Preemption + A-extension stress: ");
        if (xQueueOk == pdTRUE && xAtomicOk == pdTRUE) {
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

    /* Create consumer task (priority 2 - higher, runs first when data available) */
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
    uint32_t mcause, mepc;
    __asm volatile("csrr %0, mcause" : "=r"(mcause));
    __asm volatile("csrr %0, mepc" : "=r"(mepc));
    uart_puts("\r\n[EXCEPTION] cause=");
    uart_putchar('0' + (mcause & 0xF));
    uart_puts(" at PC=0x");
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 7; i >= 0; i--) {
        uart_putchar(hex[(mepc >> (i * 4)) & 0xF]);
    }
    uart_puts("\r\n");
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
