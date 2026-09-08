// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import type { FrostSettings } from './settings';
import type { DebugStartStrategy } from './hardware';

export function debugConfiguration(settings: FrostSettings, elf: string,
    id: string, start: DebugStartStrategy, coreXml?: string): Record<string, unknown> {
    const command = (text: string) => ({ text, ignoreFailures: false });
    return {
        name: `FROST: ${settings.app} (${settings.memory})`,
        type: 'cppdbg', request: 'launch', program: elf, cwd: settings.repoRoot,
        MIMode: 'gdb', miDebuggerPath: settings.gdbPath,
        miDebuggerServerAddress: '127.0.0.1:3333', useExtendedRemote: true,
        stopAtConnect: start !== 'main', stopAtEntry: false,
        launchCompleteCommand: start === 'main' ? 'exec-continue' : 'None',
        setupCommands: [
            ...(coreXml ? [command(`set tdesc filename ${coreXml}`)] : []),
            command('mem 0 0x40000 rw'), command('mem 0x80000000 0xc0000000 rw'),
            command('set mem inaccessible-by-default on'),
            command('set breakpoint auto-hw off'),
            command('set remote hardware-breakpoint-limit 0'),
            command('set remote hardware-watchpoint-limit 0'),
        ],
        postRemoteConnectCommands: start !== 'attach' ? [
            command('monitor reset halt'),
            command('monitor if {[dict get [get_reg -force pc] pc] != 0} {error "FROST reset did not stop at PC zero"}'),
            command('maintenance flush register-cache'),
            ...(start === 'main' ? [command('tbreak main')] : []),
        ] : [],
        // Plain cppdbg remains the adapter. This token only correlates VS Code
        // lifecycle events belonging to this extension's one managed session.
        __frostSessionId: id,
    };
}
