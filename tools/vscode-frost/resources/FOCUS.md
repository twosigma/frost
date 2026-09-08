<!-- Copyright 2026 Two Sigma Open Source, LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Optional FROST focus layout

Run **FROST: Apply Focus Layout** to hide the activity bar, status bar, minimap,
and chat toolbar button. **FROST: Restore Layout** restores the saved
User overrides, including removing overrides that were originally absent.
Settings whose User values differ from the applied values are preserved. The backup survives VS Code reloads;
repeating Apply keeps the original backup. Workspace overrides remain effective.
These commands never change extension enablement.

Use **FROST: Toggle Zen Mode** for quieter notifications and fewer panels.
It invokes VS Code's public Zen toggle; toggle again or press Escape twice to
exit. Apply configures Zen to retain source line numbers and avoid fullscreen or
centered layout. Zen silences ordinary notification popups while preserving
error notifications. FROST Output remains available through **FROST: Show Output**.
Apply/Restore do not enter or exit Zen, so an existing Zen session stays under
your control. The secondary sidebar setting controls its default visibility;
an already open sidebar can be closed with VS Code's layout controls.
See [VS Code custom layout](https://code.visualstudio.com/docs/configure/custom-layout)
and the [1.106 Zen settings](https://github.com/microsoft/vscode/blob/1.106.3/src/vs/workbench/browser/workbench.contribution.ts).

For an isolated setup, open **File > Preferences > Profiles**, choose
**Import Profile** from the **New Profile** dropdown, and select
[FROST.code-profile](FROST.code-profile). Create a **new** profile named
**FROST Debug** and review its contents before importing. Then run
**Extensions: Install from VSIX...** in that profile and select the packaged
FROST VSIX. The template requests only C/C++; FROST is a local VSIX and cannot
be installed by a Marketplace profile entry. Built-in extensions remain, and
extensions explicitly applied to all profiles may also appear. Review those
in the Profiles editor if you want only FROST and C/C++ as added extensions.
Switch back to your previous profile to recover its layout and extension set.
See [VS Code profiles](https://code.visualstudio.com/docs/configure/profiles).

Use independent Settings and UI State for the dedicated profile. Profiles that
inherit the Default profile's Settings share that settings file; the public
extension API does not expose this inheritance. Apply/Restore refuse managed
settings marked **Apply Setting to all Profiles**, and Restore refuses a backup
copied from another profile storage location. Imported focus settings are the
new profile's initial settings; Restore only undoes changes made by Apply.

The template uses VS Code 1.106's profile format: its `settings` field contains
a serialized settings resource, and `extensions` contains a serialized list.
The format follows the upstream [settings resource](https://github.com/microsoft/vscode/blob/1.106.3/src/vs/workbench/services/userDataProfile/browser/settingsResource.ts)
and [extensions resource](https://github.com/microsoft/vscode/blob/1.106.3/src/vs/workbench/services/userDataProfile/browser/extensionsResource.ts).

The 0.2 workbench check exercised Apply, Zen, and Restore. Restore removed all
11 added overrides and preserved the remaining settings. Importing this file
through the public Profiles UI created a separate FROST Debug profile containing
exactly the 11 intended settings and C/C++ 1.33.8. The original Default profile
remained active; installing FROST into the new profile is still a separate step.
