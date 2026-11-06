# MakeMeAnAdmin (SwiftDialog Edition)
Repo: [https://github.com/MrNRod/MakeMeAnAdmin.git](https://github.com/MrNRod/MakeMeAnAdmin.git)

A fork of [Jamf's MakeMeAnAdmin](https://github.com/jamf/MakeMeAnAdmin) that gives a standard user **temporary admin rights** and removes them automatically. Built for **[Fleet](https://fleetdm.com)**; also runs from **Jamf Pro**, **Workspace ONE**, or anything that can run a script as root. UI by [SwiftDialog](https://github.com/swiftDialog/swiftDialog).

![Time Selection](screenshots/prompt.png)
![Admin Confirmation](screenshots/confirmation.png)

## Requirements

- macOS 12+, run as **root**
- [SwiftDialog](https://github.com/swiftDialog/swiftDialog) on the Mac (verified by Team ID `PWA5E9TQ59`; the script exits without changing anything if it is missing)

---

# Fleet (recommended)

Fleet runs scripts as root with no arguments, so branding comes from a configuration profile and the two modes are two copies of the script. Self-service and policy `run_script` need **Fleet Premium**; without it, an admin runs the script from the host page (**Actions → Run script**) when a user asks.

**1. SwiftDialog** (policy checks for the binary the script needs)
```yaml
policies:
  - name: SwiftDialog is installed
    platform: darwin
    query: "SELECT 1 FROM file WHERE path = '/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/dialogcli';"
    install_software:
      package_path: ../lib/software/swiftdialog.yml   # url + hash_sha256 of a pinned release pkg
```

**2. Branding**: deploy [`examples/fleet/makemeanadmin.mobileconfig`](examples/fleet/makemeanadmin.mobileconfig) (new `PayloadUUID`s via `uuidgen`). It sets `companyName`, `companyLogo` and optional `companyLogoDark` in `/Library/Managed Preferences/com.makemeanadmin.plist`.
```yaml
controls:
  macos_settings:        # key name varies by Fleet version
    configuration_profiles:
      - path: ../lib/profiles/makemeanadmin.mobileconfig
```

**3. Self-service** (Premium): a script-only package, pinned to a tag and hash.
```yaml
# lib/software/makemeanadmin.yml
url: https://raw.githubusercontent.com/MrNRod/MakeMeAnAdmin/<tag>/MakeMeAnAdmin.sh
hash_sha256: <shasum -a 256 MakeMeAnAdmin.sh>
pre_install_query:
  path: ./swiftdialog-present.sql    # same SELECT as the policy above

# fleet YAML
software:
  packages:
    - path: ../lib/software/makemeanadmin.yml
      self_service: true
```

**4. `enforce` backstop** (Premium): build a second copy in CI and run it when a grant has expired or its daemon was removed.
```bash
sed 's/^defaultMode="request"/defaultMode="enforce"/' MakeMeAnAdmin.sh > lib/scripts/MakeMeAnAdmin-enforce.sh
```
```yaml
controls:
  scripts:
    - path: ../lib/scripts/MakeMeAnAdmin-enforce.sh
policies:
  - name: MakeMeAnAdmin - no expired or tampered grants
    platform: darwin
    query: |
      SELECT 1 WHERE NOT EXISTS (
        SELECT 1 FROM file_lines
        WHERE path = '/Library/Application Support/MakeMeAnAdmin/state'
          AND line LIKE 'expiry=%'
          AND (
            CAST(substr(line, 8) AS INTEGER) <= CAST(strftime('%s','now') AS INTEGER)
            OR NOT EXISTS (SELECT 1 FROM file WHERE path LIKE '/Library/LaunchDaemons/com.%.adminExpiryCheck.plist')
          )
      );
    run_script:
      path: ../lib/scripts/MakeMeAnAdmin-enforce.sh
```

**5. Alert on unexpected admins** (no automation; a user mid-grant fails it by design)
```yaml
policies:
  - name: MakeMeAnAdmin - only approved accounts are admins
    platform: darwin
    query: |
      SELECT 1 WHERE NOT EXISTS (
        SELECT 1 FROM users u
        JOIN user_groups ug ON ug.uid = u.uid
        JOIN groups g ON g.gid = ug.gid
        WHERE g.groupname = 'admin' AND u.username NOT IN ('root', 'itadmin')
      );
```

These were written from Fleet's public docs, not a live server. Check your version's YAML key names and that the profile produces the managed-preferences file on a test Mac.

# Other MDMs

- **Jamf Pro**: one policy with the script (and the SwiftDialog package), exposed in Self Service. Backstop: a second policy with `$8 = enforce` on Recurring Check-in, Ongoing.
- **Workspace ONE**: upload the script (System context); script variables arrive as environment variables. Backstop: a second copy with `mode=enforce` on a schedule.
- **Manual**: `sudo ./MakeMeAnAdmin.sh`, `sudo ./MakeMeAnAdmin.sh enforce`, or `./MakeMeAnAdmin.sh preview` (no root, changes nothing).

# Configuration

Precedence: script parameter (Jamf) → environment variable → managed preference `com.makemeanadmin` (Fleet) → default.

| Setting | Jamf | Description | Default |
| :--- | :--- | :--- | :--- |
| `companyName` | `$4` | Used in the LaunchDaemon label. Letters, digits, `.`, `_`, `-`. | `MrNRod` |
| `companyLogo` | `$5` | `https://` URL or absolute path to a PNG/JPEG. | lock icon |
| `companyLogoDark` | `$7` | Optional Dark Mode variant. | none |
| `mode` | `$8` | `request`, `enforce` or `preview` (or the first argument, or the `defaultMode` line). | `request` |

## Logos

A logo that breaks a limit is **rejected, not scaled or cropped**: the lock icon is used and the reason is logged. Limits follow common practice (SwiftDialog supports PNG and JPEG; Intune caps logos at 750 KB; Nudge warns about images over 1 MB).

| Limit | Value |
| :--- | :--- |
| Format (by content) | PNG or JPEG |
| File size | 750 KB |
| Shorter / longer side | 64 px / 2048 px |
| Aspect ratio (w:h) | 1:3 to 6:1 |
| Source | readable local path, or `https://` (15 s timeout) |

Wide logos are drawn up to 380 pt wide, square and tall ones up to 110 pt high, never above the image's own pixels (square 110×110, 3:1 330×110, 5:1 380×76, 1:2 55×110). Use a transparent PNG at about 2× the drawn size, with no empty padding. Try one with `companyLogo=/path/logo.png ./MakeMeAnAdmin.sh preview`.

# How it works

1. Finds the console user and verifies SwiftDialog. Refuses if the user is already an admin or already has a grant.
2. Prompts for a duration (30 minutes to 1 week) from a fixed list.
3. **Arms first**: writes state, a root-owned helper and a LaunchDaemon, and confirms `launchd` loaded it. Only then adds the user to `admin`. Any failure rolls back.
4. The daemon runs at boot and every 60 s. At expiry it removes the user, logs the session's sudo commands, reports accounts added to `admin` meanwhile, and deletes itself and all state.

# Security

| Bypass attempt | Defence |
| :--- | :--- |
| Re-run to extend | Refused while a grant is active. |
| Set the clock back | A backwards step over 2 minutes demotes immediately. |
| Edit the expiry | Grants over one week are treated as tampering and demoted. |
| Reboot or sleep | Absolute-timestamp expiry; the daemon runs at load. |
| Remove the daemon | `enforce` re-arms it and demotes if expired. |
| Failed setup leaves them admin | Daemon verified before elevation; failures roll back. |
| Wrong person demoted | User stored at grant time. |
| Injection via name, user, logo, dialog result | Strict patterns, fixed whitelist, content-checked `https` logos. |

**Limit:** while elevated, the user is an administrator and can run anything as root, including removing the daemon or creating another admin. The real backstop is your MDM: run `enforce`, and alert on the events `tamper-detected`, `demote-failed`, `unexpected-admin-added`, `state-tampered` and `clock-rewound`. Sudo logging records commands only (`/var/log/sudo_admin.log`).

# Logs and files

Events are CSV in `/Library/Logs/MakeMeAnAdmin/MakeMeAnAdminEvents.log` (`root:wheel 640`, rotated at 1 MB) and in the unified log under tag `MakeMeAnAdmin`. State, helper and daemon plist (`/Library/LaunchDaemons/com.<companyName>.adminExpiryCheck.plist`) exist only during a grant.

## Credits

Based on [Jamf's MakeMeAnAdmin](https://github.com/jamf/MakeMeAnAdmin). SwiftDialog by [Bart Reardon](https://github.com/swiftDialog/swiftDialog).
