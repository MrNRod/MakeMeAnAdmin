#!/bin/bash

###############################################################################
# MakeMeAnAdmin (SwiftDialog Edition)
#
# Grants the logged-in standard user temporary admin rights, then removes them
# automatically. Run as root from an MDM: Fleet (preferred), Jamf Pro,
# Workspace ONE, ...
#
# Modes (first argument, $8, $mode, or defaultMode below):
#   request   (default) prompt the user, grant admin, arm the demotion daemon
#   enforce   MDM backstop: re-arm the daemon if it was tampered with and
#             demote immediately if the grant has expired. Safe to run on a
#             recurring MDM schedule (it does nothing when no grant exists).
#   preview   show the dialogs only (no root, no changes) - for testing branding
#
# SwiftDialog is a REQUIREMENT, not something this script installs. Deploy it
# with your MDM before this script (see ReadMe.md for why).
###############################################################################

# Fixed PATH: nothing below should resolve through a caller-supplied PATH.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 022
set -u

#------------------------------------------------------------------------------
# Configuration
# Order of precedence:
#   1. MDM script parameter ($4, $5, $7, $8)   - Jamf Pro
#   2. environment variable                    - Workspace ONE, manual runs
#   3. managed preference (configuration profile, domain com.makemeanadmin)
#                                              - Fleet and any other MDM
#   4. default below
# Fleet cannot pass arguments to a script, so use (3) there. ($6 was
# "allowDialogInstall" in older versions; it is ignored now.)
#------------------------------------------------------------------------------
defaultMode="request"        # the Fleet "enforce" copy changes just this line (see ReadMe.md)
managedPrefs="/Library/Managed Preferences/com.makemeanadmin.plist"

# Read one key from the MDM-managed preference file. Only trusted if it is
# owned by root (users cannot write to /Library/Managed Preferences).
managed_pref() {
    [ -f "$managedPrefs" ] && [ "$(/usr/bin/stat -f%Su "$managedPrefs" 2>/dev/null)" = "root" ] || return 0
    /usr/bin/plutil -extract "$1" raw -o - "$managedPrefs" 2>/dev/null
}

case "${1:-}" in
    request|enforce|preview) mode="$1" ;;
    *) mode="${8:-${mode:-$defaultMode}}" ;;
esac
companyName="${4:-${companyName:-$(managed_pref companyName)}}"
companyName="${companyName:-MrNRod}"
companyLogo="${5:-${companyLogo:-$(managed_pref companyLogo)}}"
companyLogoDark="${7:-${companyLogoDark:-$(managed_pref companyLogoDark)}}"

durationOptions="30 minutes,1 hour,2 hours,4 hours,8 hours,1 day,1 week"
defaultDuration="1 hour"
promptTimeout=120            # seconds before an unanswered prompt closes (MDMs time scripts out)

# SwiftDialog (required). Always called by absolute path inside the root-owned
# app bundle - never via PATH or /usr/local/bin (which can be user-writable).
dialogApp="/Library/Application Support/Dialog/Dialog.app"
dialogBin="$dialogApp/Contents/MacOS/dialogcli"
dialogTeamID="PWA5E9TQ59"

# Dialog geometry. The logo is sized by WIDTH ("--iconsize"), height follows
# the image's aspect ratio, and the window height is exact, so both are
# computed from the logo's shape (see compute_layout).
winWidth=500
logoMaxW=380                 # widest a logo is drawn (pt); the window caps this at 80% of its width
logoMaxH=110                 # tallest a logo is drawn (pt)
logoUnknown=120              # size used when the logo's shape can't be read

#------------------------------------------------------------------------------
# Paths
#------------------------------------------------------------------------------
logDir="/Library/Logs/MakeMeAnAdmin"
logFile="$logDir/MakeMeAnAdminEvents.log"
archiveFile="$logDir/MakeMeAnAdminEvents_Archive.csv"
persist_dir="/Library/Application Support/MakeMeAnAdmin"
stateFile="$persist_dir/state"
lastSeenFile="$persist_dir/lastSeen"
snapshotFile="$persist_dir/adminSnapshot"
helperScript="$persist_dir/checkAdminExpiry.sh"
sudoLog="/var/log/sudo_admin.log"
sudoersFile="/etc/sudoers.d/admin_logging"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
say() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
    /usr/bin/logger -t MakeMeAnAdmin "$*" 2>/dev/null
}

die() {
    say "ERROR: $*"
    exit 1
}

csv() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }

is_admin() { /usr/sbin/dseditgroup -o checkmember -m "$1" admin 2>/dev/null | /usr/bin/grep -q '^yes'; }

log_event() { # user event duration commands
    local host ts
    host=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || /bin/hostname -s)
    ts=$(date -u '+%Y-%m-%d %H:%M:%S')
    [ -f "$logFile" ] || echo "timestamp,hostname,user,event,duration,command" > "$logFile"
    echo "$(csv "$ts"),$(csv "$host"),$(csv "$1"),$(csv "$2"),$(csv "$3"),$(csv "${4:-}")" >> "$logFile"
    chmod 640 "$logFile"
    say "event=$2 user=$1 duration=$3"
}

rotate_log() {
    local size
    [ -f "$logFile" ] || return 0
    size=$(stat -f%z "$logFile" 2>/dev/null || echo 0)
    if [ "$size" -ge 1000000 ]; then
        # keep the header only once in the archive
        if [ -f "$archiveFile" ]; then tail -n +2 "$logFile" >> "$archiveFile"; else cp "$logFile" "$archiveFile"; fi
        echo "timestamp,hostname,user,event,duration,command" > "$logFile"
        chmod 640 "$logFile" "$archiveFile"
    fi
}

duration_seconds() {
    case "$1" in
        "30 minutes") echo 1800 ;;
        "1 hour")     echo 3600 ;;
        "2 hours")    echo 7200 ;;
        "4 hours")    echo 14400 ;;
        "8 hours")    echo 28800 ;;
        "1 day")      echo 86400 ;;
        "1 week")     echo 604800 ;;
        *)            return 1 ;;   # anything not on the list is rejected
    esac
}

#------------------------------------------------------------------------------
# Validate configuration (company name ends up in file names and plist XML)
#------------------------------------------------------------------------------
if ! [[ "$companyName" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    die "companyName '$companyName' may only contain letters, digits, '.', '_' and '-'."
fi
case "$mode" in request|enforce|preview) ;; *) die "Unknown mode '$mode' (request|enforce|preview)." ;; esac

daemonLabel="com.${companyName}.adminExpiryCheck"
daemonPlist="/Library/LaunchDaemons/${daemonLabel}.plist"
lockDir="/var/run/${daemonLabel}.lock"

if [ "$mode" != "preview" ] && [ "$(id -u)" -ne 0 ]; then
    die "Must run as root (use 'preview' mode to test the dialogs without root)."
fi

#------------------------------------------------------------------------------
# Console user (never root / loginwindow)
#------------------------------------------------------------------------------
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
case "$consoleUser" in
    ""|root|loginwindow|_mbsetupuser) consoleUser="" ;;
esac
if [ "$mode" = "preview" ] && [ -z "$consoleUser" ]; then consoleUser=$(id -un); fi
if [ -n "$consoleUser" ] && ! [[ "$consoleUser" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "Unexpected console user name."
fi
consoleUID=""
[ -n "$consoleUser" ] && consoleUID=$(id -u "$consoleUser" 2>/dev/null)

run_as_user() {
    if [ "$(id -u)" -eq 0 ]; then
        /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
    else
        "$@"
    fi
}

#------------------------------------------------------------------------------
# SwiftDialog: required, verified, never installed from here
#------------------------------------------------------------------------------
verify_dialog() {
    [ -x "$dialogBin" ] || return 1
    /usr/bin/codesign --verify --strict "$dialogApp" >/dev/null 2>&1 || return 1
    /usr/bin/codesign -dv "$dialogApp" 2>&1 | /usr/bin/grep -q "^TeamIdentifier=$dialogTeamID\$"
}

#------------------------------------------------------------------------------
# Remote logos (https only). MDMs like Fleet cannot ship a file alongside a
# script, so a logo can be a URL. It is downloaded once, as the user, into a
# private temp dir, and its type is checked by CONTENT before it is used.
#------------------------------------------------------------------------------
logoCache=""
trap 'rm -rf "${logoCache:-}"' EXIT

# Must run in the main shell (not in $(...)) so the cleanup trap sees logoCache.
init_logo_cache() {
    [ -n "$logoCache" ] && return 0
    logoCache=$(mktemp -d /private/var/tmp/mma-logo.XXXXXX) || return 1
    [ "$(id -u)" -eq 0 ] && chown "$consoleUser" "$logoCache"
    chmod 700 "$logoCache"
}

# Runs inside $(...): messages go to stderr so only the path reaches stdout.
fetch_logo() { # url index -> prints local path on success
    local url="$1" n="$2" dl ext mime
    [[ "$url" == https://* ]] || { say "WARN: only https:// logo URLs are allowed ('$url')." >&2; return 1; }
    [ -n "$logoCache" ] || return 1
    dl="$logoCache/logo$n.download"
    run_as_user /usr/bin/curl -fsSL --proto '=https' --max-time 15 --max-filesize 5242880 -o "$dl" -- "$url" 2>/dev/null \
        || { say "WARN: could not download logo '$url'." >&2; return 1; }
    mime=$(run_as_user /usr/bin/file -b --mime-type "$dl" 2>/dev/null)
    case "$mime" in
        image/png) ext=png ;;  image/jpeg) ext=jpg ;;  image/gif) ext=gif ;;
        image/svg+xml) ext=svg ;;  application/pdf) ext=pdf ;;  image/tiff) ext=tiff ;;
        *) say "WARN: '$url' is not a supported image type ($mime)." >&2; return 1 ;;
    esac
    run_as_user /bin/mv -f "$dl" "$logoCache/logo$n.$ext" || return 1
    echo "$logoCache/logo$n.$ext"
}

#------------------------------------------------------------------------------
# Logo layout: choose icon size + window height from the logo's aspect ratio
#------------------------------------------------------------------------------
logo_arg=""      # value for --icon
logoSize=$logoUnknown
logoHeight=$logoUnknown

compute_layout() {
    local logo="$companyLogo" dark="$companyLogoDark" w="" h="" raster=0 out

    # remote logos become local files first, so they can be measured too
    if [[ "$logo$dark" == *://* ]]; then init_logo_cache; fi
    if [[ "$logo" == *://* ]]; then logo=$(fetch_logo "$logo" 1) || logo=""; fi
    if [[ "$dark" == *://* ]]; then dark=$(fetch_logo "$dark" 2) || dark=""; fi

    # fall back to a built-in symbol if the logo is unset / unreadable by the user
    if [ -z "$logo" ]; then
        logo_arg="SF=lock.shield"
    elif [[ "$logo" == SF=* ]]; then
        logo_arg="$logo"
    elif run_as_user /bin/test -r "$logo" 2>/dev/null; then
        logo_arg="$logo"
        out=$(run_as_user /usr/bin/sips -g pixelWidth -g pixelHeight "$logo" 2>/dev/null)
        w=$(echo "$out" | /usr/bin/awk '/pixelWidth/{print $2}')
        h=$(echo "$out" | /usr/bin/awk '/pixelHeight/{print $2}')
        case "$logo" in *.svg|*.SVG) raster=0 ;; *) raster=1 ;; esac
    else
        say "WARN: logo '$logo' is not readable by $consoleUser; using the default icon."
        logo_arg="SF=lock.shield"
    fi

    # optional dark-mode variant (SwiftDialog "light:dark=" syntax)
    if [ -n "$dark" ] && [ "$logo_arg" != "SF=lock.shield" ] && [[ "$logo_arg" != SF=* ]] && run_as_user /bin/test -r "$dark" 2>/dev/null; then
        logo_arg="${logo_arg}:dark=${dark}"
    fi

    # Size: wide logos are limited by width, square/tall logos by height.
    #   n = min(logoMaxW, logoMaxH * max(ratio,1)); never upscale a raster past 1x.
    if [[ "$w" =~ ^[0-9]+(\.[0-9]+)?$ && "$h" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        set -- $(/usr/bin/awk -v w="$w" -v h="$h" -v mw="$logoMaxW" -v mh="$logoMaxH" -v raster="$raster" '
            BEGIN {
                if (w <= 0 || h <= 0) { print 0, 0; exit }
                r = w / h; rr = (r > 1) ? r : 1
                n = mh * rr; if (n > mw) n = mw
                if (raster && w < n) n = w
                if (n < 32) n = 32
                ht = (r >= 1) ? n / r : n
                printf "%d %d\n", n + 0.5, ht + 0.5
            }')
        if [ "${1:-0}" -gt 0 ]; then logoSize=$1; logoHeight=$2; fi
    fi

    # ~290pt for title, message, dropdown and buttons, plus the logo. Spare
    # room is harmless (spacers); too little would squeeze the logo.
    winHeight=$(( 290 + logoHeight ))
    [ "$winHeight" -lt 350 ] && winHeight=350
    [ "$winHeight" -gt 480 ] && winHeight=480
}

dialog_ui() { # extra dialog args...
    run_as_user "$dialogBin" \
        --title "Make Me An Admin" --titlefont size=25 \
        --icon "$logo_arg" --iconsize "$logoSize" --iconalttext "$companyName logo" --centericon \
        --messagefont size=16 --alignment center \
        --width "$winWidth" --height "$winHeight" \
        --ontop --moveable \
        "$@"
}

show_message() { # message
    dialog_ui --message "$1" --button1text "OK" >/dev/null 2>&1
}

# prints the selected option; returns 1 if the user cancelled / timed out
prompt_duration() {
    local out rc choice
    out=$(dialog_ui \
        --message "Select how long you need admin access:\n\nRights are removed automatically when time is up." \
        --selecttitle "Duration" --selectvalues "$durationOptions" --selectdefault "$defaultDuration" \
        --button1text "Request" --button2text "Cancel" \
        --timer "$promptTimeout" --hidetimerbar 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || return 1
    # Output looks like:  "SelectedOption" : "1 hour"   (older versions: SelectedOption: 1 hour)
    choice=$(echo "$out" | /usr/bin/sed -n 's/^ *"\{0,1\}SelectedOption"\{0,1\} *: *"\{0,1\}\(.*[^"]\)"\{0,1\} *$/\1/p' | head -n 1)
    [ -n "$choice" ] || return 1
    echo "$choice"
}

format_expiry() { # epoch seconds
    if [ "$2" -ge 86400 ]; then date -r "$1" '+%A %b %-d at %-I:%M %p'; else date -r "$1" '+%-I:%M %p'; fi
}

#------------------------------------------------------------------------------
# Preview mode: dialogs only
#------------------------------------------------------------------------------
if [ "$mode" = "preview" ]; then
    verify_dialog || die "SwiftDialog $dialogTeamID not found/valid at '$dialogApp'."
    compute_layout
    say "preview: logo='$logo_arg' iconsize=$logoSize logoHeight=$logoHeight window=${winWidth}x${winHeight}"
    if choice=$(prompt_duration); then
        show_message "You now have administrative rights for **$choice**.\n\nThis is a preview - nothing was changed."
    fi
    exit 0
fi

#------------------------------------------------------------------------------
# Directories (root-owned; chflags cleared so a re-run can replace files)
#------------------------------------------------------------------------------
unlock_artifacts() { /usr/bin/chflags noschg "$helperScript" "$daemonPlist" 2>/dev/null; return 0; }
lock_artifacts()   { /usr/bin/chflags schg "$helperScript" "$daemonPlist" 2>/dev/null; return 0; }

for d in "$logDir" "$persist_dir"; do
    [ -L "$d" ] && die "$d is a symlink; refusing to continue."
    mkdir -p "$d" || die "Cannot create $d"
    chown root:wheel "$d"
    chmod 755 "$d"
done

# single instance
if ! mkdir "$lockDir" 2>/dev/null; then
    oldpid=$(cat "$lockDir/pid" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        say "Another MakeMeAnAdmin run is in progress (pid $oldpid)."
        exit 0
    fi
    rm -rf "$lockDir"; mkdir "$lockDir" || die "Cannot take lock."
fi
echo $$ > "$lockDir/pid"

provisioning=0
grantedUser=""
cleanup_exit() {
    if [ "$provisioning" -eq 1 ]; then
        say "Interrupted before the grant was fully armed - rolling back."
        rollback
    fi
    rm -rf "$lockDir" "${logoCache:-}"
}
trap cleanup_exit EXIT
trap 'exit 1' INT TERM HUP

rotate_log

#------------------------------------------------------------------------------
# State helpers
#------------------------------------------------------------------------------
state_get() { /usr/bin/awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$stateFile" 2>/dev/null; }

remove_artifacts() {
    unlock_artifacts
    /bin/launchctl bootout "system/$daemonLabel" 2>/dev/null
    rm -f "$stateFile" "$lastSeenFile" "$snapshotFile" "$helperScript" "$daemonPlist"
}

rollback() {
    [ -n "$grantedUser" ] && /usr/sbin/dseditgroup -o edit -d "$grantedUser" -t user admin >/dev/null 2>&1
    remove_artifacts
    provisioning=0
}

#------------------------------------------------------------------------------
# The demotion helper, run by launchd as root every 60s and at boot.
# Variables are baked in from this script, then the (quoted) body is appended,
# so nothing in the body is expanded at generation time.
#------------------------------------------------------------------------------
write_helper() {
    local tmp
    tmp=$(mktemp "$persist_dir/.helper.XXXXXX") || die "mktemp failed"
    {
        echo '#!/bin/bash'
        echo '# Generated by MakeMeAnAdmin.sh - do not edit; it is regenerated on every run.'
        printf 'LABEL=%q\n'     "$daemonLabel"
        printf 'PLIST=%q\n'     "$daemonPlist"
        printf 'STATE=%q\n'     "$stateFile"
        printf 'LASTSEEN=%q\n'  "$lastSeenFile"
        printf 'SNAPSHOT=%q\n'  "$snapshotFile"
        printf 'SELF=%q\n'      "$helperScript"
        printf 'LOGFILE=%q\n'   "$logFile"
        printf 'SUDOLOG=%q\n'   "$sudoLog"
        cat <<'HELPER_BODY'
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 022
MAX_SECONDS=604800        # no valid grant is longer than a week
CLOCK_SLACK=120           # tolerated backwards clock step (NTP corrections)

csv() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
is_admin() { /usr/sbin/dseditgroup -o checkmember -m "$1" admin 2>/dev/null | /usr/bin/grep -q '^yes'; }
get() { /usr/bin/awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$STATE" 2>/dev/null; }

log_event() { # user event duration commands
    local host ts
    host=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || /bin/hostname -s)
    ts=$(date -u '+%Y-%m-%d %H:%M:%S')
    [ -f "$LOGFILE" ] || echo "timestamp,hostname,user,event,duration,command" > "$LOGFILE"
    echo "$(csv "$ts"),$(csv "$host"),$(csv "$1"),$(csv "$2"),$(csv "$3"),$(csv "${4:-}")" >> "$LOGFILE"
    chmod 640 "$LOGFILE"
    /usr/bin/logger -t MakeMeAnAdmin "event=$2 user=$1 ${4:+detail=$4}"
}

teardown() {
    /usr/bin/chflags noschg "$SELF" "$PLIST" 2>/dev/null
    rm -f "$STATE" "$LASTSEEN" "$SNAPSHOT" "$SELF" "$PLIST"
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null   # last: this stops us
}

demote() {
    local i
    for i in 1 2 3; do
        /usr/sbin/dseditgroup -o edit -d "$1" -t user admin >/dev/null 2>&1
        is_admin "$1" || return 0
        sleep 2
    done
    return 1
}

main() {
    local now user start expiry duration offset last reason size cmds current extra

    if [ ! -f "$STATE" ]; then teardown; return 0; fi   # no grant -> nothing should be armed

    now=$(date +%s)
    user=$(get user); start=$(get start); expiry=$(get expiry)
    duration=$(get duration); offset=$(get sudoOffset)
    last=$(cat "$LASTSEEN" 2>/dev/null)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    reason=""
    if ! [[ "$user" =~ ^[A-Za-z0-9._-]+$ && "$start" =~ ^[0-9]+$ && "$expiry" =~ ^[0-9]+$ ]]; then
        reason="state-corrupt"
    elif [ "$expiry" -le "$start" ] || [ $((expiry - start)) -gt "$MAX_SECONDS" ]; then
        reason="state-tampered"
    elif [ "$now" -ge "$expiry" ]; then
        reason="expired"
    elif [ "$last" -gt $((now + CLOCK_SLACK)) ]; then
        reason="clock-rewound"        # fail closed: wall clock moved backwards
    fi

    if [ -z "$reason" ]; then
        [ "$now" -gt "$last" ] && echo "$now" > "$LASTSEEN"
        return 0
    fi

    # Without a trustworthy user name there is nobody safe to demote.
    if ! [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_event "unknown" "state-invalid" "" "$reason"
        teardown; return 0
    fi

    if ! demote "$user"; then
        log_event "$user" "demote-failed" "$duration" "$reason (will retry)"
        return 1                       # keep the daemon armed; launchd retries
    fi

    # Commands the user ran through sudo during the window (byte offset recorded at grant)
    cmds=""
    if [ -f "$SUDOLOG" ] && [[ "$offset" =~ ^[0-9]+$ ]]; then
        size=$(stat -f%z "$SUDOLOG" 2>/dev/null || echo 0)
        [ "$size" -lt "$offset" ] && offset=0
        cmds=$(tail -c "+$((offset + 1))" "$SUDOLOG" 2>/dev/null | /usr/bin/grep -F -- " : $user : " | tr '\n' ';' | head -c 8000)
    fi
    log_event "$user" "demoted" "$duration" "reason=$reason; ${cmds}"

    # Anyone newly added to admin during the window (e.g. a backdoor account)?
    if [ -f "$SNAPSHOT" ]; then
        current=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null | sed 's/^GroupMembership: *//' | tr ' ' '\n' | /usr/bin/grep -v '^$' | sort)
        extra=$(comm -13 <(sort "$SNAPSHOT") <(echo "$current") | /usr/bin/grep -vx -- "$user" | tr '\n' ' ')
        [ -n "$extra" ] && log_event "$user" "unexpected-admin-added" "" "$extra"
    fi

    teardown
    return 0
}

main "$@"
exit $?
HELPER_BODY
    } > "$tmp"
    chown root:wheel "$tmp"; chmod 755 "$tmp"
    mv -f "$tmp" "$helperScript"
}

write_daemon() {
    local tmp
    tmp=$(mktemp "$persist_dir/.plist.XXXXXX") || die "mktemp failed"
    cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${daemonLabel}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${helperScript}</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF
    /usr/bin/plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die "Generated plist is invalid."; }
    chown root:wheel "$tmp"; chmod 644 "$tmp"
    mv -f "$tmp" "$daemonPlist"
}

# (Re)install helper + daemon and confirm launchd really loaded it.
arm_daemon() {
    unlock_artifacts
    /bin/launchctl bootout "system/$daemonLabel" 2>/dev/null
    write_helper
    write_daemon
    /bin/launchctl bootstrap system "$daemonPlist" || return 1
    /bin/launchctl print "system/$daemonLabel" >/dev/null 2>&1 || return 1
    lock_artifacts
    return 0
}

setup_sudo_logging() {
    # Command-only audit log. (Older versions also enabled log_input/log_output
    # for every sudo user, which records typed secrets; that is removed.)
    local want='Defaults logfile="/var/log/sudo_admin.log"' tmp
    if [ "$(cat "$sudoersFile" 2>/dev/null)" != "$want" ]; then
        tmp=$(mktemp "$persist_dir/.sudoers.XXXXXX") || return 1
        echo "$want" > "$tmp"
        if /usr/sbin/visudo -cf "$tmp" >/dev/null 2>&1; then
            /usr/bin/install -m 440 -o root -g wheel "$tmp" "$sudoersFile"
        else
            say "WARN: sudoers logging snippet failed validation; not installed."
        fi
        rm -f "$tmp"
    fi
    [ -f "$sudoLog" ] || touch "$sudoLog"
    chown root:wheel "$sudoLog"; chmod 600 "$sudoLog"
}

#------------------------------------------------------------------------------
# enforce mode (MDM backstop)
#------------------------------------------------------------------------------
if [ "$mode" = "enforce" ]; then
    if [ ! -f "$stateFile" ]; then
        # nothing granted; make sure no stale daemon is left behind
        if [ -f "$daemonPlist" ] || [ -f "$helperScript" ]; then
            say "enforce: no active grant; removing stale daemon files."
            remove_artifacts
        fi
        exit 0
    fi
    user=$(state_get user)
    if [ ! -f "$daemonPlist" ] || [ ! -f "$helperScript" ] || ! /bin/launchctl print "system/$daemonLabel" >/dev/null 2>&1; then
        log_event "${user:-unknown}" "tamper-detected" "" "demotion daemon was missing or unloaded; re-arming"
    fi
    arm_daemon || die "enforce: could not re-arm the daemon."
    /bin/bash "$helperScript"      # demotes right now if already expired
    exit 0
fi

#------------------------------------------------------------------------------
# request mode
#------------------------------------------------------------------------------
[ -n "$consoleUser" ] || die "No user is logged in at the console."
verify_dialog || die "SwiftDialog (Team ID $dialogTeamID) is required but was not found or failed signature verification at '$dialogApp'. Deploy it with your MDM first."
compute_layout

# Existing grant? Clear it if expired, otherwise refuse to extend it.
if [ -f "$stateFile" ]; then
    arm_daemon >/dev/null 2>&1
    /bin/bash "$helperScript"                         # demotes now if expired
    if [ -f "$stateFile" ]; then
        remaining=$(( $(state_get expiry) - $(date +%s) ))
        say "Request refused: a grant for $(state_get user) is already active."
        show_message "You already have administrative rights.\n\nThey end at **$(format_expiry "$(state_get expiry)" "$remaining")**. A new request can be made after that."
        exit 0
    fi
fi

if is_admin "$consoleUser"; then
    say "$consoleUser is already an administrator; nothing to do."
    show_message "Your account already has administrator rights, so no temporary access is needed."
    exit 0
fi

choice=$(prompt_duration) || { say "User cancelled or the prompt timed out."; exit 0; }
interval=$(duration_seconds "$choice") || die "Unexpected duration selection '$choice'."

start=$(date +%s)
expiry=$((start + interval))

#------------------------------------------------------------------------------
# Arm first, verify, THEN elevate. Any failure rolls the grant back.
#------------------------------------------------------------------------------
provisioning=1
grantedUser="$consoleUser"

sudoOffset=$(stat -f%z "$sudoLog" 2>/dev/null || echo 0)
setup_sudo_logging
sudoOffset=$(stat -f%z "$sudoLog" 2>/dev/null || echo "$sudoOffset")

dscl . -read /Groups/admin GroupMembership 2>/dev/null | sed 's/^GroupMembership: *//' | tr ' ' '\n' | /usr/bin/grep -v '^$' | sort > "$snapshotFile"
umask 077
{
    echo "user=$consoleUser"
    echo "start=$start"
    echo "expiry=$expiry"
    echo "duration=$choice"
    echo "sudoOffset=$sudoOffset"
} > "$stateFile"
echo "$start" > "$lastSeenFile"
umask 022
chown root:wheel "$stateFile" "$lastSeenFile" "$snapshotFile"; chmod 600 "$stateFile" "$lastSeenFile" "$snapshotFile"

if ! arm_daemon; then
    rollback
    show_message "Admin access could not be set up, so nothing was changed. Please contact IT."
    die "Could not arm the demotion daemon; rolled back."
fi

/usr/sbin/dseditgroup -o edit -a "$consoleUser" -t user admin
if ! is_admin "$consoleUser"; then
    rollback
    show_message "Admin access could not be granted. Please contact IT."
    die "dseditgroup did not add $consoleUser to admin; rolled back."
fi

provisioning=0   # fully armed and granted
log_event "$consoleUser" "elevated" "$choice" ""

show_message "You now have administrative rights until **$(format_expiry "$expiry" "$interval")** ($choice).\n\nAdministrative actions are logged and rights are removed automatically."
exit 0
