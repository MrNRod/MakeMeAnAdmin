# MakeMeAnAdmin (SwiftDialog Edition)
Repo: [https://github.com/MrNRod/MakeMeAnAdmin.git](https://github.com/MrNRod/MakeMeAnAdmin.git)

A modernized, vendor-agnostic fork of [Jamf's MakeMeAnAdmin](https://github.com/jamf/MakeMeAnAdmin), for **Workspace ONE**, **Jamf Pro**, or any MDM that can run a script as root. It uses [SwiftDialog](https://github.com/swiftDialog/swiftDialog) for the user interface and removes admin rights automatically when the time is up.

---

## Features

- **SwiftDialog UI** with company branding that adapts to square, wide and tall logos
- **Time-boxed elevation** (30 minutes to 1 week), one active grant at a time
- **Fail-closed demotion**: the demotion daemon is installed and verified *before* the user is elevated, and any failure rolls the grant back
- **Expiry by wall-clock timestamp**: survives sleep, shutdown and reboot; a backwards clock change demotes immediately
- **MDM backstop** (`enforce` mode) that re-arms a tampered daemon
- **Audit trail**: CSV event log, sudo command log for the session, unified-log entries, and a report of any admin accounts added during the window
- **Dark-mode logo variant** and a built-in fallback icon

---

## Screenshot Preview

### Time Selection Prompt
![Time Selection](screenshots/prompt.png)

### Confirmation or Active Status Dialog
![Admin Confirmation](screenshots/confirmation.png)

---

## Requirements

- macOS 12 or later
- Run as **root** by your MDM
- **SwiftDialog installed on the Mac before the script runs** (see below)

### SwiftDialog: required, not installed by the script

Earlier versions downloaded and installed SwiftDialog at run time. That is removed on purpose:

| Problem with run-time install | Why it matters |
| :--- | :--- |
| Downloaded to a predictable path in `/tmp` and installed **as root** | A local user could swap the package and get root. |
| Unpinned "latest" release fetched from the internet by a root script | Supply-chain exposure; breaks offline or behind proxies; results vary per Mac. |
| Installs software as a side effect of a user clicking a button | Not auditable or change-controlled. |

Instead, deploy SwiftDialog through your MDM as its own package (pinned to a version you have tested), and make the Make Me Admin policy depend on it:

- **Jamf Pro**: add the SwiftDialog `.pkg` to the same policy (packages install before scripts), or scope a separate policy that runs first.
- **Workspace ONE**: deploy the `.pkg` as an app/product and set it as a dependency of the script, or assign it to the same smart group.

At run time the script does **not** trust `PATH` or `/usr/local/bin/dialog`. It calls `/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/dialogcli` directly and requires the bundle to pass `codesign --verify` with Team ID `PWA5E9TQ59`. If SwiftDialog is missing or fails the check, the script exits non-zero without changing anything.

### No separate install step for the script itself

The script is self-provisioning: when a grant is approved it writes a root-owned helper and LaunchDaemon, and when the grant ends it removes them. Nothing privileged stays on the Mac between grants, so there is nothing to install, patch or leave behind. Just deploy the script.

---

## Configuration

Precedence: **MDM script parameter → environment variable → default**.

| Variable | Jamf Param | Description | Default |
| :--- | :--- | :--- | :--- |
| `companyName` | `$4` | Used in the LaunchDaemon label (`com.<name>.adminExpiryCheck`). Letters, digits, `.`, `_`, `-` only; anything else is rejected. | `MrNRod` |
| `companyLogo` | `$5` | Absolute path to a logo (PNG, JPG, PDF, SVG, ICNS), or an `https://` URL. | built-in lock icon |
| *(unused)* | `$6` | Was `allowDialogInstall`. Ignored. | |
| `companyLogoDark` | `$7` | Optional logo for Dark Mode (use it if your logo has dark text on a transparent background). | none |
| `mode` | `$8` | `request`, `enforce` or `preview`. | `request` |

The logo must be readable by the logged-in user. If it is not, the script logs a warning and uses the built-in icon rather than showing a broken dialog.

### Logos: wide, square and tall

SwiftDialog sizes an icon by *width* and lets the height follow, and the window height is fixed. The script reads the logo's pixel dimensions and picks both so any shape looks balanced:

| Logo shape | Example | Drawn size | 
| :--- | :--- | :--- |
| Square | 512×512 | 110×110 |
| Wide 3:1 | 900×300 | 330×110 |
| Wide 5:1 | 1500×300 | 380×76 |
| Very wide 10:1 | 2000×200 | 380×38 |
| Tall 1:2 | 300×600 | 55×110 (fits a 110×110 box) |
| Small raster | 96×96 | 96×96 (never upscaled past 1×) |

The window is 500 pt wide and 350–480 pt tall depending on the logo. Recommendations:

- Use a **transparent PNG, SVG or PDF**, about **2× the drawn size** (for example 760×220 for a 3.5:1 logo) so it is sharp on Retina displays.
- Trim excess transparent padding from the image; it counts toward the logo's shape.
- URLs and non-image paths (such as an `.app`) cannot be measured, so they are drawn at a safe square size.
- The sizing constants are at the top of the script (`logoMaxW`, `logoMaxH`, `winWidth`) if you want to tune them.

### Previewing your branding

```bash
companyLogo="/Library/Application Support/Acme/logo.png" ./MakeMeAnAdmin.sh preview
```

`preview` needs no root, shows the real prompt and confirmation dialogs, and changes nothing. Use it to check a new logo before you ship it.

---

## How It Works

1. Finds the console user (never `root`/`loginwindow`) and verifies SwiftDialog.
2. Refuses if the user is already an admin (so they are never demoted by mistake) or already has an active grant (so a grant cannot be extended by re-running the policy).
3. Shows the duration prompt. The answer must match the fixed list; anything else is rejected.
4. **Arms first**: writes the state file, a root-owned helper and the LaunchDaemon, and confirms `launchd` loaded it.
5. Only then adds the user to `admin` and confirms the membership. If any step fails, or the script is killed part-way, the grant is rolled back.
6. The daemon runs at boot and every 60 seconds. At expiry it removes the user (retrying if needed), logs the session's sudo commands, reports any accounts that were added to `admin` during the window, then deletes itself and all state.

---

## Security Model

### What it defends against

| Bypass attempt | Defence |
| :--- | :--- |
| Re-run the policy to extend the window | Rejected while a grant is active. |
| Move the system clock back | `lastSeen` is recorded every minute; a backwards step over 2 minutes demotes immediately. |
| Edit the expiry to a far-future date | The helper rejects any grant longer than one week and demotes. |
| Stay admin through a reboot or sleep | Expiry is an absolute timestamp; the daemon has `RunAtLoad`. |
| Delete or unload the daemon | `enforce` mode (run it from your MDM on a schedule) re-arms it and demotes if expired. Files are also `schg`-flagged to slow casual removal. |
| Demotion fails transiently | Retried up to three times, then the daemon stays armed and `launchd` retries every minute. |
| Be left admin because setup failed | Daemon is verified before elevation; failures roll back. |
| Demoting the wrong person | The target user is stored in the state file at grant time, not looked up at expiry. |
| Inject through `companyName`, usernames or the dialog result | All are validated against strict patterns; durations come from a fixed whitelist. |
| Swap the SwiftDialog installer / binary | No run-time install; signature and Team ID are verified; `PATH` is fixed. |
| Hide what they did | Sudo commands are logged for the window; admins added during it are reported. |

### What it cannot do (read this)

**While elevated, the user is an administrator and can run anything as root.** No script can stop a determined admin from, for example, unloading the daemon and clearing the `schg` flag, creating a second admin account, or editing `/etc/sudoers`. This tool makes that hard, noisy and self-healing, but the real backstop is your MDM:

1. **Run `enforce` on a schedule** (for example every Jamf check-in or hourly in Workspace ONE). It re-arms a removed daemon and demotes expired grants even if the daemon was killed. Pass `enforce` as the first argument, or set `$8` / `mode`.
2. **Alert on the audit events**: `tamper-detected`, `demote-failed`, `unexpected-admin-added`, `state-tampered` and `clock-rewound` in `MakeMeAnAdminEvents.log`.
3. **Use an MDM compliance check** that reports unexpected members of the local `admin` group.

### Privacy note on sudo logging

Older versions enabled `log_input,log_output` for all sudo users, which records everything typed (including secrets) and grows without limit. This version logs **commands only** (`/var/log/sudo_admin.log`, root-readable), validates the sudoers snippet with `visudo -c` before installing it, and replaces the old snippet on the next run.

---

## Log Events

`MakeMeAnAdminEvents.log` (CSV, `root:wheel 640`, rotated at 1 MB into the archive CSV). Events are also written to the unified log under the tag `MakeMeAnAdmin`.

| Event | Meaning |
| :--- | :--- |
| `elevated` | Grant started. |
| `demoted` | Grant ended; `command` holds the reason and the user's sudo commands. |
| `demote-failed` | Demotion did not take; will retry. |
| `unexpected-admin-added` | Accounts added to `admin` during the window. |
| `tamper-detected` | `enforce` found the daemon missing or unloaded. |
| `state-invalid` | State file was corrupt; nothing could be safely demoted. |

---

## File Locations

- **Logs**: `/Library/Logs/MakeMeAnAdmin/MakeMeAnAdminEvents.log` and `..._Archive.csv`
- **Sudo audit log**: `/var/log/sudo_admin.log`
- **State / helper (only while a grant is active)**: `/Library/Application Support/MakeMeAnAdmin/`
- **LaunchDaemon (only while a grant is active)**: `/Library/LaunchDaemons/com.<companyName>.adminExpiryCheck.plist`

---

## Upgrading from earlier versions

- **SwiftDialog is no longer installed for you.** Deploy it first. `$6` / `allowDialogInstall` is ignored.
- Older versions did not demote reliably (the generated expiry script never expanded its paths), so users elevated by the old version may still be admins. Run `enforce` once, or check your admin group.
- The old `log_input,log_output` sudoers snippet is replaced on the next grant.
- `/etc/sudoers.d/admin_logging` is owned by this tool; if you maintain a snippet of the same name, rename one of them.

---

## Comparison to Original

| Feature                         | Original Jamf Version | SwiftDialog Edition |
|---------------------------------|------------------------|----------------------|
| GUI Support                     | ❌                     | ✅ SwiftDialog |
| MDM Compatibility               | Jamf Only              | ✅ Any MDM |
| Branding Support                | ❌                     | ✅ any logo shape + dark variant |
| Time-based UI Selection         | ❌ Manual via CLI      | ✅ |
| Logging                         | Basic                  | ✅ CSV + sudo commands + unified log |
| Survives sleep / reboot         | ✅ (sleep-based timer) | ✅ (timestamp-based) |
| Clock-tamper detection          | ❌                     | ✅ |
| Fail-closed grant / rollback    | ❌                     | ✅ |
| MDM re-arm / enforcement mode   | ❌                     | ✅ |

---

## Credits

- Based on [Jamf's MakeMeAnAdmin](https://github.com/jamf/MakeMeAnAdmin)
- SwiftDialog by [Bart Reardon](https://github.com/swiftDialog/swiftDialog)
