// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import type { FrostSettings } from './settings';
import { OwnedProcess, ownsTcpListener, requireFreePort } from './process';

export const GDB_PORT = 3333;
export const HW_PORT = 3121;
export const HW_URL = `127.0.0.1:${HW_PORT}`;

export function imageResetDelayMs(cpuClockHz: number): number {
    // xilinx_frost_subsystem's 27-bit inactivity counter uses CPU/4, and
    // frost.sv subsequently synchronizes reset into the CPU clock domain.
    // A DMI pulse while the DM is reset can be lost permanently: do not use
    // the DMI link itself to poll for reset release. Start the full interval
    // after the loader exits, conservatively later than its final BRAM write.
    const milliseconds = Math.ceil(4 * 2 ** 27 * 1000 / cpuClockHz) + 250;
    if (!Number.isFinite(milliseconds) || cpuClockHz <= 0 || milliseconds > 2147483647) {
        throw new Error('CPU clock cannot define a supported image-reset wait');
    }
    return milliseconds;
}

export class Hardware {
    private owned = new Set<OwnedProcess>();
    constructor(private readonly output: (text: string) => void) {}

    async preflight(settings: FrostSettings, vivado: boolean): Promise<void> {
        for (const file of ['fpga/debug/openocd_x3.cfg', 'fpga/load_software/load_software.py']) {
            await fs.access(path.join(settings.repoRoot, file));
        }
        if (vivado && !settings.vivadoTarget.startsWith(`${HW_URL}/`)) {
            throw new Error(`Configure the exact Vivado target name beginning ${HW_URL}/. Substring target selection is not used.`);
        }
        // Conservative single-cable v1: refuse existing tool sessions. Do not
        // adopt or terminate an external server, even if it uses our port.
        for (const pid of await fs.readdir('/proc')) {
            if (!/^\d+$/.test(pid)) continue;
            let args: string[];
            try { args = (await fs.readFile(`/proc/${pid}/cmdline`, 'utf8')).split('\0'); }
            catch { continue; }
            if (args.some(arg => ['openocd', 'hw_server'].includes(path.basename(arg)))) {
                throw new Error(`Existing hardware tool PID ${pid} must release the cable first. It was left untouched.`);
            }
        }
        await requireFreePort(GDB_PORT);
        await requireFreePort(HW_PORT);
    }

    start(command: string, args: string[], settings: FrostSettings,
        env: NodeJS.ProcessEnv = process.env): OwnedProcess {
        this.output(`\nStarting ${path.basename(command)}\n`);
        const child = new OwnedProcess({ command, args, cwd: settings.repoRoot,
            env, output: text => this.output(text) });
        this.owned.add(child);
        return child;
    }

    async run(command: string, args: string[], settings: FrostSettings,
        signal: AbortSignal, env?: NodeJS.ProcessEnv): Promise<string> {
        signal.throwIfAborted();
        const child = this.start(command, args, settings, env);
        await child.wait(settings.toolTimeoutMs, signal);
        this.owned.delete(child);
        return child.log;
    }

    async startOpenOcd(settings: FrostSettings, signal: AbortSignal): Promise<OwnedProcess> {
        signal.throwIfAborted();
        await requireFreePort(GDB_PORT);
        const child = this.start(settings.openocdPath, [
            '-c', 'bindto 127.0.0.1', '-c', `gdb_port ${GDB_PORT}`,
            '-c', 'tcl_port disabled', '-c', 'telnet_port disabled',
            '-c', 'gdb_report_data_abort enable',
            '-f', 'fpga/debug/openocd_x3.cfg',
            '-c', '$_TARGETNAME configure -event gdb-detach { resume }',
        ], settings, { ...process.env, FROST_JTAG_SERIAL: settings.jtagSerial });
        await child.ready((log, group) => {
            if (/Examination failed/.test(log)) {
                throw new Error(`OpenOCD could not examine the target.\n${log.slice(-5000)}`);
            }
            return /Examination succeed/.test(log) &&
                /Listening on port 3333 for gdb connections/.test(log) && ownsTcpListener(GDB_PORT, group);
        },
        settings.startupTimeoutMs, signal);
        this.output('OpenOCD examined the target and owns the GDB listener.\n');
        return child;
    }

    async startHwServer(settings: FrostSettings, signal: AbortSignal): Promise<OwnedProcess> {
        signal.throwIfAborted();
        await requireFreePort(HW_PORT);
        const child = this.start(settings.hwServerPath, [
            '-s', `TCP:${HW_URL}`, '-p0', '-e', `set jtag-port-filter ${settings.jtagSerial}`,
        ], settings);
        await child.ready((_log, group) => ownsTcpListener(HW_PORT, group),
            settings.startupTimeoutMs, signal);
        this.output('Owned hw_server is listening on loopback.\n');
        return child;
    }

    async stop(child: OwnedProcess): Promise<void> {
        await child.stop(); this.owned.delete(child);
    }

    async cleanup(): Promise<void> {
        // Finish a native client before its cable server. Reverse creation order.
        const errors: unknown[] = [];
        for (const child of [...this.owned].reverse()) {
            try { await this.stop(child); } catch (error) { errors.push(error); }
        }
        if (errors.length) throw new Error(`Owned-process cleanup could not be confirmed: ${errors.map(String).join('; ')}`);
    }
}

export function loadArguments(settings: FrostSettings, buildOnly: boolean, buildConfigSha256?: string): string[] {
    return ['fpga/load_software/load_software.py', 'x3', settings.app,
        '--debug', ...(settings.memory === 'ddr' ? ['--ddr'] : []),
        ...(settings.coremarkMode ? [settings.coremarkMode === 'performance' ? '-v0' : '-v1'] : []),
        ...(buildOnly ? ['--build-only'] : ['--skip-build', '--hw-server-url', HW_URL,
            '--target-exact', settings.vivadoTarget, '--non-interactive',
            ...(buildConfigSha256 ? ['--expected-build-config-sha256', buildConfigSha256] : [])]),
        '--vivado-path', settings.vivadoPath];
}

export type DebugStartStrategy = 'main' | 'reset' | 'attach';
export interface DebugBuild {
    app: string;
    appDirectory: string;
    elf: string;
    effectiveMemory: 'bram' | 'ddr';
    startStrategy: DebugStartStrategy;
    buildConfigSha256: string;
}

/** Consume the loader's description of the actual ELF before acquiring JTAG. */
export function parseDebugBuild(output: string, settings: FrostSettings, buildDirectory: string): DebugBuild {
    const marker = 'FROST_DEBUG_BUILD=';
    const records = output.split(/\r?\n/).filter(line => line.startsWith(marker));
    if (records.length !== 1) throw new Error('The loader must report exactly one debug build. Update the repository loader before debugging.');
    let value: unknown;
    try { value = JSON.parse(records[0].slice(marker.length)); }
    catch { throw new Error('Invalid debug build description from the loader.'); }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid debug build description.');
    const result = value as Record<string, unknown>;
    const directory = path.join(settings.repoRoot, 'sw/apps', buildDirectory);
    if (!/^[a-z][a-z0-9_]*$/.test(buildDirectory) || result.app !== settings.app ||
        result.appDirectory !== directory || result.elf !== path.join(directory, 'sw.elf') ||
        typeof result.effectiveMemory !== 'string' || !['bram', 'ddr'].includes(result.effectiveMemory) ||
        typeof result.startStrategy !== 'string' || !['main', 'reset', 'attach'].includes(result.startStrategy) ||
        (result.effectiveMemory === 'ddr' && result.startStrategy !== 'attach') ||
        typeof result.buildConfigSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(result.buildConfigSha256)) {
        throw new Error('The debug build does not match the selected application or a supported startup strategy.');
    }
    return result as unknown as DebugBuild;
}

// An in-memory change check plus a symbol copy keeps this operation's ELF
// paired with its load, without a persistent manifest or recovery framework.
export async function imageDigests(directory: string): Promise<Map<string, string>> {
    const values = new Map<string, string>();
    for (const file of ['sw.elf', 'sw.txt', 'sw_ddr.txt', '.frost-build-config.bin']) {
        try {
            values.set(file, createHash('sha256').update(await fs.readFile(path.join(directory, file))).digest('hex'));
        } catch (error) {
            if (file !== 'sw_ddr.txt' || (error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
        }
    }
    return values;
}

export function assertSameImages(before: Map<string, string>, after: Map<string, string>): void {
    if (before.size !== after.size || [...before].some(([name, value]) => after.get(name) !== value)) {
        throw new Error('The app image changed during loading. Stop other builds of this app and load it again before debugging.');
    }
}
