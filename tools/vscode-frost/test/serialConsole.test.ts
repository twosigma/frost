// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import path from 'node:path';
import test, { TestContext } from 'node:test';
import type * as vscode from 'vscode';
import { bounded } from '../src/process';
import type { ProcessExit, ProcessOptions } from '../src/process';

function deferred<T>() {
    let resolve!: (value: T) => void;
    let reject!: (error: unknown) => void;
    const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
    void promise.catch(() => {});
    return { promise, resolve, reject };
}

async function eventually(check: () => boolean, message: string): Promise<void> {
    const deadline = Date.now() + 1500;
    while (Date.now() < deadline) {
        if (check()) return;
        await new Promise(resolve => setTimeout(resolve, 2));
    }
    assert.fail(message);
}

class Emitter<T> {
    private handlers = new Set<(value: T) => void>();
    readonly event = (handler: (value: T) => void) => {
        this.handlers.add(handler);
        return { dispose: () => { this.handlers.delete(handler); } };
    };
    fire(value: T): void { for (const handler of this.handlers) handler(value); }
    dispose(): void { this.handlers.clear(); }
}

interface Pty {
    onDidWrite(handler: (value: string) => void): { dispose(): void };
    open(): void;
    close(): void;
    handleInput(data: string): void;
}

function harness(t: TestContext) {
    const output: string[] = [];
    const terminals: Array<{ pty: Pty; text: string[]; disposed: boolean; shown: boolean[];
        show(preserveFocus: boolean): void; dispose(): void }> = [];
    const config: Record<string, unknown> = {
        'serial.autoOpen': true, 'serial.port': 'auto', 'serial.baudRate': 115200,
        startupTimeoutMs: 300, pythonPath: 'fixture-python', jtagSerial: 'FIXTURE',
    };
    const control = {
        autoReady: true,
        autoReconfigure: true,
        startupError: undefined as string | undefined,
        metadataGate: undefined as ReturnType<typeof deferred<void>> | undefined,
        metadataCalls: 0,
        metadataSignals: [] as AbortSignal[],
    };
    const children: FakeProcess[] = [];
    class FakeProcess {
        running = true;
        readonly completion = deferred<ProcessExit>();
        readonly exited = this.completion.promise;
        readonly writes: string[] = [];
        stopCalls = 0;
        stopError?: Error;
        stopGate?: ReturnType<typeof deferred<void>>;
        constructor(readonly options: ProcessOptions) {
            children.push(this);
            queueMicrotask(() => {
                if (control.startupError) this.event({ type: 'error', message: control.startupError });
                else if (control.autoReady) this.event({ type: 'ready', port: '/dev/tty-fixture', baud: 115200 });
            });
        }
        event(message: unknown): void { this.chunk(JSON.stringify(message) + '\n'); }
        chunk(text: string): void { this.options.output?.(text); }
        finish(result: ProcessExit): void { this.running = false; this.completion.resolve(result); }
        async ready(predicate: (log: string, pid: number) => boolean | Promise<boolean>, timeout: number, signal?: AbortSignal): Promise<void> {
            try {
                const deadline = Date.now() + timeout;
                while (this.running) {
                    signal?.throwIfAborted();
                    if (await predicate('', 123)) return;
                    if (Date.now() >= deadline) throw new Error('Fixture readiness timeout');
                    await new Promise(resolve => setTimeout(resolve, 1));
                }
                throw new Error('Fixture helper exited before readiness');
            } catch (error) { await this.stop(); throw error; }
        }
        async write(data: string): Promise<void> {
            if (!this.running) throw new Error('Fixture helper is closed');
            this.writes.push(data);
            if (JSON.parse(data).type === 'reconfigure' && control.autoReconfigure) {
                queueMicrotask(() => this.event({ type: 'reconfigured' }));
            }
        }
        async stop(): Promise<void> {
            this.stopCalls++;
            if (this.stopError) throw this.stopError;
            if (this.stopGate) await this.stopGate.promise;
            this.finish({ code: 0 });
        }
    }

    const mockedVscode = {
        EventEmitter: Emitter,
        ThemeIcon: class { constructor(readonly id: string) {} },
        workspace: { getConfiguration: () => ({ get: (key: string, fallback: unknown) => config[key] ?? fallback }) },
        window: {
            createTerminal: (options: { name: string; pty: Pty; isTransient: boolean }) => {
                assert.equal(options.name, 'FROST Serial');
                assert.equal(options.isTransient, true);
                let opened = false;
                const terminal = {
                    pty: options.pty, text: [] as string[], disposed: false, shown: [] as boolean[],
                    show(preserveFocus: boolean) {
                        this.shown.push(preserveFocus);
                        if (!opened) { opened = true; this.pty.open(); }
                    },
                    dispose() { this.disposed = true; this.pty.close(); },
                };
                options.pty.onDidWrite(text => terminal.text.push(text));
                terminals.push(terminal);
                return terminal;
            },
        },
    };
    const metadata = async (_settings: unknown, signal: AbortSignal) => {
        control.metadataCalls++;
        control.metadataSignals.push(signal);
        if (control.metadataGate) await bounded(control.metadataGate.promise, 1000, signal);
        signal.throwIfAborted();
        return { apps: ['hello_world'], defaultSerial: '/dev/tty-fixture',
            coremarkProApps: [], ddrApps: [], hasDdr: true };
    };
    const Module = require('node:module') as {
        _load(request: string, parent: NodeModule | undefined, isMain: boolean): unknown;
    };
    const originalLoad = Module._load;
    const serialPath = require.resolve('../src/serialConsole');
    delete require.cache[serialPath];
    let imported: typeof import('../src/serialConsole');
    try {
        Module._load = function (request, parent, isMain) {
            if (request === 'vscode') return mockedVscode;
            if (parent?.filename === serialPath && request === './process') return { OwnedProcess: FakeProcess, bounded };
            if (parent?.filename === serialPath && request === './plainLoad') return { readRepositoryMetadata: metadata };
            return originalLoad.call(this, request, parent, isMain);
        };
        imported = require(serialPath);
    } finally { Module._load = originalLoad; }
    const console = new imported.SerialConsole({
        asAbsolutePath: (file: string) => path.join('/fixture-extension', file),
    } as vscode.ExtensionContext, text => output.push(text));
    const folder = { name: 'fixture', index: 0, uri: { fsPath: '/fixture-repo' } } as vscode.WorkspaceFolder;
    t.after(async () => {
        control.metadataGate?.resolve();
        for (const child of children) child.stopGate?.resolve();
        await console.dispose().catch(() => {});
        delete require.cache[serialPath];
    });
    return { console, folder, config, control, children, terminals, output };
}

test('RX preserves fragmented NDJSON and UTF-8 split across base64 messages', async t => {
    const h = harness(t);
    await h.console.show(h.folder);
    const terminal = h.terminals[0];
    terminal.text.length = 0;
    const bytes = Buffer.from('A€🙂Z\r\n', 'utf8');
    const chunks = [bytes.subarray(0, 2), bytes.subarray(2, 4), bytes.subarray(4, 7), bytes.subarray(7)];
    const wire = chunks.map(data => JSON.stringify({ type: 'data', data: data.toString('base64') }) + '\n').join('');
    for (let offset = 0; offset < wire.length; offset += 7) h.children[0].chunk(wire.slice(offset, offset + 7));
    assert.equal(terminal.text.join(''), bytes.toString('utf8'));
    assert.ok(!terminal.text.join('').includes('\uFFFD'));
});

test('TX preserves control/UTF-8 bytes across chunks and does not locally echo', async t => {
    const h = harness(t);
    await h.console.show(h.folder);
    const terminal = h.terminals[0];
    const before = terminal.text.join('');
    const input = 'a'.repeat(4095) + '€\r\n\0\x1b[A';
    terminal.pty.handleInput(input);
    await eventually(() => h.children[0].writes.length === 2, 'Expected two bounded TX messages');
    const sent = Buffer.concat(h.children[0].writes.map(line => {
        const message = JSON.parse(line);
        assert.equal(message.type, 'write');
        return Buffer.from(message.data, 'base64');
    }));
    assert.deepEqual(sent, Buffer.from(input, 'utf8'));
    assert.equal(terminal.text.join(''), before);
});

test('terminal close and Ctrl+] both stop the owned connection without transmitting escape', async t => {
    for (const action of ['terminal', 'escape'] as const) await t.test(action, async childTest => {
        const h = harness(childTest);
        await h.console.show(h.folder);
        if (action === 'terminal') h.terminals[0].pty.close();
        else h.terminals[0].pty.handleInput('\x1d');
        await eventually(() => !h.children[0].running, 'Serial child must stop when terminal closes');
        assert.equal(h.children[0].writes.length, 0);
        if (action === 'escape') assert.equal(h.terminals[0].disposed, true);
    });
});

test('closing during metadata query aborts it before any serial process can open', async t => {
    const h = harness(t);
    h.control.metadataGate = deferred<void>();
    const showing = h.console.show(h.folder);
    const rejected = assert.rejects(showing, /closed/);
    await h.console.close();
    await rejected;
    assert.equal(h.control.metadataSignals[0].aborted, true);
    assert.equal(h.children.length, 0);
    assert.equal(h.terminals[0].disposed, true);
});

test('operation cancellation during readiness stops the serial helper', async t => {
    const h = harness(t);
    h.control.autoReady = false;
    const abort = new AbortController();
    const showing = h.console.show(h.folder, true, abort.signal);
    const rejected = assert.rejects(showing, /cancelled by operation/);
    await eventually(() => h.children.length === 1, 'Serial helper should be waiting for readiness');
    abort.abort(new Error('cancelled by operation'));
    await rejected;
    assert.equal(h.children[0].running, false);
    assert.deepEqual(h.terminals[0].shown, [true]);
});

test('auto-open preference and external serial ownership do not fail the board flow', async t => {
    const h = harness(t);
    h.config['serial.autoOpen'] = false;
    await h.console.autoOpen(h.folder);
    assert.equal(h.terminals.length, 0);
    assert.equal(h.control.metadataCalls, 0);
    h.config['serial.autoOpen'] = true;
    h.control.startupError = 'Serial device is owned by external PID 4321';
    await assert.doesNotReject(h.console.autoOpen(h.folder));
    assert.equal(h.children[0].running, false);
    assert.ok(h.output.join('').includes('external PID 4321'));
    assert.ok(h.output.join('').includes('Could not connect'));
});

test('after-JTAG reconfiguration touches only the owned ready connection and coalesces calls', async t => {
    const h = harness(t);
    await h.console.afterJtag();
    assert.equal(h.children.length, 0);
    assert.equal(h.control.metadataCalls, 0);
    await h.console.show(h.folder);
    h.control.autoReconfigure = false;
    const first = h.console.afterJtag();
    const second = h.console.afterJtag();
    assert.equal(h.children[0].writes.length, 1);
    assert.deepEqual(JSON.parse(h.children[0].writes[0]), { type: 'reconfigure' });
    h.children[0].event({ type: 'reconfigured' });
    await Promise.all([first, second]);
    assert.equal(h.children.length, 1);
    h.control.autoReconfigure = true;
    await h.console.afterJtag();
    assert.equal(h.children[0].writes.length, 2);
    await h.console.close();
    await h.console.afterJtag();
    assert.equal(h.children[0].writes.length, 2);
});

test('unexpected worker death blocks reopen until native cleanup is confirmed', async t => {
    const h = harness(t);
    await h.console.show(h.folder);
    h.children[0].stopError = new Error('Process owner exited before confirming cleanup');
    h.children[0].finish({ code: null, error: 'Process owner exited before confirming cleanup' });
    await assert.rejects(h.console.show(h.folder), /cleanup|confirming/);
    await assert.rejects(h.console.show(h.folder), /Serial cleanup is unconfirmed/);
    assert.equal(h.children.length, 1);
});

test('reopen waits for old descriptor cleanup and concurrent reopen requests share one helper', async t => {
    const h = harness(t);
    await h.console.show(h.folder);
    const child = h.children[0];
    child.stopGate = deferred<void>();
    child.finish({ code: 0 });
    const first = h.console.show(h.folder);
    const second = h.console.show(h.folder);
    await eventually(() => child.stopCalls > 0, 'Old connection cleanup should begin');
    assert.equal(h.children.length, 1);
    child.stopGate.resolve();
    await Promise.all([first, second]);
    assert.equal(h.children.length, 2);
    assert.equal(h.children[1].running, true);
});

test('invalid helper protocol after readiness closes the connection and reports the error', async t => {
    const h = harness(t);
    await h.console.show(h.folder);
    h.children[0].chunk('{invalid JSON}\n');
    await eventually(() => !h.children[0].running, 'Protocol failure must close the helper');
    assert.ok(h.output.join('').includes('Invalid serial helper response'));
    h.terminals[0].pty.handleInput('must not send');
    assert.equal(h.children[0].writes.length, 0);
});

test('invalid base64 is rejected rather than silently dropping serial bytes', async t => {
    const h = harness(t);
    await h.console.show(h.folder);
    h.children[0].event({ type: 'data', data: 'not base64!' });
    await eventually(() => !h.children[0].running, 'Invalid serial payload must close the helper');
    assert.ok(h.output.join('').includes('Invalid serial helper response'));
});
