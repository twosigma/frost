// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import * as vscode from 'vscode';

/** User preferences only: entering/exiting Zen Mode remains an explicit VS Code action. */
export const focusSettings: Readonly<Record<string, string | boolean>> = Object.freeze({
    'workbench.activityBar.location': 'hidden',
    'workbench.statusBar.visible': false,
    'workbench.secondarySideBar.defaultVisibility': 'hidden',
    'editor.minimap.enabled': false,
    // Unlike chat.disableAIFeatures, this does not change extension enablement.
    'chat.commandCenter.enabled': false,
    'zenMode.fullScreen': false,
    'zenMode.centerLayout': false,
    'zenMode.hideLineNumbers': false,
    'zenMode.hideActivityBar': true,
    'zenMode.hideStatusBar': true,
    'zenMode.silentNotifications': true,
});

const snapshotKey = 'frost.focusLayout.snapshot.v1';
interface SavedSetting {
    key: string;
    // Omission survives JSON serialization and means there was no User override.
    before?: unknown;
    applied: string | boolean;
}
interface Snapshot {
    version: 1;
    storage: string;
    settings: SavedSetting[];
}

/** Register optional layout commands without changing any preferences on activation. */
export function registerFocusLayout(context: vscode.ExtensionContext): vscode.Disposable {
    let pending = Promise.resolve();

    function saved(): Snapshot | undefined {
        const value = context.globalState.get<Snapshot>(snapshotKey);
        if (!value) return undefined;
        if (value.version !== 1 || value.storage !== context.globalStorageUri.toString()
            || !Array.isArray(value.settings)
            || value.settings.some(entry => !Object.hasOwn(focusSettings, entry.key)
                || !['string', 'boolean'].includes(typeof entry.applied))) {
            throw new Error('The saved FROST layout belongs to another profile or is invalid. Restore it in the profile where it was applied.');
        }
        return value;
    }

    function checkSharedSettings(keys: string[]): void {
        const shared = vscode.workspace.getConfiguration().get<string[]>(
            'workbench.settings.applyToAllProfiles', []);
        const affected = keys.filter(key => shared.includes(key));
        if (affected.length) {
            throw new Error(`These layout settings apply to all profiles: ${affected.join(', ')}. `
                + 'Turn off "Apply Setting to all Profiles" for them before applying or restoring the FROST layout.');
        }
    }

    async function restore(snapshot: Snapshot): Promise<number> {
        checkSharedSettings(snapshot.settings.map(entry => entry.key));
        const remaining: SavedSetting[] = [];
        const errors: string[] = [];
        let preserved = 0;
        for (const entry of snapshot.settings) {
            const config = vscode.workspace.getConfiguration();
            if (config.inspect(entry.key)?.globalValue !== entry.applied) {
                preserved++;
                continue;
            }
            try {
                await config.update(entry.key, entry.before, vscode.ConfigurationTarget.Global);
            } catch (error) {
                remaining.push(entry);
                errors.push(`${entry.key}: ${String(error)}`);
            }
        }
        await context.globalState.update(snapshotKey,
            remaining.length ? { ...snapshot, settings: remaining } : undefined);
        if (errors.length) {
            throw new Error(`Some layout settings could not be restored. Run FROST: Restore Layout again. ${errors.join('; ')}`);
        }
        return preserved;
    }

    async function apply(): Promise<void> {
        if (saved()) {
            void vscode.window.showInformationMessage('FROST focus layout is already saved. Run FROST: Restore Layout before applying it again.');
            return;
        }
        checkSharedSettings(Object.keys(focusSettings));
        const config = vscode.workspace.getConfiguration();
        const snapshot: Snapshot = {
            version: 1,
            storage: context.globalStorageUri.toString(),
            settings: Object.entries(focusSettings).flatMap(([key, applied]) => {
                const before = config.inspect(key)?.globalValue;
                return before === applied ? [] : [{ key, before, applied }];
            }),
        };
        // Persist before the first write so Restore still works after an interrupted apply.
        await context.globalState.update(snapshotKey, snapshot);
        try {
            for (const entry of snapshot.settings) {
                await vscode.workspace.getConfiguration().update(
                    entry.key, entry.applied, vscode.ConfigurationTarget.Global);
            }
        } catch (error) {
            try { await restore(snapshot); }
            catch (restoreError) { throw new Error(`${String(error)}; ${String(restoreError)}`); }
            throw error;
        }
        void vscode.window.showInformationMessage('FROST focus layout applied to User settings. Run FROST: Toggle Zen Mode for quiet notifications.');
    }

    async function restorePrevious(): Promise<void> {
        const snapshot = saved();
        if (!snapshot) {
            void vscode.window.showInformationMessage('There is no saved FROST layout to restore in this profile.');
            return;
        }
        const preserved = await restore(snapshot);
        void vscode.window.showInformationMessage('Previous layout settings restored.'
            + (preserved ? ` Kept ${preserved} setting(s) changed since applying the layout.` : '')
            + ' Exit Zen Mode separately if it is active.');
    }

    function command(id: string, action: () => Promise<unknown>): vscode.Disposable {
        return vscode.commands.registerCommand(id, () => {
            pending = pending.then(action).then(() => {}, error => {
                void vscode.window.showErrorMessage(`FROST layout: ${String(error)}`);
            });
            return pending;
        });
    }

    return vscode.Disposable.from(
        command('frost.applyFocusLayout', apply),
        command('frost.restoreFocusLayout', restorePrevious),
        command('frost.toggleFocusZen', async () => {
            await vscode.commands.executeCommand('workbench.action.toggleZenMode');
        }),
    );
}
