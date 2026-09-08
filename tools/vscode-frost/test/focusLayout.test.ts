// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test, { TestContext } from 'node:test';

type Value = string | boolean | string[];

function harness(t: TestContext) {
    const user = new Map<string, Value>();
    const workspace = new Map<string, Value>();
    const state = new Map<string, unknown>();
    const writes: Array<{ key: string; value: unknown; target: number }> = [];
    const commands = new Map<string, () => Promise<void>>();
    const executed: string[] = [];
    const errors: string[] = [];
    const information: string[] = [];
    let storage = 'file:///fixture/profiles/frost/globalStorage/frost-local.frost';
    let failWrite: ((key: string, value: unknown) => boolean) | undefined;
    let failState = false;
    const vscode = {
        ConfigurationTarget: { Global: 1 },
        Disposable: { from: (...values: Array<{ dispose(): void }>) => ({
            dispose: () => values.forEach(value => value.dispose()),
        }) },
        workspace: { getConfiguration: () => ({
            get: (key: string, fallback: unknown) => workspace.get(key) ?? user.get(key) ?? fallback,
            inspect: (key: string) => ({ globalValue: user.get(key), workspaceValue: workspace.get(key) }),
            update: async (key: string, value: Value | undefined, target: number) => {
                writes.push({ key, value, target });
                if (failWrite?.(key, value)) throw new Error('fixture settings file is read-only');
                if (value === undefined) user.delete(key);
                else user.set(key, value);
            },
        }) },
        commands: {
            registerCommand: (id: string, handler: () => Promise<void>) => {
                commands.set(id, handler);
                return { dispose: () => commands.delete(id) };
            },
            executeCommand: async (id: string) => { executed.push(id); },
        },
        window: {
            showErrorMessage: async (message: string) => { errors.push(message); },
            showInformationMessage: async (message: string) => { information.push(message); },
        },
    };
    const context = {
        globalStorageUri: { toString: () => storage },
        globalState: {
            get: (key: string) => state.get(key),
            update: async (key: string, value: unknown) => {
                if (failState) throw new Error('fixture backup write failed');
                if (value === undefined) state.delete(key);
                else state.set(key, JSON.parse(JSON.stringify(value)));
            },
        },
    };
    const Module = require('node:module');
    const originalLoad = Module._load;
    const modulePath = require.resolve('../src/focusLayout');
    delete require.cache[modulePath];
    Module._load = function (request: string, ...args: unknown[]) {
        return request === 'vscode' ? vscode : originalLoad.call(this, request, ...args);
    };
    let module: typeof import('../src/focusLayout');
    try { module = require(modulePath); }
    finally { Module._load = originalLoad; }
    let disposable = module.registerFocusLayout(context as never);
    t.after(() => { disposable.dispose(); delete require.cache[modulePath]; });
    return {
        user, workspace, state, writes, commands, executed, errors, information,
        settings: module.focusSettings,
        apply: () => commands.get('frost.applyFocusLayout')!(),
        restore: () => commands.get('frost.restoreFocusLayout')!(),
        zen: () => commands.get('frost.toggleFocusZen')!(),
        reload: () => { disposable.dispose(); disposable = module.registerFocusLayout(context as never); },
        setStorage: (value: string) => { storage = value; },
        failWrite: (value: typeof failWrite) => { failWrite = value; },
        failState: () => { failState = true; },
    };
}

test('focus layout is opt-in and restores exact User overrides while retaining workspace preferences', async t => {
    const h = harness(t);
    h.user.set('workbench.activityBar.location', 'top');
    h.user.set('editor.fontSize', '18');
    h.workspace.set('editor.minimap.enabled', true);
    const original = new Map(h.user);
    assert.equal(h.writes.length, 0);
    assert.equal(h.commands.size, 3);
    await h.apply();
    assert.equal(h.user.get('workbench.activityBar.location'), 'hidden');
    assert.equal(h.user.get('editor.minimap.enabled'), false);
    assert.equal(h.workspace.get('editor.minimap.enabled'), true);
    assert.ok(h.writes.every(write => write.target === 1));
    assert.deepEqual(h.executed, []);
    await h.restore();
    assert.deepEqual(h.user, original);
    assert.equal(h.state.size, 0);
    assert.deepEqual(h.errors, []);
});

test('restore preserves later user edits, including deletion, and repeated Apply preserves the original backup', async t => {
    const h = harness(t);
    h.user.set('workbench.statusBar.visible', true);
    await h.apply();
    const writes = h.writes.length;
    h.user.set('workbench.statusBar.visible', false);
    h.user.set('workbench.activityBar.location', 'bottom');
    h.user.delete('editor.minimap.enabled');
    await h.apply();
    assert.equal(h.writes.length, writes);
    h.reload();
    await h.restore();
    assert.equal(h.user.get('workbench.activityBar.location'), 'bottom');
    assert.equal(h.user.get('workbench.statusBar.visible'), true);
    assert.equal(h.user.has('editor.minimap.enabled'), false);
    assert.ok(h.information.at(-1)?.includes('Kept 2'));
});

test('a backup copied into another profile is never applied there', async t => {
    const h = harness(t);
    await h.apply();
    const writes = h.writes.length;
    h.setStorage('file:///fixture/profiles/other/globalStorage/frost-local.frost');
    await h.restore();
    assert.equal(h.writes.length, writes);
    assert.equal(h.state.size, 1);
    assert.match(h.errors.at(-1)!, /another profile/);
});

test('settings shared across profiles block Apply and newly shared settings block Restore without losing the backup', async t => {
    const h = harness(t);
    h.user.set('workbench.settings.applyToAllProfiles', ['editor.minimap.enabled']);
    await h.apply();
    assert.equal(h.writes.length, 0);
    assert.equal(h.state.size, 0);
    h.user.delete('workbench.settings.applyToAllProfiles');
    await h.apply();
    const writes = h.writes.length;
    h.user.set('workbench.settings.applyToAllProfiles', ['zenMode.fullScreen']);
    await h.restore();
    assert.equal(h.writes.length, writes);
    assert.equal(h.state.size, 1);
    h.user.delete('workbench.settings.applyToAllProfiles');
    await h.restore();
    assert.equal(h.state.size, 0);
    assert.equal(h.errors.length, 2);
});

test('an interrupted Apply rolls back completed changes without touching unrelated settings', async t => {
    const h = harness(t);
    h.user.set('editor.fontFamily', 'fixture-font');
    const original = new Map(h.user);
    h.failWrite((key, value) => key === 'editor.minimap.enabled' && value === false);
    await h.apply();
    assert.deepEqual(h.user, original);
    assert.equal(h.state.size, 0);
    assert.match(h.errors.at(-1)!, /read-only/);
});

test('a failed Restore retains the remaining backup and succeeds when retried', async t => {
    const h = harness(t);
    h.user.set('workbench.activityBar.location', 'top');
    await h.apply();
    h.failWrite((key, value) => key === 'workbench.activityBar.location' && value === 'top');
    await h.restore();
    assert.deepEqual([...h.user], [['workbench.activityBar.location', 'hidden']]);
    assert.equal(h.state.size, 1);
    h.reload();
    h.failWrite(undefined);
    await h.restore();
    assert.deepEqual([...h.user], [['workbench.activityBar.location', 'top']]);
    assert.equal(h.state.size, 0);
});

test('no settings change if their backup cannot be persisted', async t => {
    const h = harness(t);
    h.failState();
    await h.apply();
    assert.equal(h.writes.length, 0);
    assert.match(h.errors.at(-1)!, /backup write failed/);
});

test('overlapping Apply and Restore are ordered, and Zen only invokes the public toggle', async t => {
    const h = harness(t);
    await Promise.all([h.apply(), h.restore()]);
    assert.equal(h.user.size, 0);
    assert.equal(h.state.size, 0);
    const writes = h.writes.length;
    await h.zen();
    await h.zen();
    assert.deepEqual(h.executed, ['workbench.action.toggleZenMode', 'workbench.action.toggleZenMode']);
    assert.equal(h.writes.length, writes);
    assert.equal(Object.hasOwn(h.settings, 'chat.disableAIFeatures'), false);
    assert.equal(h.settings['zenMode.silentNotifications'], true);
});

test('the importable profile uses the VS Code settings-resource format and requests only C/C++', t => {
    const h = harness(t);
    const profile = JSON.parse(readFileSync(path.resolve(__dirname, '../../resources/FROST.code-profile'), 'utf8'));
    assert.equal(profile.name, 'FROST Debug');
    assert.deepEqual(JSON.parse(JSON.parse(profile.settings).settings), h.settings);
    assert.deepEqual(JSON.parse(profile.extensions).map((extension: { identifier: { id: string } }) => extension.identifier.id),
        ['ms-vscode.cpptools']);
    assert.equal(profile.globalState, undefined);
});
