// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import test from 'node:test';
import { getEventListeners } from 'node:events';
import type * as vscode from 'vscode';
import { parseRepositoryMetadata, pickDebugTarget, pickPlainLoad, plainLoadArguments,
    validateDebugTarget, validatePlainLoadSelection, PlainLoadUi, RepositoryMetadata } from '../src/plainLoad';

const metadata: RepositoryMetadata = {
    apps: ['hello_world', 'linux_boot', 'uart_echo', 'coremark_pro_fixture'],
    coremarkProApps: ['coremark_pro_fixture'], ddrApps: ['linux_boot', 'coremark_pro_fixture'],
    defaultSerial: '/dev/tty-test', hasDdr: true,
    debugApps: ['hello_world', 'uart_echo', 'coremark_pro_fixture'],
    debugUnsupported: { linux_boot: 'Linux combines firmware, kernel and root filesystem images.' },
    appBuildDirectories: { hello_world: 'hello_world', linux_boot: 'linux_boot', uart_echo: 'uart_echo',
        coremark_pro_fixture: 'coremark_pro' },
};
const settings = { app: 'hello_world' as const, memory: 'bram' as const, cpuClockHz: 150000000 };
const tools = { vivadoTarget: '127.0.0.1:3121/xilinx_tcf/Xilinx/test_target', vivadoPath: '/tools with spaces/vivado' };
const record = (value: unknown) => `FROST_REPOSITORY_METADATA=${JSON.stringify(value)}\n`;

function picker(answers: Array<string | undefined>, clock: string | null = '150000000'): PlainLoadUi {
    return {
        async showQuickPick<T extends vscode.QuickPickItem>(items: readonly T[]): Promise<T | undefined> {
            const answer = answers.shift();
            return items.find(item => (item as T & { value: string }).value === answer);
        },
        async showInputBox() { return clock ?? undefined; },
    };
}

test('metadata accepts loader noise around one validated record', () => {
    assert.deepEqual(parseRepositoryMetadata(`Loader note\n${record(metadata)}stderr note\n`), metadata);
});

test('malformed, ambiguous, oversized or inconsistent metadata fails closed', () => {
    for (const output of [
        'unstructured output', record(metadata) + record(metadata),
        'FROST_REPOSITORY_METADATA={\n', record([]),
        record({ ...metadata, apps: [] }), record({ ...metadata, apps: ['hello_world', 'hello_world'] }),
        record({ ...metadata, apps: ['../outside'] }),
        record({ ...metadata, coremarkProApps: ['unregistered'] }),
        record({ ...metadata, defaultSerial: '/dev/tty-test\nextra' }),
        record({ ...metadata, hasDdr: 'true' }),
        record({ ...metadata, debugApps: undefined }),
        record({ ...metadata, debugApps: ['not_registered'] }),
        record({ ...metadata, debugApps: [...metadata.debugApps, 'linux_boot'] }),
        record({ ...metadata, debugUnsupported: {} }),
        record({ ...metadata, debugUnsupported: { linux_boot: '' } }),
        record({ ...metadata, debugUnsupported: { linux_boot: 'multiline\nreason' } }),
        record({ ...metadata, appBuildDirectories: { hello_world: 'hello_world' } }),
        record({ ...metadata, appBuildDirectories: { ...metadata.appBuildDirectories, uart_echo: '../outside' } }),
        'x'.repeat(65537),
    ]) assert.throws(() => parseRepositoryMetadata(output));
});

test('plain picker accepts non-debug apps and preserves selected DDR placement', async () => {
    const selection = await pickPlainLoad(settings, metadata, picker(['uart_echo', 'ddr']));
    assert.deepEqual(selection, { app: 'uart_echo', memory: 'ddr', cpuClockHz: 150000000 });
    const args = plainLoadArguments(tools, selection!);
    assert.deepEqual(args.slice(0, 4), ['fpga/load_software/load_software.py', 'x3', 'uart_echo', '--ddr']);
    assert.equal(args[args.indexOf('--target-exact') + 1], tools.vivadoTarget);
    assert.equal(args[args.indexOf('--vivado-path') + 1], tools.vivadoPath);
    assert.equal(args[args.indexOf('--hw-server-url') + 1], '127.0.0.1:3121');
    assert.ok(args.includes('--non-interactive'));
    for (const flag of ['--debug', '--skip-build', '--build-only']) assert.ok(!args.includes(flag));
});

test('Linux retains its default app layout without inventing a relocation requirement', async () => {
    const selection = await pickPlainLoad(settings, metadata, picker(['linux_boot', 'bram']));
    assert.equal(selection?.app, 'linux_boot');
    assert.equal(selection?.memory, 'bram');
    assert.ok(!plainLoadArguments(tools, selection!).includes('--ddr'));
    assert.throws(() => validatePlainLoadSelection(selection!, { ...metadata, hasDdr: false }), /DDR support/);
});

test('registered CoreMark-PRO aliases require and preserve explicit CLI run mode', async () => {
    for (const [mode, flag] of [['validation', '-v1'], ['performance', '-v0']] as const) {
        const selection = await pickPlainLoad(settings, metadata, picker(['coremark_pro_fixture', 'bram', mode]));
        assert.equal(selection?.coremarkMode, mode);
        assert.ok(plainLoadArguments(tools, selection!).includes(flag));
    }
    assert.throws(() => validatePlainLoadSelection({ app: 'coremark_pro_fixture', memory: 'bram', cpuClockHz: 1 }, metadata), /run mode/);
    assert.throws(() => validatePlainLoadSelection({ app: 'uart_echo', memory: 'bram', cpuClockHz: 1, coremarkMode: 'validation' }, metadata), /only valid/);
});

test('selection cancellation returns no load request', async () => {
    assert.equal(await pickPlainLoad(settings, metadata, picker([undefined])), undefined);
    assert.equal(await pickPlainLoad(settings, metadata, picker(['uart_echo', undefined])), undefined);
    assert.equal(await pickPlainLoad(settings, metadata, picker(['uart_echo', 'bram'], null)), undefined);
    assert.equal(await pickPlainLoad(settings, metadata, picker(['coremark_pro_fixture', 'bram', undefined])), undefined);
});

test('selection rejects apps outside the registry and nonpositive clocks', () => {
    assert.throws(() => validatePlainLoadSelection({ app: 'not_registered', memory: 'bram', cpuClockHz: 1 }, metadata), /accepted/);
    for (const clock of [0, -1, NaN, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
        assert.throws(() => validatePlainLoadSelection({ app: 'uart_echo', memory: 'bram', cpuClockHz: clock }, metadata), /CPU clock/);
    }
});

test('debug selection uses repository eligibility and mapped aliases beyond the original two apps', async () => {
    const selected = await pickDebugTarget(settings, metadata, picker(['uart_echo', 'ddr']));
    assert.deepEqual(selected, { app: 'uart_echo', memory: 'ddr', cpuClockHz: 150000000 });
    validateDebugTarget(selected!, metadata);
    const alias = await pickDebugTarget(settings, metadata, picker(['coremark_pro_fixture', 'bram', 'validation']));
    assert.equal(alias?.app, 'coremark_pro_fixture');
    assert.equal(metadata.appBuildDirectories[alias!.app], 'coremark_pro');
});

test('debug picker displays every app with its unsupported reason and rejects it before further prompts', async () => {
    let calls = 0;
    const ui: PlainLoadUi = {
        async showQuickPick<T extends vscode.QuickPickItem>(items: readonly T[]): Promise<T | undefined> {
            assert.equal(++calls, 1, 'An unsupported choice must not reach layout or mode selection');
            assert.deepEqual(items.map(item => item.label), metadata.apps);
            const unsupported = items.find(item => item.label === 'linux_boot');
            assert.equal(unsupported?.description, 'Load only');
            assert.equal(unsupported?.detail, metadata.debugUnsupported.linux_boot);
            return unsupported;
        },
        showInputBox: async () => assert.fail('An unsupported choice must not prompt for a clock'),
    };
    await assert.rejects(pickDebugTarget(settings, metadata, ui), /linux_boot.*Linux combines.*Load Software/);
    assert.throws(() => validateDebugTarget({ app: 'linux_boot', memory: 'bram', cpuClockHz: 150000000 }, metadata),
        /Linux combines/);
});

test('a newly advertised debug app becomes selectable without an extension allowlist update', async () => {
    const changed = parseRepositoryMetadata(record({ ...metadata,
        apps: [...metadata.apps, 'new_debug_app'], debugApps: [...metadata.debugApps, 'new_debug_app'],
        appBuildDirectories: { ...metadata.appBuildDirectories, new_debug_app: 'shared_build' },
    }));
    const selected = await pickDebugTarget(settings, changed, picker(['new_debug_app', 'bram']));
    assert.equal(selected?.app, 'new_debug_app');
    assert.equal(changed.appBuildDirectories[selected!.app], 'shared_build');
});

test('both pickers prefer the saved CoreMark-PRO run mode', async () => {
    for (const pick of [pickPlainLoad, pickDebugTarget]) {
        const base = picker(['coremark_pro_fixture', 'bram', 'performance']);
        const ui: PlainLoadUi = {
            async showQuickPick<T extends vscode.QuickPickItem>(items: readonly T[], options: vscode.QuickPickOptions): Promise<T | undefined> {
                if (options.title === 'FROST: CoreMark-PRO run mode') assert.equal(items[0].label, 'Performance (-v0)');
                return base.showQuickPick(items, options);
            },
            showInputBox: base.showInputBox,
        };
        const selected = await pick({ ...settings, coremarkMode: 'performance' }, metadata, ui);
        assert.equal(selected?.coremarkMode, 'performance');
    }
});

for (const pick of [pickPlainLoad, pickDebugTarget]) {
    for (const pendingStep of [1, 2, 3, 4]) {
    test(`cancellation closes ${pick.name} step ${pendingStep} before a delayed UI response`, { timeout: 1000 }, async () => {
        const abort = new AbortController();
        let calls = 0;
        let cancelled = 0;
        let reached!: () => void;
        const pending = new Promise<void>(resolve => { reached = resolve; });
        let finishLate!: () => void;
        function answer<T>(value: T, token?: vscode.CancellationToken): Promise<T | undefined> {
            calls++;
            if (calls !== pendingStep) return Promise.resolve(value);
            assert.ok(token, 'The public UI needs a CancellationToken to dismiss its prompt');
            assert.equal(token.isCancellationRequested, false);
            token.onCancellationRequested(() => {
                assert.equal(token.isCancellationRequested, true);
                cancelled++;
                // Deliberately delay the UI response; cancellation must still
                // release Disconnect/deactivate and prevent the next prompt.
            });
            reached();
            return new Promise(resolve => { finishLate = () => resolve(value); });
        }
        const ui: PlainLoadUi = {
            showQuickPick<T extends vscode.QuickPickItem>(items: readonly T[], _options: vscode.QuickPickOptions,
                token?: vscode.CancellationToken): Promise<T | undefined> {
                const selected = items.find(item => ['coremark_pro_fixture', 'bram', 'validation']
                    .includes((item as T & { value: string }).value))!;
                return answer(selected, token);
            },
            showInputBox: (_options, token) => answer('150000000', token),
        };
        const picking = pick(settings, metadata, ui, abort.signal);
        await pending;
        abort.abort(new Error('fixture selection cancelled'));
        await assert.rejects(picking, /fixture selection cancelled/);
        assert.equal(cancelled, 1);
        assert.equal(calls, pendingStep);
        assert.equal(getEventListeners(abort.signal, 'abort').length, 0);
        finishLate();
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(calls, pendingStep, 'A delayed answer cannot reopen another picker after cancellation');
    });
    }
}

test('an already-cancelled selection does not show a prompt', async () => {
    const abort = new AbortController();
    abort.abort(new Error('fixture cancelled before selection'));
    const ui: PlainLoadUi = {
        showQuickPick: async () => assert.fail('No picker should open after cancellation'),
        showInputBox: async () => assert.fail('No input should open after cancellation'),
    };
    await assert.rejects(pickPlainLoad(settings, metadata, ui, abort.signal), /cancelled before selection/);
    assert.equal(getEventListeners(abort.signal, 'abort').length, 0);
});
