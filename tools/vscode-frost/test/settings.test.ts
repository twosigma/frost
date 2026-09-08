// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import path from 'node:path';
import test, { TestContext } from 'node:test';
import type * as vscode from 'vscode';
import { pickDebugTarget, PlainLoadUi, RepositoryMetadata } from '../src/plainLoad';

function harness(t: TestContext) {
    const user = new Map<string, unknown>([
        ['jtagSerial', 'OLD_SERIAL'], ['vivadoTarget', '127.0.0.1:3121/xilinx_tcf/Xilinx/OLD_TARGET'],
        ['cpuClockHz', 300000000], ['app', 'hello_world'], ['memory', 'bram'],
    ]);
    const writes: Array<{ key: string; value: unknown; target: number }> = [];
    const workspace = new Map<string, unknown>();
    const workspaceFolder = new Map<string, unknown>();
    const messages: string[] = [];
    const metadataRequests: unknown[] = [];
    const inputAnswers: Array<string | undefined> = [];
    const pickerAnswers: Array<string | undefined> = [];
    const control = { metadataError: undefined as Error | undefined };
    const metadata: RepositoryMetadata = {
        apps: ['hello_world', 'coremark_pro_core', 'linux_boot'],
        debugApps: ['hello_world', 'coremark_pro_core'],
        debugUnsupported: { linux_boot: 'Linux requires a composite-image debugger.' },
        appBuildDirectories: { hello_world: 'hello_world', coremark_pro_core: 'coremark_pro', linux_boot: 'linux_boot' },
        coremarkProApps: ['coremark_pro_core'], ddrApps: ['coremark_pro_core', 'linux_boot'],
        hasDdr: true, defaultSerial: '/fixture/uart',
    };
    const config = {
        get: (key: string, fallback: unknown) => workspaceFolder.has(key) ? workspaceFolder.get(key)
            : workspace.has(key) ? workspace.get(key) : user.has(key) ? user.get(key) : fallback,
        inspect: (key: string) => ({ globalValue: user.get(key), workspaceValue: workspace.get(key),
            workspaceFolderValue: workspaceFolder.get(key) }),
        update: async (key: string, value: unknown, target: number) => {
            writes.push({ key, value, target });
            const destination = target === 1 ? user : target === 2 ? workspace : target === 3 ? workspaceFolder : undefined;
            assert.ok(destination, 'Settings writes must use an explicit configuration scope');
            destination.set(key, value);
        },
    };
    const ui: PlainLoadUi = {
        async showQuickPick<T extends vscode.QuickPickItem>(items: readonly T[]): Promise<T | undefined> {
            const answer = pickerAnswers.shift();
            return items.find(item => (item as T & { value: string }).value === answer);
        },
        showInputBox: async () => inputAnswers.shift(),
    };
    const api = {
        ConfigurationTarget: { Global: 1, Workspace: 2, WorkspaceFolder: 3 },
        workspace: { getConfiguration: () => config },
        window: { ...ui, showInformationMessage: async (message: string) => { messages.push(message); } },
    };
    const Module = require('node:module');
    const originalLoad = Module._load;
    const modulePath = require.resolve('../src/settings');
    delete require.cache[modulePath];
    Module._load = function (request: string, parent: NodeModule, ...args: unknown[]) {
        if (request === 'vscode') return api;
        if (parent?.filename === modulePath && request === './plainLoad') return {
            readRepositoryMetadata: async (settings: unknown) => {
                metadataRequests.push(settings);
                if (control.metadataError) throw control.metadataError;
                return metadata;
            },
            pickDebugTarget: (settings: Parameters<typeof pickDebugTarget>[0], repository: RepositoryMetadata) =>
                pickDebugTarget(settings, repository, ui),
        };
        return originalLoad.call(this, request, parent, ...args);
    };
    let settings: typeof import('../src/settings');
    try { settings = require(modulePath); }
    finally { Module._load = originalLoad; }
    t.after(() => { delete require.cache[modulePath]; });
    const folder = { name: 'fixture', index: 0, uri: { fsPath: '/fixture/workspace/repo' } } as vscode.WorkspaceFolder;
    return { settings, folder, user, workspace, workspaceFolder,
        writes, messages, metadataRequests, inputAnswers, pickerAnswers, control };
}

test('settings accept application names beyond the original two-app enum', t => {
    const h = harness(t);
    for (const app of ['coremark', 'coremark_pro_core', 'freertos_demo', 'new_repository_app17']) {
        h.user.set('app', app);
        assert.equal(h.settings.getSettings(h.folder).app, app);
    }
    assert.deepEqual(h.metadataRequests, [], 'Registry eligibility is checked by commands, not by reading settings');
});

test('application settings reject paths and malformed names before deriving an ELF path', t => {
    const h = harness(t);
    for (const app of ['../outside', '/tmp/app', 'app/sw.elf', 'two names', 'bad\nname', 'app;command', 42]) {
        h.user.set('app', app);
        assert.throws(() => h.settings.getSettings(h.folder), /frost\.app/);
    }
});

test('ELF settings distinguish explicit overrides from defaults awaiting registry alias resolution', t => {
    const h = harness(t);
    h.user.set('app', 'coremark_pro_core');
    h.user.set('repoRoot', '../selected-repo');
    const defaults = h.settings.getSettings(h.folder);
    assert.equal(defaults.elfExplicit, false);
    assert.equal(defaults.elf, '/fixture/workspace/selected-repo/sw/apps/coremark_pro_core/sw.elf');
    // The controller uses elfExplicit=false to replace the display-name path
    // with metadata.appBuildDirectories; an explicit override must survive.
    h.user.set('elf', 'images/exact-loaded-image.elf');
    const explicit = h.settings.getSettings(h.folder);
    assert.equal(explicit.elfExplicit, true);
    assert.equal(explicit.elf, path.join(explicit.repoRoot, 'images/exact-loaded-image.elf'));
    h.user.set('elf', '');
    assert.equal(h.settings.getSettings(h.folder).elfExplicit, false);
});

for (const cancelledPrompt of ['application', 'clock'] as const) {
    test(`cancelling Configure Target at its shared ${cancelledPrompt} picker saves no identities or selection`, async t => {
        const h = harness(t);
        const before = new Map(h.user);
        h.inputAnswers.push('NEW_SERIAL', '127.0.0.1:3121/xilinx_tcf/Xilinx/NEW_TARGET');
        if (cancelledPrompt === 'clock') {
            h.pickerAnswers.push('coremark_pro_core', 'ddr');
            h.inputAnswers.push(undefined);
        } else h.pickerAnswers.push(undefined);
        assert.equal(await h.settings.configureTarget(h.folder), false);
        assert.deepEqual(h.user, before);
        assert.deepEqual(h.writes, []);
        assert.deepEqual(h.messages, []);
        assert.equal(h.metadataRequests.length, 1);
    });
}

test('Configure Target stores the completed shared CoreMark-PRO selection and trimmed cable identities', async t => {
    const h = harness(t);
    h.user.set('elf', 'images/explicit.elf');
    h.inputAnswers.push(' NEW_SERIAL ', ' 127.0.0.1:3121/xilinx_tcf/Xilinx/NEW_TARGET ', '150000000');
    h.pickerAnswers.push('coremark_pro_core', 'ddr', 'performance');
    assert.equal(await h.settings.configureTarget(h.folder), true);
    assert.deepEqual(Object.fromEntries(h.writes.map(write => [write.key, write.value])), {
        jtagSerial: 'NEW_SERIAL', vivadoTarget: '127.0.0.1:3121/xilinx_tcf/Xilinx/NEW_TARGET',
        app: 'coremark_pro_core', memory: 'ddr', cpuClockHz: 150000000, coremarkProMode: 'performance',
    });
    assert.ok(h.writes.every(write => write.target === 1));
    assert.equal(h.user.get('elf'), 'images/explicit.elf');
    assert.equal(h.settings.getSettings(h.folder).coremarkMode, 'performance');
    assert.equal(h.messages.length, 1);
});

test('saving a debug selection updates only selection preferences and preserves cable and ELF choices', async t => {
    const h = harness(t);
    h.user.set('elf', 'images/explicit.elf');
    await h.settings.saveDebugSelection(h.folder, {
        app: 'coremark_pro_core', memory: 'bram', cpuClockHz: 150000000, coremarkMode: 'validation',
    });
    assert.deepEqual(h.writes.map(write => write.key), ['app', 'memory', 'cpuClockHz', 'coremarkProMode']);
    assert.ok(h.writes.every(write => write.target === 1));
    assert.equal(h.user.get('jtagSerial'), 'OLD_SERIAL');
    assert.equal(h.user.get('vivadoTarget'), '127.0.0.1:3121/xilinx_tcf/Xilinx/OLD_TARGET');
    assert.equal(h.user.get('elf'), 'images/explicit.elf');
    const current = h.settings.getSettings(h.folder);
    assert.equal(current.app, 'coremark_pro_core');
    assert.equal(current.coremarkMode, 'validation');
    assert.equal(current.cpuClockHz, 150000000);
});

test('Configure Target metadata failure leaves existing settings untouched', async t => {
    const h = harness(t);
    const before = new Map(h.user);
    h.inputAnswers.push('NEW_SERIAL', '127.0.0.1:3121/xilinx_tcf/Xilinx/NEW_TARGET');
    h.control.metadataError = new Error('fixture repository metadata failed');
    await assert.rejects(h.settings.configureTarget(h.folder), /repository metadata failed/);
    assert.deepEqual(h.user, before);
    assert.deepEqual(h.writes, []);
});

for (const scope of ['workspace', 'folder'] as const) {
    test(`saving a selection replaces existing ${scope} app and clock overrides for subsequent operations`, async t => {
        const h = harness(t);
        h.workspace.set('app', 'hello_world');
        h.workspace.set('memory', 'bram');
        h.workspace.set('cpuClockHz', 300000000);
        h.workspace.set('coremarkProMode', 'validation');
        if (scope === 'folder') {
            for (const [key, value] of h.workspace) h.workspaceFolder.set(key, value);
        }
        await h.settings.saveDebugSelection(h.folder, {
            app: 'coremark_pro_core', memory: 'ddr', cpuClockHz: 150000000, coremarkMode: 'performance',
        });
        assert.ok(h.writes.every(write => write.target === (scope === 'folder' ? 3 : 2)));
        const selected = h.settings.getSettings(h.folder);
        assert.equal(selected.app, 'coremark_pro_core');
        assert.equal(selected.memory, 'ddr');
        assert.equal(selected.cpuClockHz, 150000000, 'Subsequent reset waits must use the selected FPGA clock');
        assert.equal(selected.coremarkMode, 'performance');
        assert.equal(h.user.get('app'), 'hello_world');
        assert.equal(h.user.get('cpuClockHz'), 300000000);
        if (scope === 'folder') assert.equal(h.workspace.get('app'), 'hello_world');
    });
}

test('Configure Target respects each selection override scope while saving cable identities only to User settings', async t => {
    const h = harness(t);
    h.workspace.set('app', 'hello_world');
    h.workspaceFolder.set('app', 'hello_world');
    h.workspace.set('memory', 'bram');
    h.workspace.set('cpuClockHz', 300000000);
    h.workspaceFolder.set('coremarkProMode', 'validation');
    h.inputAnswers.push('NEW_SERIAL', '127.0.0.1:3121/xilinx_tcf/Xilinx/NEW_TARGET', '150000000');
    h.pickerAnswers.push('coremark_pro_core', 'ddr', 'performance');
    assert.equal(await h.settings.configureTarget(h.folder), true);
    assert.deepEqual(Object.fromEntries(h.writes.map(write => [write.key, write.target])), {
        jtagSerial: 1, vivadoTarget: 1, cpuClockHz: 2, app: 3, memory: 2, coremarkProMode: 3,
    });
    const selected = h.settings.getSettings(h.folder);
    assert.equal(selected.app, 'coremark_pro_core');
    assert.equal(selected.cpuClockHz, 150000000);
    assert.equal(selected.jtagSerial, 'NEW_SERIAL');
    assert.equal(selected.vivadoTarget, '127.0.0.1:3121/xilinx_tcf/Xilinx/NEW_TARGET');
});
