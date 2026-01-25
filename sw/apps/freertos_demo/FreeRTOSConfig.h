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
 * FreeRTOS Configuration for FROST RISC-V Processor
 *
 * This configuration is for a minimal FreeRTOS setup targeting:
 *   - RV32IMAB with M-mode only
 *   - Single core (mhartid = 0)
 *   - CLINT-style timer (mtime/mtimecmp)
 *   - 300 MHz clock frequency
 */

#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/*-----------------------------------------------------------
 * Application specific definitions.
 *----------------------------------------------------------*/

/* Scheduler settings */
#define configUSE_PREEMPTION 1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0 /* Disable - requires CLZ instruction */
#define configUSE_TICKLESS_IDLE 0
#define configUSE_IDLE_HOOK 0
#define configUSE_TICK_HOOK 0

/* CPU and tick rate */
#define configCPU_CLOCK_HZ (300000000UL) /* FROST runs at 300 MHz */
#define configTICK_RATE_HZ (1000)        /* 1ms tick */

/* Memory allocation */
#define configMINIMAL_STACK_SIZE (256)   /* Idle task stack (words) */
#define configTOTAL_HEAP_SIZE (8 * 1024) /* 8KB heap for FreeRTOS */
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

/* Disable features we don't need for minimal demo */
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
/* CLINT timer addresses for FROST */
#define configMTIME_BASE_ADDRESS (0x40000010UL)    /* mtime register */
#define configMTIMECMP_BASE_ADDRESS (0x40000018UL) /* mtimecmp register */

/* ISR stack - allocate a dedicated ISR stack within FreeRTOS
 * This avoids linker symbol issues with the RISC-V GCC toolchain */
#define configISR_STACK_SIZE_WORDS (256)

/* Assert and debug */
#define configASSERT(x)                                                                            \
    if ((x) == 0) {                                                                                \
        for (;;)                                                                                   \
            ;                                                                                      \
    }
#define configCHECK_FOR_STACK_OVERFLOW 0 /* Disable for minimal demo */
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
#define INCLUDE_xTaskGetCurrentTaskHandle 0
#define INCLUDE_uxTaskGetStackHighWaterMark 0
#define INCLUDE_xTaskGetIdleTaskHandle 0
#define INCLUDE_eTaskGetState 0
#define INCLUDE_xEventGroupSetBitFromISR 0
#define INCLUDE_xTimerPendFunctionCall 0
#define INCLUDE_xTaskAbortDelay 0
#define INCLUDE_xTaskGetHandle 0
#define INCLUDE_xTaskResumeFromISR 0

#endif /* FREERTOS_CONFIG_H */
