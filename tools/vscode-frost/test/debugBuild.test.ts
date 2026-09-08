// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import type { FrostSettings } from '../src/settings';
import { assertSameImages, imageDigests, loadArguments, parseDebugBuild } from '../src/hardware';
import { debugConfiguration } from '../src/debugConfiguration';

const settings: FrostSettings = {
    repoRoot: '/fixture/repo', app: 'coremark_pro_loops', memory: 'bram', cpuClockHz: 150000000,
    coremarkMode: 'validation', pythonPath: 'python3', gdbPath: 'gdb', openocdPath: 'openocd',
    vivadoPath: '/tools/Vivado', hwServerPath: '/tools/hw_server', jtagSerial: 'FIXTURE',
    vivadoTarget: '127.0.0.1:3121/xilinx_tcf/Xilinx/FIXTURE', elf: '', bitstream: '',
    startupTimeoutMs: 1000, toolTimeoutMs: 2000, registerDescription: 'core',
};
const description = {
    app: settings.app, appDirectory: '/fixture/repo/sw/apps/coremark_pro',
    elf: '/fixture/repo/sw/apps/coremark_pro/sw.elf', effectiveMemory: 'bram',
    startStrategy: 'attach', buildConfigSha256: 'a'.repeat(64),
};
const record = (value: unknown) => `FROST_DEBUG_BUILD=${JSON.stringify(value)}\n`;

test('build descriptor resolves a benchmark alias and can require current-PC attach in a default layout', () => {
    assert.deepEqual(parseDebugBuild(`compiler output\n${record(description)}FROST_BUILD_COMPLETE\n`, settings, 'coremark_pro'), description);
    const config = debugConfiguration(settings, description.elf, 'fixture', 'attach');
    assert.equal(config.launchCompleteCommand, 'None');
    assert.deepEqual(config.postRemoteConnectCommands, []);
});

test('absent, ambiguous, cross-app and unsafe startup descriptions cannot authorize a load', () => {
    for (const output of [
        'old loader output', record(description) + record(description), 'FROST_DEBUG_BUILD={\n',
        record({ ...description, app: 'hello_world' }),
        record({ ...description, appDirectory: '/other/repo/sw/apps/coremark_pro' }),
        record({ ...description, elf: '/fixture/repo/sw/apps/coremark_pro/other.elf' }),
        record({ ...description, effectiveMemory: 'ddr', startStrategy: 'main' }),
        record({ ...description, effectiveMemory: ['ddr'], startStrategy: 'main' }),
        record({ ...description, startStrategy: ['main'] }),
        record({ ...description, startStrategy: 'continue' }),
        record({ ...description, buildConfigSha256: 'not-a-hash' }),
    ]) assert.throws(() => parseDebugBuild(output, settings, 'coremark_pro'));
    assert.throws(() => parseDebugBuild(record(description), settings, '../coremark_pro'));
});

test('assembly startup verifies reset PC zero without inventing a main breakpoint or continuing', () => {
    const config = debugConfiguration({ ...settings, app: 'c_ext_test' }, '/fixture/app.elf', 'fixture', 'reset');
    assert.equal(config.stopAtConnect, true);
    assert.equal(config.launchCompleteCommand, 'None');
    const commands = config.postRemoteConnectCommands as { text: string; ignoreFailures: boolean }[];
    assert.ok(commands.some(command => command.text === 'monitor reset halt'));
    assert.ok(commands.some(command => command.text.includes('FROST reset did not stop at PC zero')));
    assert.ok(commands.every(command => !command.ignoreFailures && !command.text.includes('tbreak')));
});

test('benchmark build and prebuilt load preserve the same mode, with the config hash checked on load', () => {
    for (const [mode, flag] of [['validation', '-v1'], ['performance', '-v0']] as const) {
        const target = { ...settings, coremarkMode: mode };
        const build = loadArguments(target, true);
        const load = loadArguments(target, false, description.buildConfigSha256);
        for (const args of [build, load]) {
            assert.ok(args.includes('--debug'));
            assert.ok(args.includes(flag));
            assert.equal(args[2], settings.app);
        }
        assert.ok(!build.includes('--expected-build-config-sha256'));
        assert.equal(load[load.indexOf('--expected-build-config-sha256') + 1], description.buildConfigSha256);
    }
});

test('a different shared benchmark build configuration invalidates the load even if image bytes stayed identical', async t => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'frost-build-digest-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    for (const name of ['sw.elf', 'sw.txt', 'sw_ddr.txt']) await fs.writeFile(path.join(directory, name), 'unchanged fixture');
    const stamp = path.join(directory, '.frost-build-config.bin');
    await fs.writeFile(stamp, 'WORKLOAD=loops|FROST_DEBUG=1|');
    const before = await imageDigests(directory);
    await fs.writeFile(stamp, 'WORKLOAD=zip|FROST_DEBUG=1|');
    const after = await imageDigests(directory);
    assert.equal(before.get('sw.elf'), after.get('sw.elf'));
    assert.throws(() => assertSameImages(before, after), /changed during loading/);
});
