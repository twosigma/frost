// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import * as vscode from 'vscode';
import path from 'node:path';
import { StringDecoder } from 'node:string_decoder';
import { OwnedProcess, bounded } from './process';
import { readRepositoryMetadata } from './plainLoad';

interface SerialSettings {
    repoRoot: string;
    pythonPath: string;
    startupTimeoutMs: number;
    port: string;
    baud: number;
    jtagSerial: string;
}

function serialSettings(folder: vscode.WorkspaceFolder): SerialSettings {
    const config = vscode.workspace.getConfiguration('frost', folder.uri);
    const text = (key: string, fallback: string) => {
        const value: unknown = config.get(key, fallback);
        if (typeof value !== 'string' || /[\0\r\n]/.test(value)) throw new Error(`Invalid frost.${key}`);
        return value.trim();
    };
    const baud: unknown = config.get('serial.baudRate', 115200);
    if (typeof baud !== 'number' || !Number.isSafeInteger(baud) || baud <= 0) throw new Error('Set a positive serial baud rate');
    const timeout: unknown = config.get('startupTimeoutMs', 20000);
    if (typeof timeout !== 'number' || !Number.isSafeInteger(timeout) || timeout < 1 || timeout > 2147483647) throw new Error('Invalid startup timeout');
    const pythonPath = text('pythonPath', 'python3');
    const port = text('serial.port', 'auto');
    if (!pythonPath || !port) throw new Error('Configure a Python executable and serial port');
    return { repoRoot: path.resolve(folder.uri.fsPath, text('repoRoot', '')), pythonPath,
        startupTimeoutMs: timeout, port, baud, jtagSerial: text('jtagSerial', '') };
}

class ConsoleTerminal implements vscode.Pseudoterminal {
    private readonly writes = new vscode.EventEmitter<string>();
    readonly onDidWrite = this.writes.event;
    private opened = false;
    private pending = '';
    constructor(private readonly input: (data: string) => void, private readonly closed: () => void) {}
    open(): void { this.opened = true; this.writes.fire(this.pending); this.pending = ''; }
    close(): void { this.closed(); }
    handleInput(data: string): void { this.input(data); }
    write(data: string): void {
        if (this.opened) this.writes.fire(data);
        else this.pending = (this.pending + data).slice(-65536);
    }
    dispose(): void { this.writes.dispose(); }
}

interface Connection {
    child: OwnedProcess;
    pty: ConsoleTerminal;
    abort: AbortController;
    decoder: StringDecoder;
    pending: string;
    ready: boolean;
    failure?: Error;
    closing: boolean;
    cleanup?: Promise<void>;
    reconfigured?: () => void;
}

/** An extension-owned terminal: no shell, miniterm command, or shared descriptor. */
export class SerialConsole {
    private terminal?: vscode.Terminal;
    private pty?: ConsoleTerminal;
    private connection?: Connection;
    private opening?: Promise<void>;
    private openingAbort?: AbortController;
    private stopping?: Promise<void>;
    private disposed = false;
    private transmit = Promise.resolve();
    private queuedBytes = 0;
    private blocked?: string;
    private reconfiguring?: Promise<void>;

    constructor(private readonly context: vscode.ExtensionContext,
        private readonly output: (text: string) => void) {}

    private status(message: string): void {
        this.output(`Serial: ${message}\n`);
        this.pty?.write(`\r\n[FROST Serial] ${message}\r\n`);
    }

    async show(folder: vscode.WorkspaceFolder, preserveFocus = false, signal?: AbortSignal): Promise<void> {
        if (this.disposed) return;
        if (this.blocked) throw new Error(this.blocked);
        if (this.stopping) await this.stopping;
        if (!this.terminal) {
            const pty = new ConsoleTerminal(data => this.send(data), () => {
                if (this.pty !== pty) return;
                this.terminal = undefined;
                void this.close().catch(error => this.output(`Serial cleanup: ${String(error)}\n`));
            });
            this.pty = pty;
            this.terminal = vscode.window.createTerminal({ name: 'FROST Serial', pty,
                isTransient: true, iconPath: new vscode.ThemeIcon('terminal') });
        }
        this.terminal.show(preserveFocus);
        if (this.opening) return this.opening;
        if (this.connection?.ready && this.connection.child.running) return;
        const abort = this.openingAbort = new AbortController();
        const cancelled = () => abort.abort(signal?.reason ?? new Error('Serial connection cancelled'));
        signal?.addEventListener('abort', cancelled, { once: true });
        if (signal?.aborted) cancelled();
        return this.opening = this.connect(folder, abort).finally(() => {
            signal?.removeEventListener('abort', cancelled);
            this.opening = undefined; this.openingAbort = undefined;
        });
    }

    async autoOpen(folder: vscode.WorkspaceFolder, signal?: AbortSignal): Promise<void> {
        if (!vscode.workspace.getConfiguration('frost', folder.uri).get('serial.autoOpen', true)) return;
        try { await this.show(folder, true, signal); }
        catch (error) {
            // An external serial terminal does not prevent an otherwise valid
            // FPGA operation. The console reports the owner without changing it.
            this.status(`Could not connect: ${String(error)}. Use FROST: Open Serial Console to retry.`);
        }
    }

    private async connect(folder: vscode.WorkspaceFolder, abort: AbortController): Promise<void> {
        if (this.connection) await this.stopConnection(this.connection);
        if (this.blocked) throw new Error(this.blocked);
        const settings = serialSettings(folder);
        const metadata = await readRepositoryMetadata(settings, abort.signal);
        abort.signal.throwIfAborted();
        if (this.disposed || !this.pty) return;
        const pty = this.pty;
        const args = ['-B', '-u', this.context.asAbsolutePath('resources/serial_bridge.py'),
            '--port', settings.port, '--baud', String(settings.baud), '--fallback-port', metadata.defaultSerial];
        if (settings.jtagSerial) args.push('--jtag-serial', settings.jtagSerial);
        this.status(`Connecting to ${settings.port} at ${settings.baud} baud…`);
        let record: Connection | undefined;
        const child = new OwnedProcess({ command: settings.pythonPath, args, cwd: settings.repoRoot,
            input: true, output: text => { if (record) this.receive(record, text); },
            stderr: text => this.output(`Serial helper: ${text}`) });
        record = { child, pty, abort, decoder: new StringDecoder('utf8'),
            pending: '', ready: false, closing: false };
        this.connection = record;
        const current = record;
        void child.exited.then(async result => {
            current.pty.write(current.decoder.end());
            current.ready = false;
            if (!current.closing) {
                try {
                    await this.stopConnection(current);
                    this.status(`Disconnected${result.code ? ` (exit ${result.code})` : ''}. Reopen the console to reconnect.`);
                } catch (error) { this.status(String(error)); }
            }
        });
        try {
            await child.ready(() => {
                if (current.failure) throw current.failure;
                return current.ready;
            }, settings.startupTimeoutMs, current.abort.signal);
        } catch (error) {
            current.closing = true;
            await this.stopConnection(current);
            throw current.failure ?? error;
        }
    }

    private stopConnection(record: Connection): Promise<void> {
        record.closing = true;
        record.ready = false;
        return record.cleanup ??= (async () => {
            try { await record.child.stop(); }
            catch (error) { this.blocked = `Serial cleanup is unconfirmed: ${String(error)}`; throw error; }
            if (this.connection === record) this.connection = undefined;
        })();
    }

    private protocolFailure(record: Connection, message: string): void {
        record.failure = new Error(message);
        this.status(message);
        record.abort.abort(record.failure);
        void this.stopConnection(record).catch(error => this.status(String(error)));
    }

    private receive(record: Connection, text: string): void {
        record.pending += text;
        if (record.pending.length > 262144) {
            this.protocolFailure(record, 'Serial helper exceeded its message limit');
            return;
        }
        let newline: number;
        while ((newline = record.pending.indexOf('\n')) >= 0) {
            const line = record.pending.slice(0, newline); record.pending = record.pending.slice(newline + 1);
            if (!line) continue;
            try {
                const message = JSON.parse(line) as { type: string; data?: string; message?: string; port?: string; baud?: number };
                if (message.type === 'ready') {
                    record.ready = true;
                    this.status(`Connected: ${message.port}, ${message.baud} baud, 8N1. Type to send; Ctrl+] closes the console.`);
                } else if (message.type === 'data' && typeof message.data === 'string') {
                    const bytes = Buffer.from(message.data, 'base64');
                    if (bytes.toString('base64') !== message.data) throw new Error('Invalid serial payload');
                    record.pty.write(record.decoder.write(bytes));
                } else if (message.type === 'reconfigured') record.reconfigured?.();
                else if (message.type === 'error') {
                    this.protocolFailure(record, message.message ?? 'Serial helper failed');
                    return;
                } else if (message.type !== 'closed') {
                    throw new Error('Unknown serial helper event');
                }
            } catch { this.protocolFailure(record, 'Invalid serial helper response'); return; }
        }
    }

    private send(data: string): void {
        if (data === '\x1d') { void this.close().catch(error => this.status(String(error))); return; }
        const record = this.connection;
        if (!record?.ready || !record.child.running || record.closing) { this.status('Not connected. Reopen the serial console to connect.'); return; }
        const bytes = Buffer.from(data, 'utf8');
        if (this.queuedBytes + bytes.length > 65536) { this.status('Input queue full; paste a smaller amount of text.'); return; }
        this.queuedBytes += bytes.length;
        this.transmit = this.transmit.then(async () => {
            if (this.connection !== record || record.closing) return;
            for (let offset = 0; offset < bytes.length; offset += 4096) {
                await record.child.write(JSON.stringify({ type: 'write', data: bytes.subarray(offset, offset + 4096).toString('base64') }) + '\n');
            }
        }).catch(error => this.status(`Send failed: ${String(error)}`))
            .finally(() => { this.queuedBytes -= bytes.length; });
    }

    /** Reapply raw settings only on our descriptor after FT4232H JTAG activity. */
    async afterJtag(): Promise<void> {
        return this.reconfiguring ??= this.reconfigure().finally(() => { this.reconfiguring = undefined; });
    }

    private async reconfigure(): Promise<void> {
        const record = this.connection;
        if (!record?.ready || !record.child.running || record.closing) return;
        try {
            const reconfigured = new Promise<void>(resolve => { record.reconfigured = resolve; });
            await record.child.write('{"type":"reconfigure"}\n');
            await bounded(reconfigured, 3000, record.abort.signal);
            if (record.failure) throw record.failure;
        } catch (error) { this.status(`Port settings could not be restored: ${String(error)}`); }
        finally { record.reconfigured = undefined; }
    }

    close(): Promise<void> {
        if (this.stopping) return this.stopping;
        this.openingAbort?.abort(new Error('Serial console closed'));
        const record = this.connection;
        if (record) { record.closing = true; record.abort.abort(new Error('Serial console closed')); }
        const terminal = this.terminal; this.terminal = undefined;
        const pty = this.pty; this.pty = undefined;
        terminal?.dispose();
        return this.stopping = (async () => {
            await this.opening?.catch(() => {});
            if (this.connection) {
                await this.stopConnection(this.connection);
            }
            pty?.dispose();
        })().finally(() => { this.stopping = undefined; });
    }

    async dispose(): Promise<void> { this.disposed = true; await this.close(); }
}
