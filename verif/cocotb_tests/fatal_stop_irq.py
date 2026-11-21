#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Observe retirement, memory requests and interrupt entry after a writeback error."""

from typing import Any

import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import FallingEdge

# Each tuple names the source, its mcause code, and its interrupt_t bit mask.
MACHINE_IRQS = (("external", 11, 0b100), ("timer", 7, 0b010), ("software", 3, 0b001))
IRQ_CASES = tuple(
    (name, cause, line, at_stop)
    for name, cause, line in MACHINE_IRQS
    for at_stop in (True, False)
)
IRQ_DELAY = 4
IRQ_WINDOW = 64


async def check_fatal_stop_irq(
    dut: Any, uart: Any, clock: Any, run_number: int, max_cycles: int, fatal_line: int
) -> str | None:
    """Check one interrupt class and arrival time through a real writeback stop."""
    irq_name, cause_number, irq_line, at_stop = IRQ_CASES[run_number - 1]
    label = f"{irq_name}/{'at-stop' if at_stop else 'after-stop'}"
    irq_bit = 1 << cause_number
    irq_cause = (1 << 63) | cause_number
    use_external_pin = irq_name == "external"
    use_pin_while_stopped = use_external_pin and not at_stop
    platform = dut.cpu_and_memory_subsystem
    bus = platform.cpu
    soc = platform.soc
    cpu = bus.hart.cpu_inst
    csr = cpu.csr_file_inst
    cycle = 0
    edge = FallingEdge(clock)
    requests = {
        "ar": (bus.o_axi_arvalid, bus.i_axi_arready),
        "aw": (bus.o_axi_awvalid, bus.i_axi_awready),
        "w": (bus.o_axi_wvalid, bus.i_axi_wready),
        "data": (bus.data_req_valid, bus.data_req_ready),
        "fetch": (bus.low_req_valid, bus.low_req_ready),
        "ddr_ar": (soc.axi_arvalid, soc.axi_arready),
        "ddr_aw": (soc.axi_awvalid, soc.axi_awready),
        "ddr_w": (soc.axi_wvalid, soc.axi_wready),
    }
    read_addresses = {
        "fetch": (bus.low_req_addr, bus.low_req_id),
        "ar": (bus.o_axi_araddr, bus.o_axi_arid),
        "ddr_ar": (soc.axi_araddr, soc.axi_arid),
    }
    responses = {
        "b": (bus.i_axi_bvalid, bus.o_axi_bready),
        "r": (bus.i_axi_rvalid, bus.o_axi_rready),
        "ddr_b": (soc.axi_bvalid, soc.axi_bready),
        "ddr_r": (soc.axi_rvalid, soc.axi_rready),
    }
    trap_state_signals = (
        csr.mcause,
        cpu.csr_mepc,
        cpu.csr_mstatus,
        csr.mtval,
        csr.scause,
        cpu.csr_sepc,
        csr.stval,
        cpu.csr_priv,
        cpu.csr_mie,
    )

    async def step() -> None:
        # Sample settled values used at the following rising edge.
        nonlocal cycle
        await edge
        cycle += 1
        assert not uart.contains("<<FAIL>>"), "memerr_test printed <<FAIL>>"

    def trap_state() -> tuple[int, ...]:
        return tuple(int(signal.value) for signal in trap_state_signals)

    def irq_pending() -> bool:
        return bool(int(csr.mip.value) & irq_bit)

    def drive_irq(active: bool, *, use_pin: bool) -> None:
        # The pin exercises APLIC delivery. The hart's platform interrupt bus
        # lets the bench drive timer and software interrupts from outside the
        # hart and align MEI with the stop edge.
        if use_pin:
            dut.i_external_interrupt.value = int(active)
        else:
            platform.cpu_interrupts.value = Force(irq_line) if active else Release()

    for _ in range(max_cycles):
        await step()
        if uart.contains("<<EXPECT_IRQ>>"):
            break
    else:
        raise AssertionError("memerr_test did not arm the running IRQ control")
    assert not int(cpu.i_fatal_stop.value) and not irq_pending()
    assert int(cpu.csr_mie.value) & irq_bit and int(cpu.csr_mstatus_mie_direct.value)
    assert int(csr.instret_counter.value) > 0
    engine = int(dut.MISALIGNED_HW.value)
    cocotb.log.info(
        f"FATALSTOP run={run_number} case={label} MISALIGNED_HW={engine} "
        f"cycle={cycle} drive running IRQ"
    )
    drive_irq(True, use_pin=use_external_pin)
    for _ in range(IRQ_WINDOW):
        await step()
        assert not int(cpu.i_fatal_stop.value), "fatal stop preceded the IRQ control"
        if int(cpu.trap_save_m.value):
            assert irq_pending()
            assert int(cpu.trap_cause_internal.value) == irq_cause
            saved_pc = int(cpu.trap_pc_internal.value)
            take_cycle = cycle
            await step()
            drive_irq(False, use_pin=use_external_pin)
            assert trap_state()[:2] == (irq_cause, saved_pc)
            assert not int(cpu.csr_mstatus_mie_direct.value)
            cocotb.log.info(
                f"FATALSTOP case={label} running IRQ take cycle={take_cycle} "
                f"mcause={irq_cause:#x} mepc={saved_pc:#x}"
            )
            break
    else:
        raise AssertionError(f"running hart did not take the {irq_name} interrupt")

    completed_requests: set[str] = set()
    irq_driven = False
    while cycle < max_cycles:
        await step()
        if int(cpu.i_fatal_stop.value):
            break
        if at_stop and int(bus.cache_fatal.value) and not irq_driven:
            # cpu_top latches the hart stop on the next edge. MEI crosses
            # the IMSIC delivery register on that edge as well.
            drive_irq(True, use_pin=False)
            irq_driven = True
            cocotb.log.info(f"FATALSTOP case={label} drive IRQ before stop at {cycle}")
        for channel, (valid, ready) in requests.items():
            if int(valid.value) and int(ready.value):
                completed_requests.add(channel)
    else:
        raise AssertionError("memerr_test did not reach the fatal stop")
    assert uart.contains("[PASS] irq-handler"), (
        "firmware did not service the control IRQ"
    )
    assert uart.contains("<<EXPECT_FATAL>>"), "unexpected fatal stop"
    assert {"ddr_ar", "ddr_aw", "ddr_w"} <= completed_requests, (
        "missing DDR traffic before stop"
    )
    assert int(bus.o_fatal_addr.value) == fatal_line
    assert int(soc.memory_errors.axi_wr_errs_q.value) == 1
    assert int(cpu.csr_mie.value) & irq_bit and int(cpu.csr_mstatus_mie_direct.value)
    assert irq_driven == at_stop and irq_pending() == at_stop, (
        f"{label}: wrong pending state at the first stopped cycle {cycle}"
    )
    before = trap_state()
    assert before[:2] == (0, 0), "trap CSRs were not cleared after the IRQ control"
    stop_cycle = cycle
    cocotb.log.info(
        f"FATALSTOP case={label} stop cycle={stop_cycle} address={fatal_line:#x} "
        f"pre-stop transfers={','.join(sorted(completed_requests))}"
    )

    retire_cycles: list[int] = []
    request_cycles: list[int] = []
    take_cycles: list[int] = []
    first_csr_change: int | None = None
    stopped_instret: int | None = None
    pending_cycles = 0
    for offset in range(IRQ_DELAY + IRQ_WINDOW):
        if offset:
            await step()
        assert int(cpu.i_fatal_stop.value) and int(bus.o_fatal_error.value)
        assert int(bus.o_fatal_addr.value) == fatal_line
        # The registered commit and minstret stages can finish older work.
        # Raw commit enables are checked from the first cycle of the stop.
        retired = int(cpu.rob_commit_valid_raw.value) + int(
            cpu.rob_commit_2_valid_raw.value
        )
        instret = int(csr.instret_counter.value)
        if offset == IRQ_DELAY:
            stopped_instret = instret
        if retired or (stopped_instret is not None and instret != stopped_instret):
            retire_cycles.append(cycle)
        offers = [
            channel for channel, (valid, _) in requests.items() if int(valid.value)
        ]
        transfers = [channel for channel in offers if int(requests[channel][1].value)]
        reads = [
            f"{channel}:{int(addr.value):#x}/id{int(tag.value)}"
            for channel, (addr, tag) in read_addresses.items()
            if channel in transfers
        ]
        if offers:
            request_cycles.append(cycle)
        drained = [
            channel
            for channel, (valid, ready) in responses.items()
            if int(valid.value) and int(ready.value)
        ]
        pending = irq_pending()
        assert not pending or irq_driven, "pending interrupt preceded the test stimulus"
        pending_cycles += int(pending)
        take = int(cpu.trap_taken.value)
        target = "-"
        if take:
            take_cycles.append(cycle)
            target = f"{int(cpu.trap_entry_target.value):#x}"
        state = trap_state()
        cause, epc, status = state[:3]
        if first_csr_change is None and state != before:
            first_csr_change = cycle
        cocotb.log.info(
            f"FATALSTOP cycle={cycle} stop+{offset} "
            f"irq={int(irq_driven)} pending={int(pending)} "
            f"ma_shield={int(cpu.ma_shield.value)} armed={int(cpu.int_take_armed.value)} "
            f"take={take} save_m={int(cpu.trap_save_m.value)} target={target} "
            f"mcause={cause:#x} mepc={epc:#x} mstatus={status:#x} "
            f"raw_retire={retired} minstret={instret} "
            f"offer={','.join(offers) or '-'} transfer={','.join(transfers) or '-'} "
            f"reads={','.join(reads) or '-'} response={','.join(drained) or '-'}"
        )
        if not at_stop and offset == IRQ_DELAY - 1:
            cocotb.log.info(
                f"FATALSTOP case={label} drive stopped IRQ at cycle={cycle}"
            )
            drive_irq(True, use_pin=use_pin_while_stopped)
            irq_driven = True
    drive_irq(False, use_pin=use_pin_while_stopped)
    result = (
        f"case={label} stop window {stop_cycle}..{cycle}: "
        f"pending_cycles={pending_cycles} retire={retire_cycles} requests={request_cycles} "
        f"takes={take_cycles} first_csr_change={first_csr_change}"
    )
    cocotb.log.info(f"FATALSTOP {result}")
    assert pending_cycles >= IRQ_WINDOW - 4, (
        f"the stopped hart did not see the {label} interrupt held pending"
    )

    if run_number == len(IRQ_CASES):
        # A hart-side halt request must not enter Debug Mode after the stop.
        await step()
        assert not irq_pending() and not int(cpu.csr_debug_mode.value)
        halt_cycle = cycle
        platform.dbg_haltreq.value = Force(1)
        debug_cycle = None
        for _ in range(IRQ_WINDOW):
            await step()
            assert int(cpu.i_dbg_haltreq.value), "halt request did not reach the hart"
            if int(cpu.csr_debug_mode.value):
                debug_cycle = cycle
                break
        platform.dbg_haltreq.value = Release()
        cocotb.log.info(
            f"FATALSTOP debug halt after stop: MISALIGNED_HW={engine} "
            f"request={halt_cycle} last_sample={cycle} debug_entry={debug_cycle}"
        )
        assert debug_cycle is None, "a halt request entered Debug Mode after the stop"

    if retire_cycles or request_cycles or take_cycles or first_csr_change is not None:
        return f"activity after fatal stop: {result}"
    return None
