// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { OwnedProcess } from '../../src/process';

// This process stands in for VS Code's extension host. The test kills it with
// SIGKILL, so graceful shutdown handlers cannot make the test pass.
async function main(): Promise<void> {
    const marker = process.argv[2];
    const child = new OwnedProcess({
        command: process.execPath,
        args: [path.join(__dirname, 'process-child.js'), 'tree', marker],
        cwd: process.cwd(),
    });
    await child.ready(log => log.includes('TREE_READY'), 5000);
    const descendants: { pid: number; parent: number; port: number } =
        JSON.parse(readFileSync(marker, 'utf8'));
    const worker = Number(readFileSync(
        `/proc/${process.pid}/task/${process.pid}/children`, 'utf8',
    ).trim().split(/\s+/)[0]);
    process.stdout.write(`${JSON.stringify({
        host: process.pid, worker, group: child.pid, ...descendants,
    })}\n`);
}

void main().catch(error => {
    process.stderr.write(`${String(error)}\n`);
    process.exitCode = 1;
});
