<!-- Copyright 2026 Two Sigma Open Source, LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Optional FROST focus layout

**FROST: Apply Focus Layout** hides the activity bar, status bar, minimap,
and chat button, and sets Zen Mode to keep line numbers, avoid full screen and
centered layout, and show only error notifications. It also makes the
secondary side bar start hidden; close one that is already open with VS
Code's layout controls. Apply changes User settings only, never extension
enablement, and saves their previous values, which survive window reloads.
Workspace settings still override it.

**FROST: Restore Layout** puts the saved values back, removing settings that
Apply added, and keeps any setting you changed after Apply. Apply refuses to
run again until you restore. Neither command enters or leaves Zen Mode: use
**FROST: Toggle Zen Mode**, or press Escape twice to leave it.
**FROST: Show Output** still shows FROST's log in Zen Mode.

## A separate profile

To keep this layout and a minimal extension set apart from your usual setup:

1. In **File > Preferences > Profiles**, choose **Import Profile** from the
   **New Profile** menu and select [FROST.code-profile](FROST.code-profile).
2. Create it as a new profile named **FROST Debug**, with its own Settings and
   UI State, after reviewing its contents.
3. In that profile, run **Extensions: Install from VSIX...** and select the
   FROST VSIX.

The template adds only C/C++; a profile cannot install a local VSIX.
Built-in extensions, and any applied to all profiles, still appear. Switch
profiles to get your usual layout back. See
[VS Code profiles](https://code.visualstudio.com/docs/configure/profiles).

Keep the profile's Settings separate: if it shares the Default profile's
settings, Apply changes those too, and the extension cannot detect the
sharing. Apply and Restore refuse settings marked
**Apply Setting to all Profiles**, and Restore refuses a backup saved in
another profile. The imported profile starts with the focus settings already
set, and Restore undoes only what Apply changed.
