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
 * FROST-specific FreeRTOS port macros
 *
 * Minimal port configuration for FROST RISC-V M-mode processor.
 * This file defines types and macros required by FreeRTOS kernel.
 */

#ifndef PORTMACRO_H
#define PORTMACRO_H

#include <stddef.h>
#include <stdint.h>

/*-----------------------------------------------------------
 * Port specific definitions for FROST RISC-V
 *----------------------------------------------------------*/

#define portSTACK_GROWTH (-1)
#define portTICK_PERIOD_MS ((TickType_t) 1000 / configTICK_RATE_HZ)
#define portBYTE_ALIGNMENT 16
#define portPOINTER_SIZE_TYPE uint32_t

/*-----------------------------------------------------------
 * Critical section management
 *----------------------------------------------------------*/

extern void vPortEnterCritical(void);
extern void vPortExitCritical(void);

#define portDISABLE_INTERRUPTS() __asm volatile("csrci mstatus, 8")
#define portENABLE_INTERRUPTS() __asm volatile("csrsi mstatus, 8")

#define portENTER_CRITICAL() vPortEnterCritical()
#define portEXIT_CRITICAL() vPortExitCritical()

/*-----------------------------------------------------------
 * Task function macros
 *----------------------------------------------------------*/

#define portTASK_FUNCTION_PROTO(vFunction, pvParameters) void vFunction(void *pvParameters)
#define portTASK_FUNCTION(vFunction, pvParameters) void vFunction(void *pvParameters)

/*-----------------------------------------------------------
 * Scheduler utilities
 *----------------------------------------------------------*/

extern void vPortYield(void);
extern void vPortYieldWithinAPI(void);
#define portYIELD() vPortYield()
#define portYIELD_WITHIN_API() vPortYieldWithinAPI()

#define portEND_SWITCHING_ISR(xSwitchRequired)                                                     \
    if (xSwitchRequired)                                                                           \
    vPortYield()
#define portYIELD_FROM_ISR(x) portEND_SWITCHING_ISR(x)

/*-----------------------------------------------------------
 * Type definitions
 *----------------------------------------------------------*/

#define portSTACK_TYPE uint32_t
#define portBASE_TYPE int32_t
#define portUBASE_TYPE uint32_t
#define portMAX_DELAY (TickType_t) 0xffffffffUL

typedef portSTACK_TYPE StackType_t;
typedef portBASE_TYPE BaseType_t;
typedef portUBASE_TYPE UBaseType_t;
typedef uint32_t TickType_t;

#define portTICK_TYPE_IS_ATOMIC 1

/*-----------------------------------------------------------
 * Inline assembly helpers
 *----------------------------------------------------------*/

#define portNOP() __asm volatile("nop")

/*-----------------------------------------------------------
 * Unused port features for minimal demo
 *----------------------------------------------------------*/

#define portSUPPRESS_TICKS_AND_SLEEP(xExpectedIdleTime)

#endif /* PORTMACRO_H */
