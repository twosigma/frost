// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import { ChildProcess, fork } from 'node:child_process';
import { promises as fs } from 'node:fs';
import net from 'node:net';
import path from 'node:path';

export interface ProcessOptions {
    command: string;
    args: string[];
    cwd: string;
    env?: NodeJS.ProcessEnv;
    output?: (text: string) => void;
}

export interface ProcessExit { code: number | null; signal?: string; error?: string }

export class OwnedProcess {
    readonly exited: Promise<ProcessExit>;
    readonly spawned: Promise<number>;
    private worker: ChildProcess;
    private finish!: (result: ProcessExit) => void;
    private markSpawn!: (pid: number) => void;
    private failSpawn!: (error: Error) => void;
    private result?: ProcessExit;
    private spawnError?: string;
    private cleanupConfirmed = false;
    private tail = '';
    private group?: number;
    private stopping?: Promise<void>;

    constructor(readonly options: ProcessOptions) {
        this.exited = new Promise(resolve => { this.finish = resolve; });
        this.spawned = new Promise((resolve, reject) => {
            this.markSpawn = resolve; this.failSpawn = reject;
        });
        // Handle immediate ENOENT even if the caller is still arranging waits.
        void this.spawned.catch(() => {});
        this.worker = fork(path.join(__dirname, 'processWorker.js'), [], {
            execArgv: [], env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
            stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
        });
        this.worker.stderr?.on('data', data => this.append(data.toString()));
        this.worker.on('message', (message: {
            type: string; text?: string; message?: string; pid?: number;
            code?: number | null; signal?: string;
        }) => {
            if (message.type === 'spawn') {
                this.group = message.pid; this.markSpawn(message.pid!);
            } else if (message.type === 'output') this.append(message.text ?? '');
            else if (message.type === 'error') {
                this.spawnError = message.message;
                this.failSpawn(new Error(message.message));
            } else if (message.type === 'exit') {
                this.cleanupConfirmed = true;
                this.complete({ code: message.code ?? null, signal: message.signal, error: this.spawnError });
            }
        });
        this.worker.once('error', error => {
            this.failSpawn(error); this.complete({ code: null, error: error.message });
        });
        this.worker.once('exit', (code, signal) => {
            if (!this.result) this.complete({ code, signal: signal ?? undefined,
                error: this.spawnError ?? 'Process owner exited before confirming cleanup' });
        });
        this.worker.send({ type: 'start', command: options.command,
            args: options.args, cwd: options.cwd, env: options.env ?? process.env });
    }

    private append(text: string): void {
        this.tail = (this.tail + text).slice(-65536);
        this.options.output?.(text);
    }

    private complete(result: ProcessExit): void {
        if (this.result) return;
        this.result = result;
        if (!this.group) this.failSpawn(new Error(result.error ?? 'Process did not start'));
        this.finish(result);
    }

    get running(): boolean { return !this.result; }
    get pid(): number | undefined { return this.group; }
    get log(): string { return this.tail; }

    async ready(predicate: (log: string, group: number) => boolean | Promise<boolean>,
        timeoutMs: number, signal?: AbortSignal): Promise<void> {
        try {
            const start = Date.now();
            while (true) {
                signal?.throwIfAborted();
                if (this.result) throw new Error(this.failure('exited before readiness'));
                if (Date.now() - start >= timeoutMs) throw new Error(this.failure('startup timed out'));
                if (this.group && await bounded(Promise.resolve(predicate(this.tail, this.group)),
                    Math.max(1, timeoutMs - (Date.now() - start)), signal)) {
                    // The predicate can yield while the process exits.
                    signal?.throwIfAborted();
                    if (Date.now() - start >= timeoutMs) throw new Error(this.failure('startup timed out'));
                    if (this.result) throw new Error(this.failure('exited during readiness'));
                    return;
                }
                await delay(40, signal);
            }
        } catch (error) { await this.stop(); throw error; }
    }

    async wait(timeoutMs: number, signal?: AbortSignal): Promise<void> {
        try {
            const result = await bounded(this.exited, timeoutMs, signal);
            if (result.code !== 0 || result.error) throw new Error(this.failure('failed'));
        } catch (error) { await this.stop(); throw error; }
    }

    stop(): Promise<void> {
        return this.stopping ??= (async () => {
            if (this.result) {
                if (!this.cleanupConfirmed) throw new Error(this.result.error ?? 'Owned-process cleanup is unconfirmed');
                return;
            }
            if (this.worker.connected) this.worker.send({ type: 'stop' }, () => {});
            // Never kill an unrelated PID or resolve while cleanup is uncertain.
            await bounded(this.exited, 6000);
            if (!this.cleanupConfirmed) throw new Error('Owned-process cleanup is unconfirmed');
        })();
    }

    private failure(reason: string): string {
        return `${path.basename(this.options.command)} ${reason}${this.spawnError ? `: ${this.spawnError}` : ''}\n${this.tail.slice(-5000)}`;
    }
}

export function bounded<T>(promise: PromiseLike<T>, timeoutMs: number,
    signal?: AbortSignal): Promise<T> {
    return new Promise((resolve, reject) => {
        const finish = (fn: () => void) => {
            clearTimeout(timer); signal?.removeEventListener('abort', aborted); fn();
        };
        const aborted = () => finish(() => reject(signal?.reason ?? new Error('Cancelled')));
        const timer = setTimeout(() => finish(() => reject(new Error(`Timed out after ${timeoutMs} ms`))), timeoutMs);
        if (signal?.aborted) { aborted(); return; }
        signal?.addEventListener('abort', aborted, { once: true });
        Promise.resolve(promise).then(value => finish(() => resolve(value)),
            error => finish(() => reject(error)));
    });
}

export function delay(ms: number, signal?: AbortSignal): Promise<void> {
    return bounded(new Promise(resolve => setTimeout(resolve, ms)), ms + 1000, signal);
}

export async function requireFreePort(port: number): Promise<void> {
    await new Promise<void>((resolve, reject) => {
        const server = net.createServer();
        server.once('error', () => reject(new Error(`Local port ${port} is in use. Its owner was left untouched.`)));
        server.listen(port, '127.0.0.1', () => server.close(error => error ? reject(error) : resolve()));
    });
}

// Read-only ownership check: a random listener cannot satisfy readiness. This
// also handles Vivado's shell launcher with the real server in a child process.
export async function ownsTcpListener(port: number, group: number): Promise<boolean> {
    const inodes = new Set<string>();
    const table = await fs.readFile('/proc/net/tcp', 'utf8');
    const address = `0100007F:${port.toString(16).toUpperCase().padStart(4, '0')}`;
    for (const row of table.trim().split('\n').slice(1)) {
        const fields = row.trim().split(/\s+/);
        if (fields[1] === address && fields[3] === '0A') inodes.add(fields[9]);
    }
    if (!inodes.size) return false;
    for (const pid of await fs.readdir('/proc')) {
        if (!/^\d+$/.test(pid)) continue;
        try {
            const stat = await fs.readFile(`/proc/${pid}/stat`, 'utf8');
            const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
            if (Number(fields[2]) !== group) continue;
            for (const fd of await fs.readdir(`/proc/${pid}/fd`)) {
                try {
                    const link = await fs.readlink(`/proc/${pid}/fd/${fd}`);
                    if (inodes.has(/^socket:\[(\d+)\]$/.exec(link)?.[1] ?? '')) return true;
                } catch { /* Descriptor closed during the inspection. */ }
            }
        } catch { /* Process exited, or belongs to another user. */ }
    }
    return false;
}
