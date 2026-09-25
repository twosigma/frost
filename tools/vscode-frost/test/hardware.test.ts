// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { findHardwareTool, isHardwareTool } from '../src/hardware';

// Command lines as /proc/<pid>/cmdline splits them, with the trailing empty
// field its final NUL leaves.
const TOOLS: Record<string, string[]> = {
    'OpenOCD on PATH': ['openocd', '-f', 'fpga/debug/openocd_x3.cfg', ''],
    // What Vivado's bin/hw_server and bin/loader scripts finally run.
    'Vivado hw_server binary': [
        '/tools/Xilinx/2025.2/Vivado/bin/unwrapped/lnx64.o/hw_server', '-s', 'TCP:127.0.0.1:3121', ''],
    'OpenOCD run by an ld64.so loader': ['/lib64/ld64.so.1', '/opt/openocd/libexec/openocd', ''],
    'OpenOCD run by the dynamic loader (oss-cad-suite)': [
        '/opt/oss-cad-suite/lib/ld-linux-x86-64.so.2', '--inhibit-cache', '--inhibit-rpath', '',
        '--library-path', '/opt/oss-cad-suite/lib', '/opt/oss-cad-suite/libexec/openocd',
        '-c', 'bindto 127.0.0.1', ''],
    'OpenOCD run by the loader with a hwcaps list': [
        '/lib64/ld-linux-x86-64.so.2', '--glibc-hwcaps-prepend', 'x86-64-v3', '/usr/bin/openocd', ''],
    'OpenOCD run by the musl loader after --': [
        '/lib/ld-musl-x86_64.so.1', '--', '/opt/openocd/bin/openocd', ''],
};

const OTHERS: Record<string, string[]> = {
    'a manual page': ['man', 'openocd', ''],
    'a pager on the launcher': ['less', '/tools/Xilinx/2025.2/Vivado/bin/hw_server', ''],
    'a log follower': ['tail', '-f', '/tmp/openocd', ''],
    'a search': ['grep', '-r', 'hw_server', 'fpga', ''],
    'an editor on a configuration': ['vim', 'fpga/debug/openocd_x3.cfg', ''],
    'a shell running a command string': ['/bin/bash', '-c', 'man openocd', ''],
    'a command string that follows a log': ['/bin/sh', '-c', 'tail -f /tmp/openocd', ''],
    'a command string that pages the launcher': [
        '/bin/bash', '-c', 'less /tools/Xilinx/2025.2/Vivado/bin/hw_server', ''],
    'a login shell running a command string': [
        '/bin/bash', '-lc', 'journalctl -f _EXE=/usr/bin/openocd', ''],
    'a command string with tcsh options': ['/bin/tcsh', '-fc', 'tail -f /var/log/openocd', ''],
    'a shell reading standard input': ['/bin/bash', '-s', '/tmp/openocd', ''],
    'a command string whose $0 is openocd': ['/bin/bash', '-c', 'sleep 30; :', 'openocd', ''],
    'a command string given a log path': [
        '/bin/bash', '-c', 'while :; do tail -n 1 "$1"; sleep 60; done', 'monitor', '/tmp/openocd', ''],
    'a script given a log path': ['/bin/bash', '/opt/scripts/rotate-logs.sh', '/tmp/openocd', ''],
    'a configure script for an OpenOCD build': ['/bin/sh', './configure', '--prefix=/opt/openocd', ''],
    'ldd on OpenOCD': ['/bin/bash', '/usr/bin/ldd', '/usr/bin/openocd', ''],
    'the loader listing OpenOCD\'s libraries': [
        '/lib64/ld-linux-x86-64.so.2', '--list', '/usr/bin/openocd', ''],
    'the loader printing diagnostics': [
        '/lib64/ld-linux-x86-64.so.2', '--list-diagnostics', '/usr/bin/openocd', ''],
    'the loader running another program': [
        '/lib64/ld-linux-x86-64.so.2', '/usr/bin/tail', '-f', '/tmp/openocd', ''],
    'the loader running another program with a hwcaps list': [
        '/lib64/ld-linux-x86-64.so.2', '--glibc-hwcaps-prepend', 'openocd', '/usr/bin/python3', ''],
    'oss-cad-suite\'s gdb given OpenOCD': [
        '/opt/oss-cad-suite/lib/ld-linux-x86-64.so.2', '--inhibit-cache', '--inhibit-rpath', '',
        '--library-path', '/opt/oss-cad-suite/lib', '/opt/oss-cad-suite/libexec/gdb',
        '/opt/oss-cad-suite/libexec/openocd', ''],
    // Launchers whose tool runs as a process of its own, which is what counts.
    'Vivado hw_server launcher script': [
        '/bin/bash', '/tools/Xilinx/2025.2/Vivado/bin/hw_server', '-s', 'TCP:127.0.0.1:3121', ''],
    'Vivado loader script starting hw_server': [
        '/bin/bash', '/tools/Xilinx/2025.2/Vivado/bin/loader', '-exec', 'hw_server', '-p0', ''],
    'oss-cad-suite launcher before it execs the loader': [
        'bash', '/opt/oss-cad-suite/bin/openocd', '-f', 'fpga/debug/openocd_x3.cfg', ''],
    'Vivado itself': ['/bin/bash', '/tools/Xilinx/2025.2/Vivado/bin/vivado', '-mode', 'batch', ''],
    'the linker': ['ld', '-o', 'openocd', 'main.o', ''],
    'a login shell': ['-bash', ''],
    'a kernel thread': [''],
};

test('OpenOCD and hw_server count as hardware tools, directly or under the dynamic loader', () => {
    for (const [name, argv] of Object.entries(TOOLS)) {
        assert.equal(isHardwareTool(argv), true, name);
    }
});

test('programs that only name OpenOCD or hw_server in their arguments do not count', () => {
    for (const [name, argv] of Object.entries(OTHERS)) {
        assert.equal(isHardwareTool(argv), false, name);
    }
});

test('the process scan finds a hardware tool among unrelated processes', async t => {
    const proc = await fs.mkdtemp(path.join(os.tmpdir(), 'frost-proc-test-'));
    t.after(() => fs.rm(proc, { recursive: true, force: true }));
    const add = async (pid: string, argv: string[] | undefined) => {
        await fs.mkdir(path.join(proc, pid));
        if (argv) await fs.writeFile(path.join(proc, pid, 'cmdline'), argv.join('\0'));
    };
    await add('101', OTHERS['a manual page']);
    await add('102', OTHERS['a pager on the launcher']);
    await add('103', undefined); // exited between the listing and the read
    await add('self', TOOLS['OpenOCD on PATH']); // not a PID
    // A Vivado session's launcher scripts, before they start the binary.
    await add('104', OTHERS['Vivado hw_server launcher script']);
    await add('105', OTHERS['Vivado loader script starting hw_server']);
    assert.equal(await findHardwareTool(proc), undefined);
    await add('106', TOOLS['Vivado hw_server binary']);
    assert.equal(await findHardwareTool(proc), '106');
});
