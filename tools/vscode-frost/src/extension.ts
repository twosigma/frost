// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import * as vscode from 'vscode';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { configureTarget, FrostSettings, getSettings } from './settings';
import { Hardware, HW_URL, assertSameImages, imageDigests, imageResetDelayMs, loadArguments } from './hardware';
import { OwnedProcess, bounded, delay } from './process';
import { debugConfiguration } from './debugConfiguration';

type Operation = 'attach' | 'loadAndDebug' | 'programBitstream' | 'programAndDebug';

function deferred<T>() {
    let resolve!: (value: T) => void;
    let reject!: (error: unknown) => void;
    const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
    void promise.catch(() => {});
    return { promise, resolve, reject };
}

interface ManagedSession {
    id: string;
    symbols: string;
    daemon: OwnedProcess;
    session?: vscode.DebugSession;
    started: ReturnType<typeof deferred<vscode.DebugSession>>;
    stopped: ReturnType<typeof deferred<void>>;
    ended: ReturnType<typeof deferred<void>>;
    closing?: Promise<void>;
}

let controller: Controller | undefined;

class Controller {
    private readonly output = vscode.window.createOutputChannel('FROST');
    private readonly hardware = new Hardware(text => this.output.append(text));
    private active?: ManagedSession;
    private operation?: Promise<void>;
    private abort?: AbortController;
    private closing = false;
    private blocked?: string;
    private readonly symbolCopies = new Set<string>();

    constructor(private readonly context: vscode.ExtensionContext) {
        context.subscriptions.push(this.output);
        for (const kind of ['attach', 'loadAndDebug', 'programBitstream', 'programAndDebug'] as Operation[]) {
            context.subscriptions.push(vscode.commands.registerCommand(`frost.${kind}`, () => this.run(kind)));
        }
        context.subscriptions.push(
            vscode.commands.registerCommand('frost.showOutput', () => this.output.show()),
            vscode.commands.registerCommand('frost.configureTarget', async () => {
                try { await configureTarget(await this.folder()); }
                catch (error) { this.error(error); }
            }),
            vscode.commands.registerCommand('frost.disconnect', async () => {
                this.abort?.abort(new Error('Operation cancelled'));
                await this.operation;
                try { await this.disconnect(); } catch (error) { this.error(error); }
            }),
            vscode.debug.onDidStartDebugSession(session => {
                const id = session.configuration.__frostSessionId;
                if (!id) return;
                const current = this.active;
                if (current && current.id === id && !current.closing) {
                    current.session = session; current.started.resolve(session);
                } else {
                    // A timed-out launch must never become a later operation's
                    // hidden second client, even if VS Code finishes it late.
                    void vscode.debug.stopDebugging(session);
                }
            }),
            vscode.debug.onDidTerminateDebugSession(session => {
                const current = this.active;
                if (!current || current.id !== session.configuration.__frostSessionId) return;
                current.ended.resolve();
                current.stopped.reject(new Error('Debugger ended before reaching a stopped state'));
                if (!current.closing) void this.finishSession(current, false).catch(error => this.error(error));
            }),
            vscode.debug.registerDebugConfigurationProvider('cppdbg', {
                resolveDebugConfigurationWithSubstitutedVariables: (_folder, config) => {
                    if (!config.__frostSessionId) return config;
                    const current = this.active;
                    return current && current.id === config.__frostSessionId && !current.closing ? config : null;
                },
            }),
            vscode.debug.registerDebugAdapterTrackerFactory('cppdbg', {
                createDebugAdapterTracker: session => {
                    const current = this.active;
                    if (!current || current.id !== session.configuration.__frostSessionId) return undefined;
                    // Observe the public adapter stream; never replace the
                    // adapter, rewrite capabilities, or reframe DAP messages.
                    return {
                        onDidSendMessage: message => {
                            if (message.type === 'event' && message.event === 'stopped') current.stopped.resolve();
                            if (message.type === 'response' && message.command === 'launch' && !message.success) {
                                current.stopped.reject(new Error(message.message ?? 'cppdbg launch failed'));
                            }
                        },
                        onError: error => current.stopped.reject(error),
                        onExit: () => current.stopped.reject(new Error('Debug adapter exited')),
                    };
                },
            }),
        );
    }

    private async folder(): Promise<vscode.WorkspaceFolder> {
        if (process.platform !== 'linux') throw new Error('FROST v1 runs on the Linux FPGA host, locally or through Remote-SSH.');
        if (!vscode.workspace.isTrusted) throw new Error('Trust this repository before running its FPGA tools.');
        const folders = vscode.workspace.workspaceFolders ?? [];
        if (folders.length === 1) return folders[0];
        if (!folders.length) throw new Error('Open the FROST repository folder first.');
        const folder = await vscode.window.showWorkspaceFolderPick({ placeHolder: 'Select the FROST repository' });
        if (!folder) throw new Error('No repository selected');
        return folder;
    }

    private error(error: unknown): void {
        const message = error instanceof Error ? error.message : String(error);
        this.output.appendLine(`\nERROR: ${message}`);
        void vscode.window.showErrorMessage(`FROST: ${message.split('\n')[0]}`, 'Show Output')
            .then(choice => { if (choice) this.output.show(); });
    }

    run(kind: Operation): Promise<void> {
        if (this.operation || this.closing) {
            void vscode.window.showWarningMessage('A FROST operation is already in progress. Cancel it before starting another.');
            return Promise.resolve();
        }
        if (this.blocked) { this.error(this.blocked); return Promise.resolve(); }
        const abort = this.abort = new AbortController();
        this.operation = Promise.resolve().then(async () => {
            try {
                const folder = await this.folder();
                const settings = getSettings(folder);
                this.output.show(true);
                await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification,
                    title: 'FROST', cancellable: true }, async (progress, cancellation) => {
                    const listener = cancellation.onCancellationRequested(() => abort.abort(new Error('Operation cancelled')));
                    try {
                        progress.report({ message: 'Preparing target' });
                        await this.disconnect();
                        abort.signal.throwIfAborted();
                        await this.execute(kind, folder, settings, abort.signal,
                            message => progress.report({ message }));
                    } finally { listener.dispose(); }
                });
            } catch (error) {
                try { await this.disconnect(); await this.hardware.cleanup(); }
                catch (cleanup) {
                    this.blocked = `Cleanup is not confirmed; close this window before retrying. ${String(cleanup)}`;
                    this.error(this.blocked);
                }
                this.error(error);
            }
        }).finally(async () => {
            await this.clearUnusedSymbols();
            this.operation = undefined; this.abort = undefined;
        });
        return this.operation;
    }

    private async execute(kind: Operation, folder: vscode.WorkspaceFolder,
        settings: FrostSettings, signal: AbortSignal, progress: (message: string) => void): Promise<void> {
        const program = kind === 'programBitstream' || kind === 'programAndDebug';
        const load = kind === 'loadAndDebug' || kind === 'programAndDebug';
        let bitstream = settings.bitstream;
        if (program && !bitstream) {
            const selected = await vscode.window.showOpenDialog({ canSelectMany: false,
                title: 'Select FPGA bitstream', filters: { 'FPGA bitstream': ['bit'] },
                defaultUri: vscode.Uri.file(path.join(settings.repoRoot, 'fpga/build/x3/work')) });
            if (!selected?.length) throw new Error('No bitstream selected');
            bitstream = selected[0].fsPath;
        }
        if (program) {
            const stat = await fs.stat(bitstream);
            if (!stat.isFile() || !stat.size || path.extname(bitstream).toLowerCase() !== '.bit') throw new Error('Select a nonempty .bit file.');
        }
        if (kind !== 'programBitstream') {
            const cpp = vscode.extensions.getExtension('ms-vscode.cpptools');
            if (!cpp) throw new Error('Install Microsoft C/C++ on the FPGA host first.');
            await bounded(cpp.activate(), settings.startupTimeoutMs, signal);
        }
        await this.hardware.preflight(settings, program || load);
        const appDirectory = path.join(settings.repoRoot, 'sw/apps', settings.app);
        const buildEnvironment: NodeJS.ProcessEnv = { ...process.env, MEM_CONFIG: settings.memory,
            FROST_CPU_CLK_HZ: String(settings.cpuClockHz) };
        // Managed load has no ILA operation; inherited capture hooks must not
        // turn this command into an unsolicited capture workflow.
        delete buildEnvironment.FROST_ILA_ARM_HOOK;
        delete buildEnvironment.FROST_ILA_COLLECT_HOOK;
        const symbolsDirectory = path.join(this.context.globalStorageUri.fsPath, 'symbols');
        await fs.mkdir(symbolsDirectory, { recursive: true });
        // globalStorage is shared by windows: never reuse another window's ELF.
        const symbols = path.join(symbolsDirectory, `${randomUUID()}.elf`);
        this.symbolCopies.add(symbols);
        let digests: Map<string, string> | undefined;
        if (load) {
            progress('Building software with debug information');
            await this.hardware.run(settings.pythonPath, loadArguments(settings, true), settings,
                signal, buildEnvironment);
            digests = await imageDigests(appDirectory);
            await fs.copyFile(path.join(appDirectory, 'sw.elf'), symbols);
            if (createHash('sha256').update(await fs.readFile(symbols)).digest('hex') !== digests.get('sw.elf')) {
                throw new Error('The ELF changed while copying debug symbols. Stop other builds of this app and retry.');
            }
        } else if (!program) {
            await fs.copyFile(settings.elf, symbols);
        }
        if (program || load) {
            progress('Starting hardware server');
            const server = await this.hardware.startHwServer(settings, signal);
            try {
                if (program) {
                    progress('Programming FPGA');
                    await this.hardware.run(settings.pythonPath, [
                        'fpga/program_bitstream/program_bitstream.py', 'x3',
                        '--bitstream', bitstream, '--hw-server-url', HW_URL,
                        '--target-exact', settings.vivadoTarget, '--non-interactive',
                        '--vivado-path', settings.vivadoPath,
                    ], settings, signal);
                }
                if (load) {
                    assertSameImages(digests!, await imageDigests(appDirectory));
                    const resetDelay = imageResetDelayMs(settings.cpuClockHz);
                    signal.throwIfAborted();
                    progress('Loading software');
                    const loader = this.hardware.start(settings.pythonPath, loadArguments(settings, false),
                        settings, buildEnvironment);
                    try {
                        await loader.wait(settings.toolTimeoutMs, signal);
                    } finally {
                        // A cancelled or failed loader may already have written
                        // BRAM. Confirm it cannot write again before starting
                        // the full reset interval. Keep this operation active
                        // through settling so a following Attach cannot send
                        // DMI while the previous load still holds the DM reset.
                        await this.hardware.stop(loader);
                        progress('Waiting for image-load reset to release');
                        this.output.appendLine(`Waiting ${resetDelay} ms for image-load reset at ${settings.cpuClockHz} Hz before starting DMI. Cancellation completes after this reset interval.`);
                        await delay(resetDelay);
                    }
                    signal.throwIfAborted();
                    assertSameImages(digests!, await imageDigests(appDirectory));
                }
            } finally { await this.hardware.stop(server); }
        }
        if (kind === 'programBitstream') {
            this.output.appendLine('Bitstream programmed; owned hardware server stopped.');
            return;
        }
        signal.throwIfAborted();
        const coreXml = settings.registerDescription === 'core'
            ? this.context.asAbsolutePath('resources/frost-core.xml') : undefined;
        if (coreXml) {
            await fs.access(coreXml);
            if (/[\r\n]/.test(coreXml)) throw new Error('Register description path contains a newline.');
        }
        progress('Starting OpenOCD');
        const daemon = await this.hardware.startOpenOcd(settings, signal);
        progress(load && settings.memory === 'bram' ? 'Resetting BRAM application to main' : 'Attaching to loaded application');
        await this.startDebug(folder, settings, symbols, load && settings.memory === 'bram', coreXml, daemon, signal);
        this.output.appendLine(settings.memory === 'ddr' && load
            ? 'DDR image loaded and debugger stopped. The program can execute during cable handoff; reload is required for fresh initialized DDR data.'
            : 'Debugger stopped and ready. Use FROST: Disconnect and Resume to end the session.');
    }

    private async startDebug(folder: vscode.WorkspaceFolder, settings: FrostSettings,
        elf: string, reset: boolean, xml: string | undefined, daemon: OwnedProcess,
        signal: AbortSignal): Promise<void> {
        const record: ManagedSession = { id: randomUUID(), symbols: elf, daemon,
            started: deferred(), stopped: deferred(), ended: deferred() };
        this.active = record;
        void daemon.exited.then(result => {
            if (record.closing || this.active !== record) return;
            record.stopped.reject(new Error(`OpenOCD exited during debug (${result.code ?? result.error ?? result.signal}).`));
            this.error('OpenOCD exited unexpectedly. The debug session will close; target state is unknown.');
            void this.finishSession(record, true).catch(error => this.error(error));
        });
        const launch = vscode.debug.startDebugging(folder,
            debugConfiguration(settings, elf, record.id, reset, xml) as vscode.DebugConfiguration);
        let launchSettled = false;
        void Promise.resolve(launch).finally(() => { launchSettled = true; }).catch(() => {});
        try {
            const launched = await bounded(launch, settings.startupTimeoutMs, signal);
            if (!launched) throw new Error('cppdbg did not start. See the Debug Console and FROST output.');
            await bounded(record.started.promise, settings.startupTimeoutMs, signal);
            await bounded(record.stopped.promise, settings.startupTimeoutMs, signal);
            if (!daemon.running || record.closing) throw new Error('Debug session ended during startup');
        } catch (error) {
            if (!launchSettled) this.blocked = 'A VS Code debug launch is still pending. Close this window before retrying; owned OpenOCD will be stopped.';
            await this.finishSession(record, true);
            throw error;
        }
    }

    private disconnect(): Promise<void> {
        return this.active ? this.finishSession(this.active, true) : Promise.resolve();
    }

    private finishSession(record: ManagedSession, requestDetach: boolean): Promise<void> {
        return record.closing ??= Promise.resolve().then(async () => {
            try {
                if (requestDetach && record.session) {
                    try {
                        await bounded(record.session.customRequest('disconnect', { terminateDebuggee: false }), 5000);
                        await bounded(record.ended.promise, 5000);
                    } catch (error) {
                        this.output.appendLine(`Graceful detach was not confirmed: ${String(error)}. Reload before relying on breakpoint restoration.`);
                        await bounded(vscode.debug.stopDebugging(record.session), 5000).catch(() => {});
                    }
                }
            } finally {
                await this.hardware.stop(record.daemon);
                if (this.active === record) this.active = undefined;
                await this.clearUnusedSymbols();
                this.output.appendLine('Owned OpenOCD stopped; cable released.');
            }
        });
    }

    private async clearUnusedSymbols(): Promise<void> {
        for (const file of this.symbolCopies) {
            if (file === this.active?.symbols) continue;
            await fs.rm(file, { force: true }).catch(error => this.output.appendLine(`Symbol-copy cleanup: ${String(error)}`));
            this.symbolCopies.delete(file);
        }
    }

    async dispose(): Promise<void> {
        this.closing = true;
        this.abort?.abort(new Error('Extension is closing'));
        await this.operation;
        await this.disconnect();
        await this.hardware.cleanup();
        await this.clearUnusedSymbols();
    }
}

export function activate(context: vscode.ExtensionContext): void {
    controller = new Controller(context);
}

export async function deactivate(): Promise<void> {
    await controller?.dispose();
}
