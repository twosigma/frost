/*
 * FreeRTOS port for FROST, assembly half: the M-mode trap handler, the yield
 * and tick context switches, and first-task start.
 */

.section .text
.align 2

.global freertos_risc_v_trap_handler
.global pxCurrentTCB
.global xPortStartFirstTask

/* FreeRTOS external functions */
.extern vPortTimerTickHandler
.extern freertos_risc_v_application_exception_handler
.extern freertos_risc_v_application_interrupt_handler
.extern vPortDebugTrap
.extern vPortDebugRestore
.extern vPortDebugTCB
.extern vPortDebugRA

/* Critical section nesting counter */
.extern uxCriticalNesting

/* Context size: 28 GPRs + mepc + mstatus + uxCriticalNesting = 31 XLEN-wide
 * slots, rounded up to 16-byte alignment (248->256 bytes).
 * STORE/LOAD/XB select the register-width access; pointer-holding
 * globals (pxCurrentTCB->pxTopOfStack, uxCriticalNesting = UBaseType_t) are
 * XLEN-wide too and use the same macros. */
#define STORE sd
#define LOAD ld
#define XB 8
#define portCONTEXT_SIZE 256
#define MCAUSE_MTI_LITERAL 0x8000000000000007

/*-----------------------------------------------------------*/
/* freertos_risc_v_trap_handler
 *
 * Trap entry (mtvec) for exceptions and interrupts. Saves the full context on
 * the interrupted task's stack, dispatches on mcause, and returns through
 * whichever context pxCurrentTCB selects afterwards.
 */
.align 4
freertos_risc_v_trap_handler:
    /* Save context on current stack */
    addi sp, sp, -portCONTEXT_SIZE

    /* Save all registers */
    STORE x1,  0*XB(sp)
    STORE x5,  1*XB(sp)
    STORE x6,  2*XB(sp)
    STORE x7,  3*XB(sp)
    STORE x8,  4*XB(sp)
    STORE x9,  5*XB(sp)
    STORE x10, 6*XB(sp)
    STORE x11, 7*XB(sp)
    STORE x12, 8*XB(sp)
    STORE x13, 9*XB(sp)
    STORE x14, 10*XB(sp)
    STORE x15, 11*XB(sp)
    STORE x16, 12*XB(sp)
    STORE x17, 13*XB(sp)
    STORE x18, 14*XB(sp)
    STORE x19, 15*XB(sp)
    STORE x20, 16*XB(sp)
    STORE x21, 17*XB(sp)
    STORE x22, 18*XB(sp)
    STORE x23, 19*XB(sp)
    STORE x24, 20*XB(sp)
    STORE x25, 21*XB(sp)
    STORE x26, 22*XB(sp)
    STORE x27, 23*XB(sp)
    STORE x28, 24*XB(sp)
    STORE x29, 25*XB(sp)
    STORE x30, 26*XB(sp)
    STORE x31, 27*XB(sp)

    /* Save mepc */
    csrr t0, mepc
    STORE t0, 28*XB(sp)

    /* Save mstatus */
    csrr t1, mstatus
    STORE t1, 29*XB(sp)

    /* Save uxCriticalNesting to stack */
    la t0, uxCriticalNesting
    LOAD t1, 0(t0)
    STORE t1, 30*XB(sp)

    /* Save current SP to pxCurrentTCB if it exists */
    la t0, pxCurrentTCB
    LOAD t1, 0(t0)
    beqz t1, skip_save_sp
    STORE sp, 0(t1)

skip_save_sp:
    /* Run the handler with nesting = 1: critical sections entered by the kernel
     * calls below unwind to 1, never to 0, so they cannot re-enable interrupts */
    la t0, uxCriticalNesting
    li t1, 1
    STORE t1, 0(t0)

    /* Check if interrupt or exception */
    csrr t0, mcause
    blt t0, zero, handle_interrupt

handle_exception:
    /* mcause 11 = ecall from M-mode: a yield request */
    li t1, 11
    beq t0, t1, handle_yield

    /* Other exception - call application handler */
    call freertos_risc_v_application_exception_handler
    j trap_exit

handle_yield:
    /* ECALL: advance mepc past the ecall instruction (4 bytes) */
    LOAD t0, 28*XB(sp)
    addi t0, t0, 4
    STORE t0, 28*XB(sp)

    /* Save sp and the TCB before calling vTaskSwitchContext
     * s0 = original sp (the saved context lives here)
     * s1 = original pxCurrentTCB pointer */
    mv s0, sp
    la t0, pxCurrentTCB
    LOAD s1, 0(t0)

    /* Select the next task */
    call vTaskSwitchContext

    /* Check if pxCurrentTCB changed */
    la t0, pxCurrentTCB
    LOAD t1, 0(t0)
    beq t1, s1, yield_same_task  /* same task: keep the saved sp */

    /* Different task - reload SP from new pxCurrentTCB */
    beqz t1, yield_same_task
    LOAD sp, 0(t1)
    j trap_exit

yield_same_task:
    /* Same task: restore the original sp */
    mv sp, s0
    j trap_exit

handle_interrupt:
    /* Machine timer interrupt: mcause = MCAUSE_MTI_LITERAL (interrupt bit | 7) */
    li t1, MCAUSE_MTI_LITERAL
    beq t0, t1, handle_timer

    /* Other interrupt - call application handler */
    call freertos_risc_v_application_interrupt_handler
    j trap_exit

handle_timer:
    /* Save sp and the TCB before calling the handler
     * s0 = original sp (the saved context lives here)
     * s1 = original pxCurrentTCB pointer */
    mv s0, sp
    la t0, pxCurrentTCB
    LOAD s1, 0(t0)

    /* C tick handler; may call vTaskSwitchContext */
    call vPortTimerTickHandler

    /* If the interrupted code was inside a critical section (saved nesting > 0),
     * do not switch */
    LOAD t1, 30*XB(sp)
    bnez t1, timer_same_task

    /* Check if pxCurrentTCB changed */
    la t0, pxCurrentTCB
    LOAD t1, 0(t0)
    beq t1, s1, timer_same_task  /* same task: keep the saved sp */

    /* Different task - reload SP from new pxCurrentTCB */
    beqz t1, timer_same_task
    LOAD sp, 0(t1)
    j trap_exit

timer_same_task:
    /* Same task: restore the original sp */
    mv sp, s0
    /* Fall through to trap_exit */

trap_exit:
    /* Restore uxCriticalNesting from stack */
    LOAD t1, 30*XB(sp)
    la t0, uxCriticalNesting
    STORE t1, 0(t0)

    /* Restore mstatus */
    LOAD t1, 29*XB(sp)
    csrw mstatus, t1

    /* Restore mepc */
    LOAD t0, 28*XB(sp)
    csrw mepc, t0

    /* Restore all registers */
    LOAD x31, 27*XB(sp)
    LOAD x30, 26*XB(sp)
    LOAD x29, 25*XB(sp)
    LOAD x28, 24*XB(sp)
    LOAD x27, 23*XB(sp)
    LOAD x26, 22*XB(sp)
    LOAD x25, 21*XB(sp)
    LOAD x24, 20*XB(sp)
    LOAD x23, 19*XB(sp)
    LOAD x22, 18*XB(sp)
    LOAD x21, 17*XB(sp)
    LOAD x20, 16*XB(sp)
    LOAD x19, 15*XB(sp)
    LOAD x18, 14*XB(sp)
    LOAD x17, 13*XB(sp)
    LOAD x16, 12*XB(sp)
    LOAD x15, 11*XB(sp)
    LOAD x14, 10*XB(sp)
    LOAD x13, 9*XB(sp)
    LOAD x12, 8*XB(sp)
    LOAD x11, 7*XB(sp)
    LOAD x10, 6*XB(sp)
    LOAD x9,  5*XB(sp)
    LOAD x8,  4*XB(sp)
    LOAD x7,  3*XB(sp)
    LOAD x6,  2*XB(sp)
    LOAD x5,  1*XB(sp)
    LOAD x1,  0*XB(sp)

    addi sp, sp, portCONTEXT_SIZE

    mret

/*-----------------------------------------------------------*/
/* xPortStartFirstTask
 *
 * Called from xPortStartScheduler. Loads the first task's saved context from
 * pxCurrentTCB and enters it with mret; never returns.
 */
xPortStartFirstTask:
    /* Load stack pointer from pxCurrentTCB */
    la t0, pxCurrentTCB
    LOAD t1, 0(t0)
    LOAD sp, 0(t1)

    /* Restore uxCriticalNesting from stack */
    LOAD t1, 30*XB(sp)
    la t0, uxCriticalNesting
    STORE t1, 0(t0)

    /* Restore mstatus */
    LOAD t1, 29*XB(sp)
    csrw mstatus, t1

    /* Restore mepc */
    LOAD t0, 28*XB(sp)
    csrw mepc, t0

    /* Restore all registers */
    LOAD x31, 27*XB(sp)
    LOAD x30, 26*XB(sp)
    LOAD x29, 25*XB(sp)
    LOAD x28, 24*XB(sp)
    LOAD x27, 23*XB(sp)
    LOAD x26, 22*XB(sp)
    LOAD x25, 21*XB(sp)
    LOAD x24, 20*XB(sp)
    LOAD x23, 19*XB(sp)
    LOAD x22, 18*XB(sp)
    LOAD x21, 17*XB(sp)
    LOAD x20, 16*XB(sp)
    LOAD x19, 15*XB(sp)
    LOAD x18, 14*XB(sp)
    LOAD x17, 13*XB(sp)
    LOAD x16, 12*XB(sp)
    LOAD x15, 11*XB(sp)
    LOAD x14, 10*XB(sp)
    LOAD x13, 9*XB(sp)
    LOAD x12, 8*XB(sp)
    LOAD x11, 7*XB(sp)
    LOAD x10, 6*XB(sp)
    LOAD x9,  5*XB(sp)
    LOAD x8,  4*XB(sp)
    LOAD x7,  3*XB(sp)
    LOAD x6,  2*XB(sp)
    LOAD x5,  1*XB(sp)
    LOAD x1,  0*XB(sp)

    addi sp, sp, portCONTEXT_SIZE

    mret
