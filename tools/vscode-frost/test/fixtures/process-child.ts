// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import net from 'node:net';

// A small native-tool substitute. Tree descendants deliberately close their
// inherited output streams and ignore TERM, just as a daemonizing launcher can.
const [mode, marker] = process.argv.slice(2);

switch (mode) {
    case 'echo-input':
        process.stderr.write('fixture diagnostic\n');
        process.stdout.write('INPUT_READY\n');
        process.stdin.on('data', data => process.stdout.write(data));
        break;
    case 'exit':
        process.stderr.write('fixture: tool initialization failed\n');
        process.exitCode = 17;
        break;
    case 'hang':
        process.stdout.write('STARTED\n');
        setInterval(() => {}, 1000);
        break;
    case 'split-ready':
        process.stdout.write('fixture: Lis');
        setTimeout(() => {
            process.stdout.write('tening on port ');
            setTimeout(() => process.stdout.write('12345\n'), 60);
        }, 60);
        setInterval(() => {}, 1000);
        break;
    case 'listen': {
        const server = net.createServer(socket => socket.end('owned listener\n'));
        server.listen(0, '127.0.0.1', () => {
            const address = server.address() as net.AddressInfo;
            process.stdout.write(`LISTENING ${address.port}\n`);
        });
        break;
    }
    case 'stubborn': {
        process.on('SIGTERM', () => {});
        const server = net.createServer(socket => socket.end('owned descendant\n'));
        server.listen(0, '127.0.0.1', () => {
            const address = server.address() as net.AddressInfo;
            writeFileSync(marker, JSON.stringify({
                pid: process.pid, parent: process.ppid, port: address.port,
            }));
        });
        break;
    }
    case 'tree':
    case 'tree-exit': {
        const descendant = spawn(process.execPath, [__filename, 'stubborn', marker], {
            stdio: 'ignore', detached: false,
        });
        descendant.once('error', error => { throw error; });
        const timer = setInterval(() => {
            if (!existsSync(marker)) return;
            // A successful parse means the descendant is listening and its
            // SIGTERM handler is installed before the test starts cleanup.
            const details: unknown = JSON.parse(readFileSync(marker, 'utf8'));
            clearInterval(timer);
            process.stdout.write(`TREE_READY ${JSON.stringify(details)}\n`);
            if (mode === 'tree-exit') setTimeout(() => process.exit(0), 100);
        }, 20);
        break;
    }
    default:
        throw new Error(`Unknown fixture mode: ${mode}`);
}
