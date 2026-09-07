// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { TestContext } from 'node:test';
import type { FrostSettings } from '../src/settings';
import { assertSameImages, imageDigests, imageResetDelayMs, loadArguments } from '../src/hardware';
import { bounded } from '../src/process';
import * as processTools from '../src/process';

type Config = Record<string, unknown>;
interface Session {
    id: string;
    configuration: Config;
    customRequest(command: string, args?: Config): Promise<unknown>;
}
interface Tracker {
    onDidSendMessage?(message: Config): void;
    onError?(error: Error): void;
    onExit?(): void;
}
interface Disposable { dispose(): void }

function deferred<T>() {
    let resolve!: (value: T) => void;
    let reject!: (error: unknown) => void;
    const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
    void promise.catch(() => {});
    return { promise, resolve, reject };
}

function listeners<T>() {
    const values = new Set<(value: T) => void>();
    return {
        event(handler: (value: T) => void): Disposable {
            values.add(handler);
            return { dispose: () => { values.delete(handler); } };
        },
        fire(value: T): void { for (const handler of values) handler(value); },
    };
}

async function eventually(check: () => boolean | Promise<boolean>, message: string): Promise<void> {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
        if (await check()) return;
        await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert.fail(message);
}

class FakeProcess {
    running = true;
    readonly completion = deferred<{ code: number }>();
    readonly exited = this.completion.promise;
    constructor(readonly name: string,
        private readonly waitForExit?: (timeout: number, signal?: AbortSignal) => Promise<void>) {}
    async wait(timeout: number, signal?: AbortSignal): Promise<void> {
        await this.waitForExit?.(timeout, signal);
    }
}

async function harness(t: TestContext) {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'frost-controller-test-'));
    const app = path.join(root, 'sw/apps/hello_world');
    await fs.mkdir(app, { recursive: true });
    await Promise.all([
        fs.writeFile(path.join(app, 'sw.elf'), 'fixture ELF and symbols'),
        fs.writeFile(path.join(app, 'sw.txt'), '00000013\n'),
        fs.writeFile(path.join(app, 'sw_ddr.txt'), '00000013\n'),
        fs.writeFile(path.join(root, 'design.bit'), 'fixture bitstream'),
    ]);
    const settings: FrostSettings = {
        repoRoot: root, pythonPath: 'fixture-python', openocdPath: 'fixture-openocd',
        gdbPath: 'fixture-gdb', vivadoPath: 'fixture-vivado', hwServerPath: 'fixture-hw-server',
        jtagSerial: 'FIXTURE', vivadoTarget: '127.0.0.1:3121/xilinx_tcf/Xilinx/FIXTURE',
        app: 'hello_world', memory: 'bram', cpuClockHz: 300000000,
        bitstream: path.join(root, 'design.bit'), elf: path.join(app, 'sw.elf'),
        startupTimeoutMs: 100, toolTimeoutMs: 1000, registerDescription: 'default',
    };
    const calls: string[] = [];
    const errors: string[] = [];
    const warnings: string[] = [];
    const output: string[] = [];
    const commands = new Map<string, () => Promise<void>>();
    const starts = listeners<Session>();
    const ends = listeners<Session>();
    const cancel = listeners<void>();
    const owned = new Set<FakeProcess>();
    const launches: Config[] = [];
    const delays: number[] = [];
    const sessions: Session[] = [];
    const stoppedByVscode: Session[] = [];
    const trackers = new Map<string, Tracker>();
    let trackerFactory: { createDebugAdapterTracker(session: Session): Tracker | undefined };
    let provider: {
        resolveDebugConfigurationWithSubstitutedVariables(folder: unknown, config: Config): Config | null;
    };
    const control = {
        autoTerminate: true,
        openOcdReady: undefined as ReturnType<typeof deferred<void>> | undefined,
        stopGate: undefined as ReturnType<typeof deferred<void>> | undefined,
        imageResetWait: undefined as ReturnType<typeof deferred<void>> | undefined,
        loadCompletion: undefined as ReturnType<typeof deferred<void>> | undefined,
        loaderStopGate: undefined as ReturnType<typeof deferred<void>> | undefined,
        loadError: undefined as Error | undefined,
        readinessError: undefined as Error | undefined,
        launch: undefined as ((config: Config) => Promise<boolean>) | undefined,
    };

    class FakeHardware {
        async preflight(): Promise<void> { calls.push('hardware:preflight'); }
        async startOpenOcd(_settings: FrostSettings, signal: AbortSignal): Promise<FakeProcess> {
            const daemon = new FakeProcess('openocd');
            owned.add(daemon);
            calls.push('openocd:start');
            if (control.openOcdReady) await bounded(control.openOcdReady.promise, 3000, signal);
            if (control.readinessError) throw control.readinessError;
            calls.push('openocd:ready');
            return daemon;
        }
        async startHwServer(): Promise<FakeProcess> {
            const server = new FakeProcess('hw_server');
            owned.add(server);
            calls.push('hw_server:start');
            return server;
        }
        async run(_command: string, args: string[]): Promise<void> {
            calls.push(args[0].includes('program_bitstream') ? 'tool:program'
                : args.includes('--build-only') ? 'tool:build' : 'tool:load');
        }
        start(_command: string, args: string[]): FakeProcess {
            assert.ok(args[0].includes('load_software') && args.includes('--skip-build'),
                'This fixture starts only the native software loader');
            calls.push('tool:load');
            const loader = new FakeProcess('loader', async (timeout, signal) => {
                calls.push('loader:wait');
                if (control.loadCompletion) await bounded(control.loadCompletion.promise, timeout, signal);
                signal?.throwIfAborted();
                if (control.loadError) throw control.loadError;
                calls.push('loader:wait-completed');
            });
            owned.add(loader);
            return loader;
        }
        async stop(child: FakeProcess): Promise<void> {
            if (!owned.has(child)) return;
            calls.push(`${child.name}:stop-requested`);
            if (child.name === 'openocd' && control.stopGate) await control.stopGate.promise;
            if (child.name === 'loader' && control.loaderStopGate) await control.loaderStopGate.promise;
            child.running = false;
            owned.delete(child);
            child.completion.resolve({ code: 0 });
            calls.push(`${child.name}:stopped`);
        }
        async cleanup(): Promise<void> {
            calls.push('hardware:cleanup');
            for (const child of [...owned].reverse()) await this.stop(child);
        }
    }

    function end(session: Session): void {
        calls.push(`session:end:${session.id}`);
        ends.fire(session);
    }

    function makeSession(config: Config): Session {
        const session: Session = {
            id: `debug-${sessions.length + 1}`,
            configuration: config,
            async customRequest(command, args) {
                calls.push(`session:${command}:${session.id}`);
                if (command === 'disconnect') {
                    assert.equal(args?.terminateDebuggee, false,
                        'FROST must request detach rather than terminating the target');
                    if (control.autoTerminate) queueMicrotask(() => end(session));
                }
                return {};
            },
        };
        sessions.push(session);
        return session;
    }

    function start(config: Config, stopped = true): Session {
        const session = makeSession(config);
        starts.fire(session);
        const tracker = trackerFactory.createDebugAdapterTracker(session);
        if (tracker) trackers.set(session.id, tracker);
        if (stopped) tracker?.onDidSendMessage?.({ type: 'event', event: 'stopped' });
        return session;
    }

    const folder = { name: 'FROST fixture', index: 0, uri: { fsPath: root } };
    const dispose = (): Disposable => ({ dispose() {} });
    const vscode = {
        ProgressLocation: { Notification: 15 },
        Uri: { file: (file: string) => ({ fsPath: file }) },
        workspace: { isTrusted: true, workspaceFolders: [folder] },
        extensions: { getExtension: () => ({ activate: async () => {} }) },
        commands: {
            registerCommand(name: string, handler: () => Promise<void>) {
                commands.set(name, handler);
                return { dispose: () => { commands.delete(name); } };
            },
        },
        window: {
            createOutputChannel: () => ({
                append: (text: string) => output.push(text),
                appendLine: (text: string) => output.push(text), show() {}, dispose() {},
            }),
            showErrorMessage: async (message: string) => { errors.push(message); return undefined; },
            showWarningMessage: async (message: string) => { warnings.push(message); return undefined; },
            withProgress: async (_options: unknown,
                task: (progress: { report(value: unknown): void }, token: unknown) => Promise<void>) =>
                task({ report() {} }, { onCancellationRequested: cancel.event }),
        },
        debug: {
            onDidStartDebugSession: starts.event,
            onDidTerminateDebugSession: ends.event,
            registerDebugConfigurationProvider: (_type: string, value: typeof provider) => {
                provider = value; return dispose();
            },
            registerDebugAdapterTrackerFactory: (_type: string, value: typeof trackerFactory) => {
                trackerFactory = value; return dispose();
            },
            startDebugging: async (_folder: unknown, config: Config) => {
                calls.push('debug:start'); launches.push(config);
                if (control.launch) return control.launch(config);
                start(config);
                return true;
            },
            stopDebugging: async (session: Session) => {
                calls.push(`debug:stop:${session.id}`);
                stoppedByVscode.push(session);
                end(session);
            },
        },
    };

    // Isolate the VS Code host boundary, not the controller implementation.
    // Every test exercises activate's real commands, provider and event handlers.
    const Module = require('node:module') as {
        _load(request: string, parent: NodeModule | undefined, isMain: boolean): unknown;
    };
    const originalLoad = Module._load;
    const extensionPath = require.resolve('../src/extension');
    delete require.cache[extensionPath];
    let extension: typeof import('../src/extension');
    try {
        Module._load = function (request, parent, isMain) {
            if (request === 'vscode') return vscode;
            if (parent?.filename === extensionPath && request === './settings') {
                return { getSettings: () => settings, configureTarget: async () => true };
            }
            if (parent?.filename === extensionPath && request === './hardware') {
                return { Hardware: FakeHardware, HW_URL: '127.0.0.1:3121',
                    assertSameImages, imageDigests, imageResetDelayMs, loadArguments };
            }
            if (parent?.filename === extensionPath && request === './process') {
                return { ...processTools, delay: async (milliseconds: number, signal?: AbortSignal) => {
                    delays.push(milliseconds);
                    calls.push('image-reset:waiting');
                    signal?.throwIfAborted();
                    if (control.imageResetWait) await bounded(control.imageResetWait.promise, 3000, signal);
                    calls.push('image-reset:released');
                } };
            }
            return originalLoad.call(this, request, parent, isMain);
        };
        extension = require(extensionPath);
    } finally { Module._load = originalLoad; }
    const subscriptions: Disposable[] = [];
    extension.activate({
        subscriptions,
        globalStorageUri: { fsPath: path.join(root, 'extension-storage') },
        asAbsolutePath: (file: string) => path.resolve(__dirname, '../../', file),
    } as unknown as Parameters<typeof extension.activate>[0]);
    t.after(async () => {
        control.openOcdReady?.resolve();
        control.stopGate?.resolve();
        control.imageResetWait?.resolve();
        control.loadCompletion?.resolve();
        control.loaderStopGate?.resolve();
        control.autoTerminate = true;
        for (const session of sessions) end(session);
        await extension.deactivate();
        for (const item of subscriptions) item.dispose();
        delete require.cache[extensionPath];
        await fs.rm(root, { recursive: true, force: true });
    });
    return {
        root, settings, calls, errors, warnings, output, owned, launches, delays, sessions, stoppedByVscode,
        trackers, control, start, end, makeSession,
        command: async (name: string) => {
            const handler = commands.get(`frost.${name}`);
            assert.ok(handler, `Public command frost.${name} must exist`);
            await handler();
        },
        provider: (config: Config) => provider.resolveDebugConfigurationWithSubstitutedVariables(folder, config),
        startEvent: starts.fire,
        cancel: () => cancel.fire(),
    };
}

async function noSymbolCopies(root: string): Promise<void> {
    const directory = path.join(root, 'extension-storage/symbols');
    const files = await fs.readdir(directory).catch(() => []);
    assert.deepEqual(files, [], 'Failed/finished sessions must remove their private ELF copies');
}

test('OpenOCD readiness failure never starts cppdbg and cleans owned resources', async t => {
    const h = await harness(t);
    h.control.readinessError = new Error('fixture target examination failed');
    await h.command('attach');
    assert.equal(h.launches.length, 0);
    assert.equal(h.owned.size, 0);
    assert.ok(h.calls.includes('openocd:stopped'));
    assert.match(h.errors.join('\n'), /target examination failed/);
    await noSymbolCopies(h.root);
});

for (const failure of ['false', 'reject', 'no-start', 'no-stop', 'adapter-error'] as const) {
    test(`cppdbg ${failure} startup failure releases OpenOCD and symbol copies`, async t => {
        const h = await harness(t);
        h.control.launch = async config => {
            if (failure === 'false') return false;
            if (failure === 'reject') throw new Error('fixture cppdbg rejection');
            if (failure !== 'no-start') {
                const session = h.start(config, false);
                if (failure === 'adapter-error') h.trackers.get(session.id)?.onDidSendMessage?.({
                    type: 'response', command: 'launch', success: false, message: 'fixture MI launch failure',
                });
            }
            return true;
        };
        await h.command('attach');
        assert.equal(h.launches.length, 1);
        assert.equal(h.owned.size, 0);
        assert.ok(h.calls.includes('openocd:stopped'));
        assert.ok(h.errors.length > 0);
        await noSymbolCopies(h.root);
        assert.equal(await fs.readFile(h.settings.elf, 'utf8'), 'fixture ELF and symbols');
        assert.equal(h.provider(h.launches[0]), null, 'A failed launch token must not become valid later');
    });
}

test('a never-settling VS Code launch times out, releases OpenOCD, and blocks a retry', async t => {
    const h = await harness(t);
    h.control.launch = () => new Promise<boolean>(() => {});
    await h.command('attach');
    assert.equal(h.owned.size, 0);
    assert.equal(h.launches.length, 1);
    await h.command('attach');
    assert.equal(h.launches.length, 1, 'A pending old launch must not race a new session');
    assert.match(h.errors.join('\n'), /still pending/);
    const late = h.makeSession(h.launches[0]);
    h.startEvent(late);
    assert.ok(h.stoppedByVscode.includes(late), 'A timed-out late session must be stopped');
    await noSymbolCopies(h.root);
});

test('unrelated debug-session events leave the managed session and its server running', async t => {
    const h = await harness(t);
    await h.command('attach');
    const daemon = [...h.owned][0];
    const unrelated = h.makeSession({ type: 'cppdbg', request: 'attach', name: 'unrelated' });
    h.startEvent(unrelated);
    h.end(unrelated);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(daemon.running, true);
    assert.equal(h.owned.size, 1);
    assert.equal(h.stoppedByVscode.length, 0);
    assert.equal(h.provider(unrelated.configuration), unrelated.configuration);
    await h.command('disconnect');
    assert.equal(daemon.running, false);
});

test('a second command while target startup is pending cannot start another operation', async t => {
    const h = await harness(t);
    h.control.openOcdReady = deferred<void>();
    const first = h.command('attach');
    await eventually(() => h.calls.includes('openocd:start'), 'OpenOCD startup was not reached');
    await h.command('programBitstream');
    assert.equal(h.warnings.length, 1);
    assert.equal(h.calls.filter(call => call === 'hardware:preflight').length, 1);
    assert.equal(h.calls.includes('hw_server:start'), false);
    h.control.openOcdReady.resolve();
    await first;
    assert.equal(h.launches.length, 1);
});

test('cancelling preparation never starts a debugger and releases the pending server', async t => {
    const h = await harness(t);
    h.control.openOcdReady = deferred<void>();
    const operation = h.command('attach');
    await eventually(() => h.calls.includes('openocd:start'), 'OpenOCD startup was not reached');
    h.cancel();
    await operation;
    assert.equal(h.launches.length, 0);
    assert.equal(h.owned.size, 0);
    assert.match(h.errors.join('\n'), /cancelled/);
});

for (const operation of ['programBitstream', 'loadAndDebug'] as const) {
    test(`${operation} waits for detach termination and owned OpenOCD cleanup`, async t => {
        const h = await harness(t);
        await h.command('attach');
        const old = h.sessions[0];
        h.control.autoTerminate = false;
        h.control.stopGate = deferred<void>();
        const next = h.command(operation);
        await eventually(() => h.calls.includes(`session:disconnect:${old.id}`),
            'Replacement operation did not request detach');
        assert.equal(h.calls.includes('openocd:stop-requested'), false);
        assert.equal(h.calls.includes('hw_server:start'), false);
        assert.equal(h.calls.includes('tool:build'), false);
        h.end(old);
        await eventually(() => h.calls.includes('openocd:stop-requested'),
            'OpenOCD cleanup was not requested after session termination');
        assert.equal(h.calls.includes('hw_server:start'), false,
            'Cable acquisition must wait for actual owned-server cleanup');
        assert.equal(h.calls.includes('tool:build'), false);
        h.control.stopGate.resolve();
        h.control.autoTerminate = true;
        await next;
        const cleanup = h.calls.indexOf('openocd:stopped');
        assert.ok(cleanup >= 0 && cleanup < h.calls.indexOf('hw_server:start'));
        if (operation === 'loadAndDebug') assert.ok(cleanup < h.calls.indexOf('tool:build'));
        else assert.ok(h.calls.indexOf('tool:program') > cleanup);
        assert.equal(h.errors.length, 0);
    });
}

test('image-reset hold times cover the supported 150 MHz and 300 MHz board clocks', () => {
    // Contract from xilinx_frost_subsystem.sv: a 27-bit inactivity counter on
    // CPU/4, plus the extension's 250 ms reset-synchronization margin.
    assert.equal(imageResetDelayMs(150000000), 3830);
    assert.equal(imageResetDelayMs(300000000), 2040);
    for (const invalid of [0, -150000000, Number.NaN, 1]) {
        assert.throws(() => imageResetDelayMs(invalid), /supported image-reset wait/);
    }
});

for (const memory of ['bram', 'ddr'] as const) {
    test(`${memory} load holds the cable until image-reset release before starting OpenOCD`, async t => {
        const h = await harness(t);
        h.settings.memory = memory;
        h.settings.cpuClockHz = 150000000;
        h.control.imageResetWait = deferred<void>();
        const loading = h.command('loadAndDebug');
        await eventually(() => h.calls.includes('image-reset:waiting'),
            'Software load did not reach its image-reset wait');
        assert.deepEqual(h.delays, [3830]);
        assert.ok(h.calls.indexOf('tool:load') < h.calls.indexOf('image-reset:waiting'));
        assert.ok(h.calls.indexOf('loader:stopped') < h.calls.indexOf('image-reset:waiting'));
        assert.equal(h.calls.includes('hw_server:stop-requested'), false,
            'The loader cable owner must remain alive through the reset interval');
        assert.equal(h.calls.includes('openocd:start'), false,
            'DMI requests must not reach a debug module still held in image reset');
        assert.equal(h.launches.length, 0);
        assert.deepEqual([...h.owned].map(child => child.name), ['hw_server']);
        h.control.imageResetWait.resolve();
        await loading;
        assert.ok(h.calls.indexOf('image-reset:released') < h.calls.indexOf('hw_server:stopped'));
        assert.ok(h.calls.indexOf('hw_server:stopped') < h.calls.indexOf('openocd:start'));
        assert.ok(h.calls.indexOf('openocd:ready') < h.calls.indexOf('debug:start'));
        assert.equal(h.errors.length, 0);
    });
}

test('cancelling the image-reset wait blocks immediate Attach until settling finishes', async t => {
    const h = await harness(t);
    h.control.imageResetWait = deferred<void>();
    let settled = false;
    const loading = h.command('loadAndDebug').then(() => { settled = true; });
    await eventually(() => h.calls.includes('image-reset:waiting'),
        'Software load did not reach its image-reset wait');
    assert.deepEqual(h.delays, [2040]);
    h.cancel();
    await h.command('attach');
    assert.equal(h.warnings.length, 1);
    assert.equal(settled, false, 'Cancellation must wait out a reset already triggered by image writes');
    assert.equal(h.calls.includes('hw_server:stop-requested'), false);
    assert.equal(h.calls.includes('openocd:start'), false);
    h.control.imageResetWait.resolve();
    await loading;
    assert.ok(h.calls.includes('hw_server:stopped'));
    assert.equal(h.owned.size, 0);
    assert.equal(h.calls.includes('image-reset:released'), true);
    assert.equal(h.calls.includes('openocd:start'), false);
    assert.equal(h.launches.length, 0);
    assert.match(h.errors.join('\n'), /cancelled/);
    await noSymbolCopies(h.root);
    await h.command('attach');
    assert.equal(h.launches.length, 1, 'Attach can proceed after reset settling and server cleanup');
    assert.ok(h.calls.indexOf('image-reset:released') < h.calls.indexOf('openocd:start'));
});

test('cancelling a partial load first stops its writer, then settles reset before another Attach', async t => {
    const h = await harness(t);
    h.control.loadCompletion = deferred<void>();
    h.control.loaderStopGate = deferred<void>();
    h.control.imageResetWait = deferred<void>();
    const loading = h.command('loadAndDebug');
    await eventually(() => h.calls.includes('loader:wait'), 'Native loader did not start');
    h.cancel();
    await eventually(() => h.calls.includes('loader:stop-requested'),
        'Cancellation did not request native loader cleanup');
    assert.equal(h.calls.includes('image-reset:waiting'), false,
        'The inactivity interval cannot start while a native writer may still issue writes');
    assert.equal(h.calls.includes('hw_server:stop-requested'), false);
    h.control.loaderStopGate.resolve();
    await eventually(() => h.calls.includes('image-reset:waiting'),
        'A cancelled partial load did not settle image reset');
    assert.ok(h.calls.indexOf('loader:stopped') < h.calls.indexOf('image-reset:waiting'));
    await h.command('attach');
    assert.equal(h.warnings.length, 1);
    assert.equal(h.calls.includes('openocd:start'), false);
    assert.equal(h.launches.length, 0);
    h.control.imageResetWait.resolve();
    await loading;
    assert.equal(h.owned.size, 0);
    assert.match(h.errors.join('\n'), /cancelled/);
    await h.command('attach');
    assert.equal(h.launches.length, 1);
    assert.ok(h.calls.indexOf('hw_server:stopped') < h.calls.indexOf('openocd:start'));
});

test('a failed loader that may have written memory also fences the next Attach through reset release', async t => {
    const h = await harness(t);
    h.control.loadError = new Error('fixture loader failed after the first image write');
    h.control.imageResetWait = deferred<void>();
    const loading = h.command('loadAndDebug');
    await eventually(() => h.calls.includes('image-reset:waiting'),
        'A failed partial load did not settle image reset');
    assert.ok(h.calls.indexOf('loader:stopped') < h.calls.indexOf('image-reset:waiting'));
    await h.command('attach');
    assert.equal(h.warnings.length, 1);
    assert.equal(h.calls.includes('openocd:start'), false);
    assert.equal(h.calls.includes('hw_server:stop-requested'), false);
    h.control.imageResetWait.resolve();
    await loading;
    assert.equal(h.owned.size, 0);
    assert.match(h.errors.join('\n'), /failed after the first image write/);
    await noSymbolCopies(h.root);
    await h.command('attach');
    assert.equal(h.launches.length, 1);
    assert.ok(h.calls.indexOf('image-reset:released') < h.calls.indexOf('openocd:start'));
});

for (const memory of ['bram', 'ddr'] as const) {
    for (const operation of ['attach', 'loadAndDebug'] as const) {
        test(`${operation} for ${memory} gives cppdbg the intended stop/continue behavior`, async t => {
            const h = await harness(t);
            h.settings.memory = memory;
            await h.command(operation);
            assert.equal(h.launches.length, 1);
            const config = h.launches[0];
            const resetToMain = operation === 'loadAndDebug' && memory === 'bram';
            assert.equal(config.stopAtConnect, !resetToMain,
                'Stopping on connect suppresses cppdbg launchCompleteCommand continuation');
            assert.equal(config.launchCompleteCommand, resetToMain ? 'exec-continue' : 'None');
            const commands = config.postRemoteConnectCommands as { text: string }[];
            assert.equal(commands.some(command => command.text === 'tbreak main'), resetToMain);
            assert.equal(commands.some(command => command.text === 'monitor reset halt'), resetToMain);
            assert.equal(h.errors.length, 0);
        });
    }
}
