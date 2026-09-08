// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import test, { TestContext } from 'node:test';
import type { FrostSettings } from '../src/settings';
import { assertSameImages, DebugBuild, imageDigests, imageResetDelayMs, loadArguments, parseDebugBuild } from '../src/hardware';
import { bounded } from '../src/process';
import * as processTools from '../src/process';
import { pickDebugTarget, pickPlainLoad, plainLoadArguments, PlainLoadSelection, PlainLoadUi,
    RepositoryMetadata, validateDebugTarget } from '../src/plainLoad';

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
        fs.writeFile(path.join(app, '.frost-build-config.bin'), 'fixture build configuration'),
        fs.writeFile(path.join(root, 'design.bit'), 'fixture bitstream'),
    ]);
    const settings: FrostSettings = {
        repoRoot: root, pythonPath: 'fixture-python', openocdPath: 'fixture-openocd',
        gdbPath: 'fixture-gdb', vivadoPath: 'fixture-vivado', hwServerPath: 'fixture-hw-server',
        jtagSerial: 'FIXTURE', vivadoTarget: '127.0.0.1:3121/xilinx_tcf/Xilinx/FIXTURE',
        app: 'hello_world', memory: 'bram', cpuClockHz: 300000000,
        bitstream: path.join(root, 'design.bit'), elf: path.join(app, 'sw.elf'),
        elfExplicit: false,
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
    const nativeStarts: Array<{ args: string[]; settings: FrostSettings; env?: NodeJS.ProcessEnv }> = [];
    const toolRuns: Array<{ args: string[]; settings: FrostSettings; env?: NodeJS.ProcessEnv }> = [];
    const savedSelections: PlainLoadSelection[] = [];
    const metadata: RepositoryMetadata = {
        apps: ['hello_world', 'debug_target', 'coremark', 'csr_test', 'ddr_exec_test',
            'coremark_pro_core', 'linux_boot', 'opensbi_smoke'],
        defaultSerial: '/fixture/uart', coremarkProApps: ['coremark_pro_core'],
        ddrApps: ['ddr_exec_test', 'coremark_pro_core', 'linux_boot', 'opensbi_smoke'], hasDdr: true,
        debugApps: ['hello_world', 'debug_target', 'coremark', 'csr_test', 'ddr_exec_test', 'coremark_pro_core'],
        debugUnsupported: { linux_boot: 'Linux uses composite images.', opensbi_smoke: 'OpenSBI uses composite images.' },
        appBuildDirectories: { hello_world: 'hello_world', debug_target: 'debug_target', coremark: 'coremark',
            csr_test: 'csr_test', ddr_exec_test: 'ddr_exec_test', coremark_pro_core: 'coremark_pro',
            linux_boot: 'linux_boot', opensbi_smoke: 'opensbi_smoke' },
    };
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
        selection: { app: 'coremark', memory: 'bram', cpuClockHz: 150000000 } as PlainLoadSelection | undefined,
        pickerUi: undefined as PlainLoadUi | undefined,
        debugPickerUi: undefined as PlainLoadUi | undefined,
        debugSelection: undefined as PlainLoadSelection | null | undefined,
        saveError: undefined as Error | undefined,
        buildOverrides: {} as Partial<DebugBuild>,
        buildOutput: undefined as string | undefined,
        afterBuild: undefined as ((build: DebugBuild) => Promise<void>) | undefined,
        metadataError: undefined as Error | undefined,
        loadTimeout: 7200000 as unknown,
    };

    class FakeSerialConsole {
        async autoOpen(): Promise<void> { calls.push('serial:auto-open'); }
        async afterJtag(): Promise<void> { calls.push('serial:reassert'); }
        async show(): Promise<void> { calls.push('serial:show'); }
        async close(): Promise<void> { calls.push('serial:close'); }
        async dispose(): Promise<void> { calls.push('serial:dispose'); }
    }

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
        async run(_command: string, args: string[], targetSettings: FrostSettings,
            _signal: AbortSignal, env?: NodeJS.ProcessEnv): Promise<string> {
            toolRuns.push({ args, settings: targetSettings, env });
            calls.push(args[0].includes('program_bitstream') ? 'tool:program'
                : args.includes('--build-only') ? 'tool:build' : 'tool:load');
            if (!args.includes('--build-only')) return '';
            const directory = path.join(root, 'sw/apps', metadata.appBuildDirectories[targetSettings.app]);
            await fs.mkdir(directory, { recursive: true });
            for (const [file, contents] of Object.entries({
                'sw.elf': `fixture ELF for ${targetSettings.app}`, 'sw.txt': '00000013\n',
                'sw_ddr.txt': '00000013\n', '.frost-build-config.bin': `fixture build of ${targetSettings.app}`,
            })) {
                try { await fs.access(path.join(directory, file)); }
                catch { await fs.writeFile(path.join(directory, file), contents); }
            }
            const build: DebugBuild = {
                app: targetSettings.app, appDirectory: directory, elf: path.join(directory, 'sw.elf'),
                effectiveMemory: targetSettings.memory,
                startStrategy: targetSettings.memory === 'ddr' ? 'attach' : 'main',
                buildConfigSha256: createHash('sha256').update(await fs.readFile(path.join(directory, '.frost-build-config.bin'))).digest('hex'),
                ...control.buildOverrides,
            };
            await control.afterBuild?.(build);
            return control.buildOutput ?? `FROST_DEBUG_BUILD=${JSON.stringify(build)}\nFROST_BUILD_COMPLETE\n`;
        }
        start(_command: string, args: string[], targetSettings: FrostSettings, env?: NodeJS.ProcessEnv): FakeProcess {
            assert.ok(args[0].includes('load_software'),
                'This fixture starts only the native software loader');
            nativeStarts.push({ args, settings: targetSettings, env });
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
        workspace: { isTrusted: true, workspaceFolders: [folder],
            getConfiguration: () => ({ get: (key: string, fallback: unknown) =>
                key === 'loadTimeoutMs' ? control.loadTimeout : fallback }),
        },
        extensions: { getExtension: () => ({ activate: async () => { calls.push('cppdbg:activate'); } }) },
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
            if (parent?.filename === extensionPath && request === './serialConsole') {
                return { SerialConsole: FakeSerialConsole };
            }
            if (parent?.filename === extensionPath && request === './focusLayout') {
                return { registerFocusLayout: () => dispose() };
            }
            if (parent?.filename === extensionPath && request === './plainLoad') {
                return { plainLoadArguments, validateDebugTarget,
                    readRepositoryMetadata: async () => {
                        calls.push('metadata:read');
                        if (control.metadataError) throw control.metadataError;
                        return metadata;
                    },
                    pickDebugTarget: async (targetSettings: FrostSettings, repository: RepositoryMetadata,
                        _ui?: PlainLoadUi, signal?: AbortSignal) => {
                        calls.push('debug:pick');
                        if (control.debugPickerUi) return pickDebugTarget(targetSettings, repository, control.debugPickerUi, signal);
                        if (control.debugSelection === null) return undefined;
                        const selected = control.debugSelection ?? { app: targetSettings.app, memory: targetSettings.memory,
                            cpuClockHz: targetSettings.cpuClockHz,
                            ...(metadata.coremarkProApps.includes(targetSettings.app) ? { coremarkMode: targetSettings.coremarkMode } : {}) };
                        validateDebugTarget(selected, repository);
                        return selected;
                    },
                    pickPlainLoad: async (targetSettings: FrostSettings,
                        metadata: Parameters<typeof pickPlainLoad>[1], _ui?: PlainLoadUi, signal?: AbortSignal) => {
                        calls.push('plain:pick');
                        return control.pickerUi ? pickPlainLoad(targetSettings, metadata, control.pickerUi, signal)
                            : control.selection;
                    },
                };
            }
            if (parent?.filename === extensionPath && request === './settings') {
                return { getSettings: () => settings, configureTarget: async () => true,
                    saveDebugSelection: async (_folder: unknown, selected: PlainLoadSelection) => {
                        if (control.saveError) throw control.saveError;
                        calls.push('settings:saved');
                        savedSelections.push({ ...selected });
                        Object.assign(settings, selected, { coremarkMode: selected.coremarkMode });
                    },
                };
            }
            if (parent?.filename === extensionPath && request === './hardware') {
                return { Hardware: FakeHardware, HW_URL: '127.0.0.1:3121',
                    assertSameImages, imageDigests, imageResetDelayMs, loadArguments, parseDebugBuild };
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
        root, settings, metadata, calls, errors, warnings, output, owned, launches, nativeStarts,
        toolRuns, savedSelections, delays, sessions, stoppedByVscode,
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

function selectionUi(answers: Array<string | undefined>, clock = '150000000'): PlainLoadUi {
    return {
        async showQuickPick(items) {
            const next = answers.shift();
            return items.find(item => (item as typeof item & { value: string }).value === next);
        },
        showInputBox: async () => clock,
    };
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

for (const operation of ['programBitstream', 'loadAndDebug', 'loadSoftware'] as const) {
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
        else if (operation === 'programBitstream') assert.ok(h.calls.indexOf('tool:program') > cleanup);
        else assert.ok(h.calls.indexOf('tool:load') > cleanup);
        assert.equal(h.errors.length, 0);
    });
}

for (const memory of ['bram', 'ddr'] as const) {
    test(`plain ${memory} load runs the selected release application without invoking a debugger or copying symbols`, async t => {
        const h = await harness(t);
        h.control.selection!.memory = memory;
        h.control.loadTimeout = 8100000;
        // A plain application does not need a debug ELF or even the configured
        // debugger application's directory. The native loader owns its build.
        await fs.rm(path.join(h.root, 'sw/apps/hello_world'), { recursive: true });
        const prior = Object.fromEntries(['MEM_CONFIG', 'FROST_DEBUG', 'FROST_ILA_ARM_HOOK', 'FROST_ILA_COLLECT_HOOK']
            .map(key => [key, process.env[key]]));
        t.after(() => {
            for (const [key, value] of Object.entries(prior)) {
                if (value === undefined) delete process.env[key];
                else process.env[key] = value;
            }
        });
        process.env.MEM_CONFIG = 'inherited-invalid-layout';
        process.env.FROST_DEBUG = '1';
        process.env.FROST_ILA_ARM_HOOK = 'fixture-arm-hook';
        process.env.FROST_ILA_COLLECT_HOOK = 'fixture-collect-hook';
        await h.command('loadSoftware');
        assert.deepEqual(h.errors, []);
        assert.equal(h.nativeStarts.length, 1);
        const loader = h.nativeStarts[0];
        assert.deepEqual(loader.args.slice(0, 3), ['fpga/load_software/load_software.py', 'x3', 'coremark']);
        assert.equal(loader.args.includes('--debug'), false);
        assert.equal(loader.args.includes('--skip-build'), false);
        assert.equal(loader.args.includes('--ddr'), memory === 'ddr');
        assert.equal(loader.env?.FROST_DEBUG, '0');
        assert.equal(loader.env?.MEM_CONFIG, memory === 'ddr' ? 'ddr' : undefined);
        assert.equal(loader.env?.FROST_CPU_CLK_HZ, '150000000');
        assert.equal(loader.env?.FROST_ILA_ARM_HOOK, undefined);
        assert.equal(loader.env?.FROST_ILA_COLLECT_HOOK, undefined);
        assert.equal(loader.settings.toolTimeoutMs, 8100000);
        assert.equal(h.settings.toolTimeoutMs, 1000, 'Plain-load timeout must not mutate the debugger settings');
        assert.equal(h.calls.includes('cppdbg:activate'), false);
        assert.equal(h.calls.includes('openocd:start'), false);
        assert.equal(h.launches.length, 0);
        assert.equal(h.owned.size, 0);
        assert.deepEqual(h.delays, [3830]);
        const loaderStopped = h.calls.indexOf('loader:stopped');
        assert.equal(h.calls[loaderStopped + 1], 'serial:reassert');
        assert.equal(h.calls[loaderStopped + 2], 'image-reset:waiting');
        assert.ok(h.calls.indexOf('image-reset:released') < h.calls.indexOf('hw_server:stopped'));
        assert.match(h.output.join(''), /coremark loaded and running/);
        await assert.rejects(fs.stat(path.join(h.root, 'extension-storage/symbols')), { code: 'ENOENT' });
    });
}

test('CoreMark debug selection persists before handoff and loads its own ELF and verified build configuration', async t => {
    const h = await harness(t);
    await h.command('attach');
    const old = h.sessions[0];
    h.control.debugPickerUi = selectionUi(['coremark', 'bram']);
    await h.command('loadAndDebug');
    assert.deepEqual(h.errors, []);
    assert.deepEqual(h.savedSelections, [{ app: 'coremark', memory: 'bram', cpuClockHz: 150000000 }]);
    assert.ok(h.calls.indexOf('settings:saved') < h.calls.indexOf(`session:disconnect:${old.id}`));
    assert.equal(h.settings.app, 'coremark');
    assert.equal(h.settings.cpuClockHz, 150000000);
    const build = h.toolRuns.find(run => run.args.includes('--build-only'))!;
    const loader = h.nativeStarts[0];
    for (const invocation of [build, loader]) {
        assert.equal(invocation.args[2], 'coremark');
        assert.ok(invocation.args.includes('--debug'));
        assert.equal(invocation.env?.FROST_CPU_CLK_HZ, '150000000');
    }
    const stamp = await fs.readFile(path.join(h.root, 'sw/apps/coremark/.frost-build-config.bin'));
    assert.equal(loader.args[loader.args.indexOf('--expected-build-config-sha256') + 1],
        createHash('sha256').update(stamp).digest('hex'));
    const config = h.launches[1];
    assert.equal(config.name, 'FROST: coremark (bram)');
    assert.equal(await fs.readFile(config.program as string, 'utf8'), 'fixture ELF for coremark');
    assert.ok((config.postRemoteConnectCommands as { text: string }[]).some(command => command.text === 'tbreak main'));
});

test('assembly builds use the loader reset strategy without a nonexistent main breakpoint', async t => {
    const h = await harness(t);
    h.control.debugSelection = { app: 'csr_test', memory: 'bram', cpuClockHz: 300000000 };
    h.control.buildOverrides.startStrategy = 'reset';
    await h.command('loadAndDebug');
    assert.deepEqual(h.errors, []);
    const config = h.launches[0];
    assert.equal(config.stopAtConnect, true);
    assert.equal(config.launchCompleteCommand, 'None');
    const commands = config.postRemoteConnectCommands as { text: string }[];
    assert.ok(commands.some(command => command.text === 'monitor reset halt'));
    assert.equal(commands.some(command => command.text === 'tbreak main'), false);
    assert.match(h.output.join(''), /Assembly application stopped at reset PC zero/);
});

test('a default-layout app actually built in DDR attaches at its current PC', async t => {
    const h = await harness(t);
    h.control.debugSelection = { app: 'ddr_exec_test', memory: 'bram', cpuClockHz: 150000000 };
    h.control.buildOverrides = { effectiveMemory: 'ddr', startStrategy: 'attach' };
    await h.command('loadAndDebug');
    assert.deepEqual(h.errors, []);
    assert.equal(h.nativeStarts[0].args.includes('--ddr'), false, 'Default app layout must retain its own Makefile choice');
    const config = h.launches[0];
    assert.equal(config.name, 'FROST: ddr_exec_test (ddr)');
    assert.equal(config.stopAtConnect, true);
    assert.equal(config.launchCompleteCommand, 'None');
    assert.deepEqual(config.postRemoteConnectCommands, []);
    assert.match(h.output.join(''), /current PC/);
});

test('CoreMark-PRO debug and later Attach use the mapped build directory and retain the selected run mode', async t => {
    const h = await harness(t);
    h.control.debugPickerUi = selectionUi(['coremark_pro_core', 'bram', 'validation']);
    h.control.buildOverrides = { effectiveMemory: 'ddr', startStrategy: 'attach' };
    await h.command('loadAndDebug');
    assert.deepEqual(h.errors, []);
    assert.equal(h.settings.coremarkMode, 'validation');
    for (const invocation of [...h.toolRuns.filter(run => run.args.includes('--build-only')), ...h.nativeStarts]) {
        assert.equal(invocation.args[2], 'coremark_pro_core');
        assert.ok(invocation.args.includes('-v1'));
    }
    const realElf = path.join(h.root, 'sw/apps/coremark_pro/sw.elf');
    const bytes = await fs.readFile(realElf, 'utf8');
    assert.equal(await fs.readFile(h.launches[0].program as string, 'utf8'), bytes);
    await assert.rejects(fs.stat(path.join(h.root, 'sw/apps/coremark_pro_core')), { code: 'ENOENT' });
    await h.command('disconnect');
    await h.command('attach');
    assert.deepEqual(h.errors, []);
    assert.equal(h.launches.length, 2);
    assert.equal(await fs.readFile(h.launches[1].program as string, 'utf8'), bytes);
    assert.deepEqual(h.launches[1].postRemoteConnectCommands, []);
});

for (const operation of ['loadAndDebug', 'programAndDebug'] as const) {
    for (const choice of ['cancelled', 'unsupported'] as const) {
        test(`${operation} with a ${choice} debug picker preserves the existing session before handoff`, async t => {
            const h = await harness(t);
            await h.command('attach');
            const old = h.launches[0];
            const daemon = [...h.owned][0];
            const before = h.calls.length;
            h.control.debugPickerUi = selectionUi([choice === 'unsupported' ? 'linux_boot' : undefined]);
            await h.command(operation);
            assert.deepEqual(h.calls.slice(before), ['metadata:read', 'debug:pick']);
            assert.equal(h.savedSelections.length, 0);
            assert.equal(h.launches.length, 1);
            assert.equal(daemon.running, true);
            assert.equal(h.provider(old), old);
            assert.equal(await fs.readFile(old.program as string, 'utf8'), 'fixture ELF and symbols');
            assert.equal(h.nativeStarts.length, 0);
            if (choice === 'unsupported') assert.match(h.errors.join('\n'), /Linux uses composite images/);
            else assert.deepEqual(h.errors, []);
        });
    }
}

test('a debug-selection save failure preserves the existing session and never starts a hardware operation', async t => {
    const h = await harness(t);
    await h.command('attach');
    const daemon = [...h.owned][0];
    const before = h.calls.length;
    h.control.saveError = new Error('fixture User settings are read-only');
    await h.command('loadAndDebug');
    assert.deepEqual(h.calls.slice(before), ['metadata:read', 'debug:pick']);
    assert.equal(daemon.running, true);
    assert.equal(h.launches.length, 1);
    assert.match(h.errors.join('\n'), /User settings are read-only/);
});

test('Attach rejects an unsupported configured app before replacing an existing debugger', async t => {
    const h = await harness(t);
    await h.command('attach');
    const before = h.calls.length;
    const daemon = [...h.owned][0];
    h.settings.app = 'linux_boot';
    await h.command('attach');
    assert.deepEqual(h.calls.slice(before), ['metadata:read']);
    assert.equal(daemon.running, true);
    assert.equal(h.launches.length, 1);
    assert.match(h.errors.join('\n'), /Linux uses composite images/);
});

for (const failure of ['invalid descriptor', 'changed build stamp'] as const) {
    test(`${failure} prevents FPGA programming, software loading, and debugger startup`, async t => {
        const h = await harness(t);
        if (failure === 'invalid descriptor') h.control.buildOutput = 'FROST_BUILD_COMPLETE\n';
        else h.control.afterBuild = build => fs.writeFile(path.join(build.appDirectory, '.frost-build-config.bin'),
            'fixture configuration changed after the build report');
        await h.command('programAndDebug');
        assert.equal(h.calls.includes('hw_server:start'), false);
        assert.equal(h.calls.includes('tool:program'), false);
        assert.equal(h.nativeStarts.length, 0);
        assert.equal(h.calls.includes('openocd:start'), false);
        assert.equal(h.launches.length, 0);
        assert.equal(h.owned.size, 0);
        assert.match(h.errors.join('\n'), failure === 'invalid descriptor'
            ? /exactly one debug build/ : /build configuration changed before loading/);
        await noSymbolCopies(h.root);
    });
}

test('cancelling the plain-load picker leaves an existing debugger and its symbols untouched', async t => {
    const h = await harness(t);
    await h.command('attach');
    const before = h.calls.length;
    const symbols = h.launches[0].program as string;
    const daemon = [...h.owned][0];
    h.control.pickerUi = {
        showQuickPick: async () => undefined,
        showInputBox: async () => assert.fail('A dismissed application picker cannot advance'),
    };
    await h.command('loadSoftware');
    const after = h.calls.slice(before);
    assert.ok(after.includes('plain:pick'));
    assert.equal(after.some(call => call.startsWith('session:disconnect:')), false);
    assert.equal(after.includes('hardware:preflight'), false);
    assert.equal(after.includes('hw_server:start'), false);
    assert.equal(daemon.running, true);
    assert.equal(h.launches.length, 1);
    assert.equal(await fs.readFile(symbols, 'utf8'), 'fixture ELF and symbols');
    assert.deepEqual(h.errors, []);
});

test('Disconnect cancels a pending real application picker and then detaches the active debugger', { timeout: 1500 }, async t => {
    const h = await harness(t);
    await h.command('attach');
    const session = h.sessions[0];
    const prompted = deferred<void>();
    let dismissed = false;
    h.control.pickerUi = {
        showQuickPick: (_items, _options, token) => {
            assert.ok(token);
            token.onCancellationRequested(() => { dismissed = true; });
            prompted.resolve();
            return new Promise(() => {});
        },
        showInputBox: async () => assert.fail('Cancellation cannot advance the picker'),
    };
    const loading = h.command('loadSoftware');
    await prompted.promise;
    const disconnecting = h.command('disconnect');
    await Promise.all([loading, disconnecting]);
    assert.equal(dismissed, true);
    assert.ok(h.calls.includes(`session:disconnect:${session.id}`));
    assert.equal(h.calls.includes('hw_server:start'), false);
    assert.equal(h.nativeStarts.length, 0);
    assert.equal(h.launches.length, 1);
    assert.equal(h.owned.size, 0);
    await noSymbolCopies(h.root);
});

for (const preparation of ['metadata', 'picker'] as const) {
    test(`a ${preparation} error before plain-load handoff preserves the active debugger, symbols and UART state`, async t => {
        const h = await harness(t);
        await h.command('attach');
        const config = h.launches[0];
        const symbols = config.program as string;
        const daemon = [...h.owned][0];
        const before = h.calls.length;
        const error = new Error(`fixture ${preparation} preparation failed`);
        if (preparation === 'metadata') h.control.metadataError = error;
        else h.control.pickerUi = {
            showQuickPick: async () => { throw error; },
            showInputBox: async () => assert.fail('A failed application picker cannot advance'),
        };
        await h.command('loadSoftware');
        assert.deepEqual(h.calls.slice(before), preparation === 'metadata'
            ? ['metadata:read'] : ['metadata:read', 'plain:pick'],
        'Preparation failure must not touch JTAG, UART, or the existing debug session');
        assert.equal(daemon.running, true);
        assert.deepEqual([...h.owned], [daemon]);
        assert.equal(h.launches.length, 1);
        assert.equal(h.nativeStarts.length, 0);
        assert.equal(h.provider(config), config, 'The current session token must remain valid');
        assert.equal(await fs.readFile(symbols, 'utf8'), 'fixture ELF and symbols');
        assert.match(h.errors.join('\n'), new RegExp(`fixture ${preparation} preparation failed`));
        await h.command('disconnect');
        assert.equal(h.owned.size, 0, 'The preserved session remains available for an explicit detach');
    });
}

test('an unsupported 150 Hz reset interval is rejected before any plain-load hardware operation', async t => {
    const h = await harness(t);
    h.control.selection!.cpuClockHz = 150;
    await h.command('loadSoftware');
    assert.match(h.errors.join('\n'), /supported image-reset wait/);
    assert.equal(h.calls.includes('hardware:preflight'), false);
    assert.equal(h.calls.includes('serial:auto-open'), false);
    assert.equal(h.calls.includes('hw_server:start'), false);
    assert.equal(h.nativeStarts.length, 0);
    assert.equal(h.launches.length, 0);
    assert.equal(h.owned.size, 0);
    assert.deepEqual(h.delays, []);
});

for (const outcome of ['failed', 'cancelled'] as const) {
    test(`${outcome} plain load stops its writer and reasserts UART before holding reset and releasing the cable`, async t => {
        const h = await harness(t);
        h.control.imageResetWait = deferred<void>();
        h.control.loaderStopGate = deferred<void>();
        if (outcome === 'failed') h.control.loadError = new Error('fixture plain loader failed after writes');
        else h.control.loadCompletion = deferred<void>();
        const loading = h.command('loadSoftware');
        await eventually(() => h.calls.includes('loader:wait'), 'Plain loader did not start');
        if (outcome === 'cancelled') h.cancel();
        await eventually(() => h.calls.includes('loader:stop-requested'), 'Plain loader cleanup was not requested');
        assert.equal(h.calls.includes('image-reset:waiting'), false);
        assert.equal(h.calls.includes('hw_server:stop-requested'), false);
        h.control.loaderStopGate.resolve();
        await eventually(() => h.calls.includes('image-reset:waiting'), 'Plain load did not settle image reset');
        const stopped = h.calls.indexOf('loader:stopped');
        assert.equal(h.calls[stopped + 1], 'serial:reassert');
        assert.equal(h.calls[stopped + 2], 'image-reset:waiting');
        assert.deepEqual([...h.owned].map(child => child.name), ['hw_server']);
        await h.command('attach');
        assert.equal(h.warnings.length, 1);
        assert.equal(h.calls.includes('openocd:start'), false);
        h.control.imageResetWait.resolve();
        await loading;
        assert.equal(h.owned.size, 0);
        assert.equal(h.launches.length, 0);
        assert.equal(h.calls.includes('cppdbg:activate'), false);
        assert.ok(h.calls.indexOf('image-reset:released') < h.calls.indexOf('hw_server:stopped'));
        assert.match(h.errors.join('\n'), outcome === 'failed' ? /failed after writes/ : /cancelled/);
        assert.doesNotMatch(h.output.join(''), /coremark loaded and running/);
        await noSymbolCopies(h.root);
    });
}

for (const operation of ['attach', 'loadAndDebug', 'programBitstream', 'programAndDebug'] as const) {
    test(`${operation} opens the optional serial console and reasserts it around JTAG handoffs`, async t => {
        const h = await harness(t);
        await h.command(operation);
        const autoOpen = h.calls.indexOf('serial:auto-open');
        assert.ok(autoOpen > h.calls.indexOf('hardware:preflight'));
        if (operation !== 'attach') {
            const server = h.calls.indexOf('hw_server:start');
            assert.ok(autoOpen < server);
            assert.equal(h.calls[server + 1], 'serial:reassert');
        }
        if (operation.startsWith('program')) {
            const programmed = h.calls.indexOf('tool:program');
            assert.equal(h.calls[programmed + 1], 'serial:reassert');
        }
        if (operation !== 'programBitstream') {
            const openOcd = h.calls.indexOf('openocd:ready');
            assert.ok(autoOpen < openOcd);
            assert.equal(h.calls[openOcd + 1], 'serial:reassert');
            assert.ok(openOcd < h.calls.indexOf('debug:start'));
            await h.command('disconnect');
            assert.equal(h.calls[h.calls.indexOf('openocd:stopped') + 1], 'serial:reassert');
        }
        assert.deepEqual(h.errors, []);
    });
}

test('manual serial commands reach the console without acquiring JTAG', async t => {
    const h = await harness(t);
    await h.command('openSerialConsole');
    await h.command('closeSerialConsole');
    assert.deepEqual(h.calls, ['serial:show', 'serial:close']);
    assert.equal(h.owned.size, 0);
});

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
