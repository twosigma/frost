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
 * FreeRTOS configuration for the FROST demo: a minimal kernel build for a
 * single RV64GCB hart (mhartid = 0) that runs every task in M-mode, with the
 * tick from the native mtime/mtimecmp timer and the software build's CPU clock.
 */

#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/*-----------------------------------------------------------
 * Application specific definitions.
 *----------------------------------------------------------*/

/* Scheduler settings */
#define configUSE_PREEMPTION 1
/* The port defines no portGET_HIGHEST_PRIORITY. */
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#define configUSE_TICKLESS_IDLE 0
#define configUSE_IDLE_HOOK 0
#define configUSE_TICK_HOOK 0

/* CPU and tick rate */
#define configCPU_CLOCK_HZ (FPGA_CPU_CLK_FREQ)
#define configTICK_RATE_HZ (1000) /* 1 ms tick */

/* Memory allocation */
#define configMINIMAL_STACK_SIZE (256) /* Idle task stack (words) */
/* Stack depths count StackType_t words, 8 bytes each. Every task stack and
 * kernel object is allocated from this heap. */
#define configTOTAL_HEAP_SIZE (16 * 1024)
#define configMAX_TASK_NAME_LEN (16)
#define configUSE_16_BIT_TICKS 0
#define configIDLE_SHOULD_YIELD 1

/* Task settings */
#define configMAX_PRIORITIES (5)
#define configUSE_MUTEXES 1
#define configUSE_RECURSIVE_MUTEXES 0
#define configUSE_COUNTING_SEMAPHORES 0
#define configQUEUE_REGISTRY_SIZE 0
#define configUSE_QUEUE_SETS 0
#define configUSE_TIME_SLICING 1
#define configSTACK_DEPTH_TYPE uint16_t
#define configMESSAGE_BUFFER_LENGTH_TYPE size_t

/* Feature trim. Task notifications stay on: the consumer waits on one per atomic worker. */
#define configUSE_TASK_NOTIFICATIONS 1
#define configTASK_NOTIFICATION_ARRAY_ENTRIES 1
#define configUSE_NEWLIB_REENTRANT 0
#define configENABLE_BACKWARD_COMPATIBILITY 0
#define configNUM_THREAD_LOCAL_STORAGE_POINTERS 0
#define configUSE_MINI_LIST_ITEM 1
#define configHEAP_CLEAR_MEMORY_ON_FREE 0

/* Software timer settings (disabled for minimal demo) */
#define configUSE_TIMERS 0
#define configTIMER_TASK_PRIORITY (configMAX_PRIORITIES - 1)
#define configTIMER_QUEUE_LENGTH 5
#define configTIMER_TASK_STACK_DEPTH configMINIMAL_STACK_SIZE

/* Co-routine settings (disabled) */
#define configUSE_CO_ROUTINES 0

/* RISC-V specific configuration */
/* Native timer addresses. Only the upstream RISC-V port uses these; port_frost.c reaches the
 * same registers through mmio.h. */
#define configMTIME_BASE_ADDRESS (0x40000010UL)    /* mtime register */
#define configMTIMECMP_BASE_ADDRESS (0x40000018UL) /* mtimecmp register */

/* Sized for the upstream RISC-V port's dedicated ISR stack. port_frost_asm.S does not use
 * it: traps run on the interrupted task's stack. */
#define configISR_STACK_SIZE_WORDS (256)

/* Assert and debug */
#define configASSERT(x)                                                                            \
    if ((x) == 0) {                                                                                \
        for (;;)                                                                                   \
            ;                                                                                      \
    }
/* On every switch away from a task, check its saved stack pointer and the 16
 * fill bytes at its stack limit; an overflow fails the run. There is no
 * malloc-failed hook: the tick check retries a helper whose stack allocation
 * fails. */
#define configCHECK_FOR_STACK_OVERFLOW 2
#define configGENERATE_RUN_TIME_STATS 0
#define configUSE_TRACE_FACILITY 0
#define configUSE_STATS_FORMATTING_FUNCTIONS 0

/* Set the following definitions to 1 to include the API function, or zero
 * to exclude the API function. */
#define INCLUDE_vTaskPrioritySet 0
#define INCLUDE_uxTaskPriorityGet 0
#define INCLUDE_vTaskDelete 1
#define INCLUDE_vTaskSuspend 0
#define INCLUDE_xResumeFromISR 0
#define INCLUDE_vTaskDelayUntil 1
#define INCLUDE_vTaskDelay 1
#define INCLUDE_xTaskGetSchedulerState 0
#define INCLUDE_xTaskGetCurrentTaskHandle 1
#define INCLUDE_uxTaskGetStackHighWaterMark 0
#define INCLUDE_xTaskGetIdleTaskHandle 0
#define INCLUDE_eTaskGetState 0
#define INCLUDE_xEventGroupSetBitFromISR 0
#define INCLUDE_xTimerPendFunctionCall 0
#define INCLUDE_xTaskAbortDelay 0
#define INCLUDE_xTaskGetHandle 0
#define INCLUDE_xTaskResumeFromISR 0

#endif /* FREERTOS_CONFIG_H */
