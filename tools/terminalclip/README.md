# TerminalClip · UI 0.2 (MVP)

Native macOS menu-bar utility that copies marked output from Apple Terminal.app. One Swift source file, no external libraries.

## Features

- Shortcut ⌘⌥C: copy last marked output
- Popover: copy full output, last 100 lines, command, working directory, or diagnostic report
- Cleans ANSI escape sequences
- Optional Zsh hooks add command, PWD, exit code, duration, and timestamp
- No automatic logging of output, network calls or cloud services
- Optional start at login

## UI design

The redesigned popover follows the keyboard-first simplicity of [Maccy](https://github.com/p0deje/Maccy) and the clear action hierarchy of [Raycast](https://manual.raycast.com/clipboard-history), without adopting their clipboard-history features:

- **Opaque native panel** (~390 pt wide) instead of a translucent system menu.
- **Prominent primary action** for copying the last output, with ⌘⌥C visible beside it.
- **Two compact groups:** Output (last output / last 100 lines) and Context (report / command / directory; optional Zsh integration required).
- **SF Symbols, subtitles and subtle hover highlighting** so actions are quick to distinguish.
- **Terminal.app availability indicator** shown when the popover opens, and discreet local/private status plus Quit in the footer.
- **No new dependencies or background collection.** Native UI only; no stored output history.

The interface retains the limitations of native Terminal.app marks; its visual polish does not imply byte-perfect stdout/stderr capture.

## If you still see the old grey buttons

The old interface says **"Copia dal tab corrente di Terminal.app"** and uses five identical grey buttons. The redesigned interface says **"Dall'output agli appunti in un clic"**, has **OUTPUT** and **CONTESTO** groups, and shows **v0.2** near the title.

After fetching the branch, **force rebuild and relaunch** the installed app instead of simply running `open` (which can reuse an older process):

~~~bash
git fetch origin
git switch feat/terminalclip-mvp
git pull --ff-only
make refresh-terminalclip
~~~

This command rebuilds from source even if local timestamps are misleading, closes existing TerminalClip processes, installs the bundle at `~/.local/opt/TerminalClip.app`, and opens this exact bundle. It does not affect MenuMeter. If the old UI remains, inspect all running copies and the version:

~~~bash
ps -axo pid,command | grep '[T]erminalClip'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME/.local/opt/TerminalClip.app/Contents/Info.plist"
~~~

The version should be **0.2.0**. If a TerminalClip process is running from another path, quit it and relaunch the installed bundle above. On macOS the global shortcut can also conflict with an old Automator binding.

## Install

macOS 13+ and Xcode Command Line Tools. From the repository root:

~~~bash
make install-terminalclip
open "$HOME/.local/opt/TerminalClip.app"
~~~

Alternatively, `make install` or `bash install.sh` installs both MenuMeter and TerminalClip. Installation does not activate the hook, autostart, or start the app.

To enable optional metadata capture explicitly:

~~~bash
bash tools/terminalclip/install-zsh.sh
~~~

Open a new Terminal tab. This adds a single idempotent line to `~/.zshrc`. The hook records the **last completed command** per local TTY.

Enable or disable start at next login:

~~~bash
bash tools/terminalclip/login.sh enable
bash tools/terminalclip/login.sh disable
~~~

## Permissions and shortcut

- Allow TerminalClip in **System Settings → Privacy & Security → Accessibility** to send ⌘⇧A and ⌘C to Terminal.app.
- If using the Zsh hook, allow **Automation → Terminal** when prompted, to read the selected tab's TTY.
- Remove any existing global ⌘⌥C Automator shortcut if you want TerminalClip's shortcut to work; the menu remains available.

## Manual smoke test

1. Enable automatic prompt marks in Terminal.app → Edit → Marks.
2. Run `printf 'TerminalClip example\nsecond line\n'`.
3. Verify the native ⌘⇧A then ⌘C sequence copies the expected block (which may include prompt/command).
4. Open TerminalClip and press ⌘⌥C, then paste into a text editor.
5. With the optional hook enabled, run `false` in a new tab, then test command and diagnostic report actions.
6. Repeat across two tabs to verify session matching.

Run core checks and macOS typecheck:

~~~bash
make test-terminalclip
~~~

## Limitations and privacy

- Apple Terminal.app only. Copy depends on native marks and scrollback, not a byte-for-byte stream recording. stdout/stderr are not separable, and prompts or commands can be included.
- Selecting output activates Terminal.app. A changed clipboard is used to detect successful copying; clipboard changes made simultaneously by other apps may affect detection.
- Optional Zsh hook saves the last local command and its metadata in `~/Library/Application Support/TerminalClip/state/` with restrictive permissions. **Command lines may include secrets**. Files are deleted on normal shell exit or TTY reuse, but can survive crashes. Do not enable the hook if that risk is unacceptable.
- Metadata of commands run inside SSH/remote shells is not available. Output and metadata can diverge if a different marked block is selected.
- Copied text uses the normal macOS clipboard; Universal Clipboard may sync it if enabled.
- No silent output capture, no persistent output history, no upload.

## Uninstall

~~~bash
make uninstall-terminalclip
~~~

This removes the app and login plist but leaves the optional `~/.zshrc` source line and state untouched. Inspect and remove the hook and files separately if desired.

## Validation

The pure-Swift unit checks can run without AppKit. Full AppKit/Carbon compilation, permission prompts, marks selection and live clipboard behavior must be validated on macOS.
