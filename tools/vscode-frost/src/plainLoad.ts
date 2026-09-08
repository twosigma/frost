// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import path from 'node:path';
import type * as vscode from 'vscode';
import type { FrostSettings } from './settings';
import { OwnedProcess } from './process';

const MARKER = 'FROST_REPOSITORY_METADATA=';
const MAX_METADATA_OUTPUT = 65536;

export interface RepositoryMetadata {
    apps: string[];
    defaultSerial: string;
    coremarkProApps: string[];
    ddrApps: string[];
    hasDdr: boolean;
    debugApps: string[];
    debugUnsupported: Record<string, string>;
    appBuildDirectories: Record<string, string>;
}

export interface PlainLoadSelection {
    app: string;
    memory: 'bram' | 'ddr';
    cpuClockHz: number;
    coremarkMode?: 'performance' | 'validation';
}

type MetadataSettings = Pick<FrostSettings, 'repoRoot' | 'pythonPath' | 'startupTimeoutMs'>;
type PickerSettings = Pick<FrostSettings, 'app' | 'memory' | 'cpuClockHz'>
    & Pick<PlainLoadSelection, 'coremarkMode'>;

function applicationNames(value: unknown, key: string): string[] {
    if (!Array.isArray(value) || value.length > 1024 ||
        value.some(app => typeof app !== 'string' || app.length > 128 || !/^[a-z][a-z0-9_]*$/.test(app)) ||
        new Set(value).size !== value.length) {
        throw new Error(`Repository metadata ${key} must contain unique application names.`);
    }
    return value;
}

function appStrings(value: unknown, key: string, apps: string[]): Record<string, string> {
    if (!value || typeof value !== 'object' || Array.isArray(value)
        || Object.entries(value).some(([app, text]) => !apps.includes(app)
            || typeof text !== 'string' || !text.trim() || text.length > 4096 || /[\0\r\n]/.test(text))) {
        throw new Error(`Repository metadata ${key} must map accepted applications to nonempty strings.`);
    }
    return value as Record<string, string>;
}

export function parseRepositoryMetadata(output: string): RepositoryMetadata {
    if (output.length > MAX_METADATA_OUTPUT) throw new Error('Repository metadata output is too large.');
    const records = output.split(/\r?\n/).filter(line => line.startsWith(MARKER));
    if (records.length !== 1) throw new Error('Repository metadata did not return exactly one JSON record.');
    let value: unknown;
    try { value = JSON.parse(records[0].slice(MARKER.length)); }
    catch { throw new Error('Repository metadata returned invalid JSON.'); }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Repository metadata must be an object.');
    const record = value as Record<string, unknown>;
    const apps = applicationNames(record.apps, 'apps');
    if (!apps.length) throw new Error('Repository metadata contains no loader applications.');
    const coremarkProApps = applicationNames(record.coremarkProApps, 'coremarkProApps');
    const ddrApps = applicationNames(record.ddrApps, 'ddrApps');
    if ([...coremarkProApps, ...ddrApps].some(app => !apps.includes(app))) {
        throw new Error('Repository metadata references an application the loader does not accept.');
    }
    if (typeof record.defaultSerial !== 'string' || !record.defaultSerial ||
        record.defaultSerial.length > 4096 || /[\0\r\n]/.test(record.defaultSerial)) {
        throw new Error('Repository metadata must provide the X3 UART device default.');
    }
    if (typeof record.hasDdr !== 'boolean') throw new Error('Repository metadata must declare X3 DDR support.');
    const debugApps = applicationNames(record.debugApps, 'debugApps');
    const debugUnsupported = appStrings(record.debugUnsupported, 'debugUnsupported', apps);
    if (debugApps.some(app => !apps.includes(app) || Object.hasOwn(debugUnsupported, app))
        || debugApps.length + Object.keys(debugUnsupported).length !== apps.length) {
        throw new Error('Repository debug eligibility must partition every loader application.');
    }
    const appBuildDirectories = appStrings(record.appBuildDirectories, 'appBuildDirectories', apps);
    if (Object.keys(appBuildDirectories).length !== apps.length
        || Object.values(appBuildDirectories).some(directory => directory.length > 128 || !/^[a-z][a-z0-9_]*$/.test(directory))) {
        throw new Error('Repository build directories must provide a safe basename for every application.');
    }
    return { apps, coremarkProApps, ddrApps, defaultSerial: record.defaultSerial, hasDdr: record.hasDdr,
        debugApps, debugUnsupported, appBuildDirectories };
}

export async function readRepositoryMetadata(settings: MetadataSettings, signal?: AbortSignal): Promise<RepositoryMetadata> {
    signal?.throwIfAborted();
    const helper = path.resolve(__dirname, '../../resources/repo_metadata.py');
    let output = '';
    let oversized = false;
    const child = new OwnedProcess({
        command: settings.pythonPath, args: ['-B', helper, settings.repoRoot], cwd: settings.repoRoot,
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' },
        output: text => {
            if (output.length + text.length > MAX_METADATA_OUTPUT) oversized = true;
            output = (output + text).slice(-MAX_METADATA_OUTPUT);
        },
    });
    await child.wait(settings.startupTimeoutMs, signal);
    if (oversized) throw new Error('Repository metadata output is too large.');
    return parseRepositoryMetadata(output);
}

export function validatePlainLoadSelection(selection: PlainLoadSelection, metadata: RepositoryMetadata): void {
    if (!metadata.apps.includes(selection.app)) throw new Error('Select an application accepted by the repository loader.');
    if (selection.memory !== 'bram' && selection.memory !== 'ddr') throw new Error('Select the default app layout or DDR relocation.');
    if ((selection.memory === 'ddr' || metadata.ddrApps.includes(selection.app)) && !metadata.hasDdr) {
        throw new Error('This application or placement requires board DDR support.');
    }
    if (!Number.isSafeInteger(selection.cpuClockHz) || selection.cpuClockHz <= 0) throw new Error('Enter the actual positive CPU clock in Hz.');
    if (metadata.coremarkProApps.includes(selection.app)) {
        if (selection.coremarkMode !== 'performance' && selection.coremarkMode !== 'validation') {
            throw new Error('CoreMark-PRO requires a performance or validation run mode.');
        }
    } else if (selection.coremarkMode !== undefined) throw new Error('CoreMark-PRO mode is only valid for its registered workloads.');
}

export function validateDebugTarget(selection: PlainLoadSelection, metadata: RepositoryMetadata): void {
    if (!metadata.debugApps.includes(selection.app)) {
        throw new Error(`${selection.app} is unavailable for managed debugging: `
            + (metadata.debugUnsupported[selection.app] ?? 'Select a debug-capable application from this repository.')
            + ' Use FROST: Load Software for supported loading workflows.');
    }
    validatePlainLoadSelection(selection, metadata);
}

export interface PlainLoadUi {
    showQuickPick<T extends vscode.QuickPickItem>(items: readonly T[], options: vscode.QuickPickOptions,
        token?: vscode.CancellationToken): Thenable<T | undefined>;
    showInputBox(options: vscode.InputBoxOptions, token?: vscode.CancellationToken): Thenable<string | undefined>;
}

// Use the public cancellation contract without importing VS Code at runtime
// when callers supply a test UI. Cancelling closes the visible prompt and also
// releases its caller even if the UI's completion callback is delayed.
async function prompt<T>(signal: AbortSignal | undefined,
    show: (token?: vscode.CancellationToken) => Thenable<T>): Promise<T> {
    signal?.throwIfAborted();
    if (!signal) return show();
    const listeners = new Set<() => void>();
    let reject!: (error: unknown) => void;
    const cancelled = new Promise<never>((_resolve, no) => { reject = no; });
    void cancelled.catch(() => {});
    const token: vscode.CancellationToken = {
        get isCancellationRequested() { return signal.aborted; },
        onCancellationRequested: (listener, thisArgs, disposables) => {
            const callback = () => listener.call(thisArgs, undefined);
            listeners.add(callback);
            const disposable = { dispose: () => { listeners.delete(callback); } };
            disposables?.push(disposable);
            return disposable;
        },
    };
    const abort = () => {
        // Settle cancellation before notifying the UI: its callback may resolve
        // the prompt synchronously, but an aborted operation must not advance.
        reject(signal.reason ?? new Error('Software selection cancelled'));
        for (const listener of listeners) listener();
    };
    signal.addEventListener('abort', abort, { once: true });
    try { return await Promise.race([cancelled, show(token)]); }
    finally { signal.removeEventListener('abort', abort); listeners.clear(); }
}

export async function pickPlainLoad(settings: PickerSettings, metadata: RepositoryMetadata,
    suppliedUi?: PlainLoadUi, signal?: AbortSignal): Promise<PlainLoadSelection | undefined> {
    return pickApplication(settings, metadata, false, suppliedUi, signal);
}

export async function pickDebugTarget(settings: PickerSettings, metadata: RepositoryMetadata,
    suppliedUi?: PlainLoadUi, signal?: AbortSignal): Promise<PlainLoadSelection | undefined> {
    return pickApplication(settings, metadata, true, suppliedUi, signal);
}

async function pickApplication(settings: PickerSettings, metadata: RepositoryMetadata, debug: boolean,
    suppliedUi?: PlainLoadUi, signal?: AbortSignal): Promise<PlainLoadSelection | undefined> {
    signal?.throwIfAborted();
    const ui = suppliedUi ?? (await import('vscode')).window;
    const apps = metadata.apps.map(value => ({ value, label: value,
        description: debug && !metadata.debugApps.includes(value) ? 'Load only'
            : metadata.ddrApps.includes(value) ? 'Uses DDR in its application layout' : undefined,
        detail: debug && metadata.debugUnsupported[value] ? metadata.debugUnsupported[value]
            : value === 'linux_boot' ? 'Linux cold builds can take 30–60 minutes; allow enough time in the load timeout setting.' : undefined,
    }));
    apps.sort((a, b) => Number(b.value === settings.app) - Number(a.value === settings.app));
    const app = await prompt(signal, token => ui.showQuickPick(apps, {
        title: debug ? 'FROST: Debug Target' : 'FROST: Load Software',
        placeHolder: debug ? 'Debug-capable applications and unsupported workflows' : 'Application accepted by the repository loader',
        ignoreFocusOut: true,
    }, token));
    if (!app) return undefined;
    // QuickPick has no public disabled-row flag. Keep unavailable workflows
    // visible with their reason, but reject them before any further prompts.
    if (debug && !metadata.debugApps.includes(app.value)) {
        validateDebugTarget({ app: app.value, memory: settings.memory, cpuClockHz: settings.cpuClockHz }, metadata);
    }
    const memories: { value: 'bram' | 'ddr'; label: string; description: string }[] = [
        { value: 'bram', label: 'BRAM / default application layout', description: 'No --ddr flag; applications can still contain DDR code or data' },
        ...(metadata.hasDdr ? [{ value: 'ddr' as const, label: 'DDR relocation', description: 'Pass --ddr; fixed-layout applications retain their own placement' }] : []),
    ];
    memories.sort((a, b) => Number(b.value === settings.memory) - Number(a.value === settings.memory));
    const memory = await prompt(signal, token => ui.showQuickPick(memories, { title: 'FROST: Software placement', ignoreFocusOut: true }, token));
    if (!memory) return undefined;
    const clock = await prompt(signal, token => ui.showInputBox({ title: 'FROST: CPU clock',
        prompt: 'Actual CPU clock of the programmed bitstream, in Hz',
        value: settings.cpuClockHz > 0 ? String(settings.cpuClockHz) : '', ignoreFocusOut: true,
        validateInput: value => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? undefined : 'Enter a positive integer clock in Hz.',
    }, token));
    if (clock === undefined) return undefined;
    let coremarkMode: PlainLoadSelection['coremarkMode'];
    if (metadata.coremarkProApps.includes(app.value)) {
        const modes = [
            { value: 'validation' as const, label: 'Validation (-v1)', description: 'Check official workload results' },
            { value: 'performance' as const, label: 'Performance (-v0)', description: 'Use hardware-sized score iterations' },
        ];
        modes.sort((a, b) => Number(b.value === settings.coremarkMode) - Number(a.value === settings.coremarkMode));
        const mode = await prompt(signal, token => ui.showQuickPick(modes,
            { title: 'FROST: CoreMark-PRO run mode', ignoreFocusOut: true }, token));
        if (!mode) return undefined;
        coremarkMode = mode.value;
    }
    const result: PlainLoadSelection = { app: app.value, memory: memory.value, cpuClockHz: Number(clock),
        ...(coremarkMode ? { coremarkMode } : {}) };
    signal?.throwIfAborted();
    if (debug) validateDebugTarget(result, metadata);
    else validatePlainLoadSelection(result, metadata);
    return result;
}

export function plainLoadArguments(settings: Pick<FrostSettings, 'vivadoTarget' | 'vivadoPath'>, selection: PlainLoadSelection): string[] {
    if (!/^[a-z][a-z0-9_]*$/.test(selection.app)) throw new Error('Invalid loader application name.');
    if (selection.memory !== 'bram' && selection.memory !== 'ddr') throw new Error('Invalid loader memory selection.');
    if (selection.coremarkMode !== undefined && selection.coremarkMode !== 'performance' && selection.coremarkMode !== 'validation') {
        throw new Error('Invalid CoreMark-PRO mode.');
    }
    return ['fpga/load_software/load_software.py', 'x3', selection.app,
        ...(selection.memory === 'ddr' ? ['--ddr'] : []),
        ...(selection.coremarkMode ? [selection.coremarkMode === 'performance' ? '-v0' : '-v1'] : []),
        '--hw-server-url', '127.0.0.1:3121', '--target-exact', settings.vivadoTarget,
        '--non-interactive', '--vivado-path', settings.vivadoPath];
}
