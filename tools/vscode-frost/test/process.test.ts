// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { promises as fs } from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test, { TestContext } from 'node:test';
import { OwnedProcess, ownsTcpListener, requireFreePort } from '../src/process';

const fixture = path.join(__dirname, 'fixtures', 'process-child.js');
const isLinux = process.platform === 'linux';

async function isLive(pid: number): Promise<boolean> {
    try {
        const stat = await fs.readFile(`/proc/${pid}/stat`, 'utf8');
        const state = stat.slice(stat.lastIndexOf(')') + 2).split(' ')[0];
        return state !== 'Z';
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
        throw error;
    }
}

async function eventually(check: () => boolean | Promise<boolean>,
    message: string, timeout = 5000): Promise<void> {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
        if (await check()) return;
        await new Promise(resolve => setTimeout(resolve, 30));
    }
    assert.fail(message);
}

function killOwnedGroup(group: number | undefined): void {
    if (group === undefined) return;
    try { process.kill(-group, 'SIGKILL'); }
    catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
    }
}

function tool(t: TestContext, mode: string, ...args: string[]): OwnedProcess {
    const child = new OwnedProcess({
        command: process.execPath, args: [fixture, mode, ...args], cwd: process.cwd(),
    });
    t.after(async () => {
        try { await child.stop(); }
        finally { killOwnedGroup(child.pid); }
    });
    return child;
}

async function temporaryMarker(t: TestContext): Promise<string> {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'frost-process-test-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    return path.join(directory, 'descendant.json');
}

async function markerData(marker: string): Promise<{
    pid: number; parent: number; port: number;
}> {
    return JSON.parse(await fs.readFile(marker, 'utf8'));
}

async function readListener(port: number): Promise<string> {
    return new Promise((resolve, reject) => {
        const socket = net.createConnection({ host: '127.0.0.1', port });
        let output = '';
        socket.setEncoding('utf8');
        socket.setTimeout(2000, () => socket.destroy(new Error('Listener did not reply')));
        socket.on('data', data => { output += data; });
        socket.once('error', reject);
        socket.once('end', () => resolve(output));
    });
}

test('missing executable reports ENOENT and completes its owner', { skip: !isLinux }, async t => {
    const child = new OwnedProcess({
        command: `/nonexistent/frost-test-${process.pid}`, args: [], cwd: process.cwd(),
    });
    t.after(() => child.stop());
    await assert.rejects(child.spawned, /ENOENT/);
    await assert.rejects(child.ready(() => true, 3000), /ENOENT/);
    assert.match((await child.exited).error ?? '', /ENOENT/);
    assert.equal(child.running, false);
});

test('a tool exiting before readiness preserves its diagnostic and exit status',
    { skip: !isLinux }, async t => {
        const child = tool(t, 'exit');
        await assert.rejects(child.ready(() => false, 5000), /tool initialization failed/);
        assert.equal((await child.exited).code, 17);
        assert.equal(child.running, false);
    });

test('readiness matches output split across pipe writes', { skip: !isLinux }, async t => {
    const child = tool(t, 'split-ready');
    await child.ready(log => /Listening on port 12345\n/.test(log), 5000);
    assert.equal(child.running, true);
    assert.match(child.log, /fixture: Listening on port 12345\n/);
    await child.stop();
    assert.equal(await isLive(child.pid!), false);
});

test('readiness timeout terminates a tool that never becomes ready',
    { skip: !isLinux }, async t => {
        const child = tool(t, 'hang');
        const pid = await child.spawned;
        await assert.rejects(child.ready(() => false, 150), /startup timed out/);
        assert.equal(await isLive(pid), false);
    });

test('readiness rejects a predicate that reports success after its deadline',
    { skip: !isLinux, timeout: 5000 }, async t => {
        const child = tool(t, 'hang');
        await child.ready(log => log.includes('STARTED'), 5000);
        await assert.rejects(child.ready(async () => {
            await new Promise(resolve => setTimeout(resolve, 300));
            return true;
        }, 50), /timed out/i);
        assert.equal(await isLive(child.pid!), false);
    });

test('readiness timeout also bounds a predicate that never settles',
    { skip: !isLinux, timeout: 5000 }, async t => {
        const child = tool(t, 'hang');
        await child.ready(log => log.includes('STARTED'), 5000);
        await assert.rejects(child.ready(() => new Promise<boolean>(() => {}), 100),
            /timed out/i);
        assert.equal(await isLive(child.pid!), false);
    });

test('cancellation interrupts a readiness predicate already awaiting forever',
    { skip: !isLinux, timeout: 5000 }, async t => {
        const child = tool(t, 'hang');
        await child.ready(log => log.includes('STARTED'), 5000);
        const cancellation = new AbortController();
        let markEntered!: () => void;
        const entered = new Promise<void>(resolve => { markEntered = resolve; });
        const pending = child.ready(() => {
            markEntered();
            return new Promise<boolean>(() => {});
        }, 10000, cancellation.signal);
        await entered;
        cancellation.abort(new Error('cancel hung readiness probe'));
        await assert.rejects(pending, /cancel hung readiness probe/);
        assert.equal(await isLive(child.pid!), false);
    });

test('operation timeout terminates a tool that does not exit',
    { skip: !isLinux }, async t => {
        const child = tool(t, 'hang');
        await child.ready(log => log.includes('STARTED'), 5000);
        await assert.rejects(child.wait(150), /Timed out/);
        assert.equal(await isLive(child.pid!), false);
    });

for (const operation of ['ready', 'wait'] as const) {
    test(`cancelling ${operation} cleans up the owned process`, { skip: !isLinux }, async t => {
        const child = tool(t, 'hang');
        await child.ready(log => log.includes('STARTED'), 5000);
        const cancellation = new AbortController();
        const pending = operation === 'ready'
            ? child.ready(() => false, 5000, cancellation.signal)
            : child.wait(5000, cancellation.signal);
        cancellation.abort(new Error('fixture cancellation'));
        await assert.rejects(pending, /fixture cancellation/);
        assert.equal(await isLive(child.pid!), false);
    });
}

test('an occupied port and unrelated listener remain untouched',
    { skip: !isLinux }, async t => {
        const external = net.createServer(socket => socket.end('external listener\n'));
        external.listen(0, '127.0.0.1');
        await once(external, 'listening');
        t.after(() => new Promise<void>((resolve, reject) => {
            external.close(error => error ? reject(error) : resolve());
        }));
        const port = (external.address() as net.AddressInfo).port;
        const unrelated = tool(t, 'hang');
        await unrelated.ready(log => log.includes('STARTED'), 5000);
        await assert.rejects(requireFreePort(port), /in use.*owner was left untouched/);
        assert.equal(await ownsTcpListener(port, unrelated.pid!), false);
        assert.equal(await readListener(port), 'external listener\n');
        await unrelated.stop();
        assert.equal(await readListener(port), 'external listener\n');
    });

test('listener readiness verifies the process group that owns its socket',
    { skip: !isLinux }, async t => {
        const child = tool(t, 'listen');
        let port = 0;
        await child.ready(async (log, group) => {
            const match = /LISTENING (\d+)/.exec(log);
            if (!match) return false;
            port = Number(match[1]);
            return ownsTcpListener(port, group);
        }, 5000);
        assert.equal(await readListener(port), 'owned listener\n');
        await child.stop();
        await requireFreePort(port);
    });

test('stop waits for a TERM-resistant descendant after launcher streams close',
    { skip: !isLinux, timeout: 12000 }, async t => {
        const marker = await temporaryMarker(t);
        const child = tool(t, 'tree', marker);
        await child.ready(log => log.includes('TREE_READY'), 5000);
        const descendant = await markerData(marker);
        assert.equal(descendant.parent, child.pid);
        assert.equal(await ownsTcpListener(descendant.port, child.pid!), true);
        assert.equal(await readListener(descendant.port), 'owned descendant\n');
        await child.stop();
        assert.equal(await isLive(child.pid!), false);
        assert.equal(await isLive(descendant.pid), false);
        await requireFreePort(descendant.port);
    });

test('successful launcher exit also cleans a TERM-resistant daemon with ignored stdio',
    { skip: !isLinux, timeout: 12000 }, async t => {
        const marker = await temporaryMarker(t);
        const child = tool(t, 'tree-exit', marker);
        await child.wait(7000);
        const descendant = await markerData(marker);
        assert.equal((await child.exited).code, 0);
        assert.equal(await isLive(descendant.pid), false);
        await requireFreePort(descendant.port);
    });

test('SIGKILL of the extension host closes IPC and reaps its native process group',
    { skip: !isLinux, timeout: 15000 }, async t => {
        const marker = await temporaryMarker(t);
        const host = spawn(process.execPath, [
            path.join(__dirname, 'fixtures', 'owner-host.js'), marker,
        ], { cwd: process.cwd(), stdio: ['ignore', 'pipe', 'pipe'] });
        let output = '';
        let errors = '';
        let group: number | undefined;
        host.stdout.on('data', data => { output += data.toString(); });
        host.stderr.on('data', data => { errors += data.toString(); });
        const hostExit = once(host, 'exit');
        t.after(() => {
            if (host.exitCode === null && host.signalCode === null) host.kill('SIGKILL');
            killOwnedGroup(group);
        });
        await eventually(() => output.includes('\n'),
            `Fixture host did not become ready: ${errors}`);
        const details: {
            host: number; worker: number; group: number; pid: number; port: number;
        } = JSON.parse(output.trim());
        group = details.group;
        assert.equal(details.host, host.pid);
        assert.equal(await isLive(details.worker), true);
        assert.equal(await readListener(details.port), 'owned descendant\n');
        host.kill('SIGKILL');
        await hostExit;
        await eventually(async () => !(await isLive(details.group))
            && !(await isLive(details.pid)) && !(await isLive(details.worker)),
        'Native parent, TERM-resistant grandchild, or owner worker survived host death');
        await requireFreePort(details.port);
    });

test('SIGKILL of the owner worker does not falsely confirm native cleanup',
    { skip: !isLinux, timeout: 10000 }, async t => {
        const childrenPath = `/proc/${process.pid}/task/${process.pid}/children`;
        const before = new Set((await fs.readFile(childrenPath, 'utf8')).trim().split(/\s+/));
        const child = new OwnedProcess({
            command: process.execPath, args: [fixture, 'hang'], cwd: process.cwd(),
        });
        t.after(async () => {
            // The test intentionally kills the cleanup worker. Its tool's PID
            // came from this OwnedProcess, so explicitly reap only that group.
            try { await child.stop(); }
            catch { /* Unconfirmed cleanup is the expected result here. */ }
            finally { killOwnedGroup(child.pid); }
        });
        await child.ready(log => log.includes('STARTED'), 5000);
        const newWorkers = (await fs.readFile(childrenPath, 'utf8')).trim().split(/\s+/)
            .filter(pid => pid && !before.has(pid)).map(Number);
        assert.equal(newWorkers.length, 1, 'Fixture must identify its own cleanup worker');
        process.kill(newWorkers[0], 'SIGKILL');
        const result = await child.exited;
        assert.match(result.error ?? '', /before confirming cleanup/);
        await assert.rejects(child.stop(), /cleanup|owner/i);
        assert.equal(await isLive(child.pid!), true,
            'The worker failure should leave cleanup explicitly unresolved');
    });
