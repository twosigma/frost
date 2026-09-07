// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0

// One disposable worker owns one native process group. IPC closure means the
// extension host died: cleanup must not depend on VS Code calling deactivate().
import { ChildProcess, spawn } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';

let child: ChildProcess | undefined;
let stopping = false;
let killTimer: NodeJS.Timeout | undefined;

function send(message: unknown): void {
    if (process.connected) process.send?.(message, () => {});
}

function signalGroup(signal: NodeJS.Signals): void {
    if (!child?.pid) return;
    try { process.kill(-child.pid, signal); }
    catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ESRCH') {
            send({ type: 'error', message: `Process cleanup failed: ${String(error)}` });
        }
    }
}

function stop(): void {
    if (stopping) return;
    stopping = true;
    if (!child) { process.exit(0); return; }
    signalGroup('SIGTERM');
    killTimer = setTimeout(() => signalGroup('SIGKILL'), 1500);
}

function groupReleased(): boolean {
    if (!child?.pid) return true;
    try { process.kill(-child.pid, 0); }
    catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ESRCH') return true;
        return false;
    }
    // Orphaned zombies can await PID 1 without retaining a cable or descriptor.
    // Do not confuse them with live descendants that ignored SIGTERM.
    for (const pid of readdirSync('/proc')) {
        if (!/^\d+$/.test(pid)) continue;
        try {
            const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
            const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
            if (Number(fields[2]) === child.pid && fields[0] !== 'Z') return false;
        } catch { /* Process exited during inspection. */ }
    }
    return true;
}

function finishWhenReleased(code: number | null, signal: NodeJS.Signals | null): void {
    if (!groupReleased()) {
        setTimeout(() => finishWhenReleased(code, signal), 50);
        return;
    }
    if (killTimer) clearTimeout(killTimer);
    send({ type: 'exit', code, signal });
    if (process.connected) process.disconnect();
}

process.on('disconnect', stop);
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
process.on('message', (message: {
    type: string; command?: string; args?: string[];
    cwd?: string; env?: NodeJS.ProcessEnv;
}) => {
    if (message.type === 'stop') { stop(); return; }
    if (message.type !== 'start' || child || stopping || !message.command) return;
    child = spawn(message.command, message.args ?? [], {
        cwd: message.cwd, env: message.env, detached: true,
        stdio: ['ignore', 'pipe', 'pipe'], shell: false,
    });
    child.once('spawn', () => send({ type: 'spawn', pid: child!.pid }));
    child.stdout!.on('data', data => send({ type: 'output', text: data.toString() }));
    child.stderr!.on('data', data => send({ type: 'output', text: data.toString() }));
    child.once('error', error => send({ type: 'error', message: error.message }));
    // If a launcher exits with descendants still holding its streams, clean
    // those descendants too. Success is reported only after the streams close.
    child.once('exit', stop);
    child.once('close', (code, signal) => {
        finishWhenReleased(code, signal);
    });
});
