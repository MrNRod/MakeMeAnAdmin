#!/bin/bash

# MakeMeAnAdmin: temporary admin rights with automatic demotion.
# Modes (first arg, $8, $mode or defaultMode): request (default), enforce, preview.
# Requires SwiftDialog.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 022
set -u

# Precedence: parameter ($4 $5 $7 $8) > environment > managed preference > default.
defaultMode="request"        # the Fleet "enforce" copy changes just this line
managedPrefs="/Library/Managed Preferences/com.makemeanadmin.plist"

# Managed preferences are trusted only if root-owned.
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
promptTimeout=120            # seconds

dialogApp="/Library/Application Support/Dialog/Dialog.app"
dialogBin="$dialogApp/Contents/MacOS/dialogcli"
dialogTeamID="PWA5E9TQ59"

# Logos outside these limits are rejected (built-in icon used), never scaled or cropped.
logoMaxBytes=768000          # 750 KB
logoMinPx=64                 # shorter side
logoMaxPx=2048               # longer side
logoMinRatio=0.33            # width/height: 1:3 ...
logoMaxRatio=6               # ... to 6:1

# Dialog geometry in points; icon size and window height are derived from the logo (compute_layout).
winWidth=500
logoMaxW=380                 # widest logo (window allows 80% of its width)
logoMaxH=110                 # tallest logo
defaultIconSize=120

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
        *)            return 1 ;;
    esac
}

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

verify_dialog() {
    [ -x "$dialogBin" ] || return 1
    /usr/bin/codesign --verify --strict "$dialogApp" >/dev/null 2>&1 || return 1
    /usr/bin/codesign -dv "$dialogApp" 2>&1 | /usr/bin/grep -q "^TeamIdentifier=$dialogTeamID\$"
}

logoCache=""
trap 'rm -rf "${logoCache:-}"' EXIT

# Must run in the main shell, not in $(...), so the exit trap sees logoCache.
init_logo_cache() {
    [ -n "$logoCache" ] && return 0
    logoCache=$(mktemp -d /private/var/tmp/mma-logo.XXXXXX) || return 1
    [ "$(id -u)" -eq 0 ] && chown "$consoleUser" "$logoCache"
    chmod 700 "$logoCache"
}

image_ext() { # file -> png|jpg, judged by content
    case "$(run_as_user /usr/bin/file -b --mime-type "$1" 2>/dev/null)" in
        image/png)  echo png ;;
        image/jpeg) echo jpg ;;
        *)          return 1 ;;
    esac
}

fetch_logo() { # url n -> local path; warnings go to stderr because stdout is captured
    local url="$1" dl="$logoCache/logo$2" ext
    [[ "$url" == https://* ]] || { say "WARN: logo URL must be https:// ('$url')." >&2; return 1; }
    run_as_user /usr/bin/curl -fsSL --proto '=https' --max-time 15 --max-filesize "$logoMaxBytes" -o "$dl" -- "$url" 2>/dev/null \
        || { say "WARN: could not download logo '$url'." >&2; return 1; }
    ext=$(image_ext "$dl") || { say "WARN: '$url' is not a PNG or JPEG." >&2; return 1; }
    run_as_user /bin/mv -f "$dl" "$dl.$ext" && echo "$dl.$ext"
}

# Sets chkW/chkH; returns 1 with a warning if the logo breaks a limit.
check_logo() {
    local f="$1" bytes out
    run_as_user /bin/test -r "$f" || { say "WARN: logo '$f' is not readable by $consoleUser."; return 1; }
    bytes=$(run_as_user /usr/bin/stat -f%z "$f")
    [ "$bytes" -le "$logoMaxBytes" ] || { say "WARN: logo is $((bytes / 1024)) KB; the limit is $((logoMaxBytes / 1024)) KB."; return 1; }
    image_ext "$f" >/dev/null || { say "WARN: logo '$f' is not a PNG or JPEG."; return 1; }
    out=$(run_as_user /usr/bin/sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null)
    chkW=$(echo "$out" | /usr/bin/awk '/pixelWidth/{print $2}')
    chkH=$(echo "$out" | /usr/bin/awk '/pixelHeight/{print $2}')
    [[ "$chkW" =~ ^[0-9]+$ && "$chkH" =~ ^[0-9]+$ && "$chkW" -gt 0 && "$chkH" -gt 0 ]] \
        || { say "WARN: could not read the logo's dimensions."; return 1; }
    /usr/bin/awk -v w="$chkW" -v h="$chkH" -v minpx="$logoMinPx" -v maxpx="$logoMaxPx" -v minr="$logoMinRatio" -v maxr="$logoMaxRatio" '
        BEGIN { s = (w < h) ? w : h; l = (w > h) ? w : h; r = w / h
                exit !(s >= minpx && l <= maxpx && r >= minr && r <= maxr) }' \
        || { say "WARN: logo is ${chkW}x${chkH}px; allowed is shorter side >= ${logoMinPx}, longer side <= ${logoMaxPx}, ratio 1:3 to 6:1."; return 1; }
}

logo_arg="SF=lock.shield"
logoSize=$defaultIconSize
logoHeight=$defaultIconSize

compute_layout() {
    local logo="$companyLogo" dark="$companyLogoDark" w h

    if [[ "$logo$dark" == *://* ]]; then init_logo_cache; fi
    if [[ "$logo" == *://* ]]; then logo=$(fetch_logo "$logo" 1) || logo=""; fi
    if [[ "$dark" == *://* ]]; then dark=$(fetch_logo "$dark" 2) || dark=""; fi

    if [ -n "$logo" ] && check_logo "$logo"; then
        w=$chkW; h=$chkH
        logo_arg="$logo"
        if [ -n "$dark" ] && check_logo "$dark"; then logo_arg="$logo:dark=$dark"; fi

        # size = min(logoMaxW, logoMaxH * max(ratio,1)), never above the image's own pixels
        set -- $(/usr/bin/awk -v w="$w" -v h="$h" -v mw="$logoMaxW" -v mh="$logoMaxH" '
            BEGIN {
                r = w / h; n = mh * ((r > 1) ? r : 1); if (n > mw) n = mw
                px = (r >= 1) ? w : h; if (px < n) n = px
                printf "%d %d\n", n + 0.5, ((r >= 1) ? n / r : n) + 0.5
            }')
        logoSize=$1; logoHeight=$2
    fi

    # 290pt for everything but the logo; spare room is harmless, too little squeezes the logo
    winHeight=$(( 290 + logoHeight ))
    [ "$winHeight" -lt 390 ] && winHeight=390
    [ "$winHeight" -gt 480 ] && winHeight=480
}

dialog_ui() {
    run_as_user "$dialogBin" \
        --title "Make Me An Admin" --titlefont size=25 \
        --icon "$logo_arg" --iconsize "$logoSize" --iconalttext "$companyName logo" --centericon \
        --messagefont size=16 --alignment center \
        --width "$winWidth" --height "$winHeight" \
        --ontop --moveable \
        "$@"
}

show_message() {
    dialog_ui --message "$1" --button1text "OK" >/dev/null 2>&1
}

prompt_duration() {
    local out rc choice
    out=$(dialog_ui \
        --message "Select how long you need admin access:\n\nRights are removed automatically when time is up." \
        --selecttitle "Duration" --selectvalues "$durationOptions" --selectdefault "$defaultDuration" \
        --button1text "Request" --button2text "Cancel" \
        --timer "$promptTimeout" --hidetimerbar 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || return 1
    # output: "SelectedOption" : "1 hour"  (older SwiftDialog: SelectedOption: 1 hour)
    choice=$(echo "$out" | /usr/bin/sed -n 's/^ *"\{0,1\}SelectedOption"\{0,1\} *: *"\{0,1\}\(.*[^"]\)"\{0,1\} *$/\1/p' | head -n 1)
    [ -n "$choice" ] || return 1
    echo "$choice"
}

format_expiry() { # epoch seconds
    if [ "$2" -ge 86400 ]; then date -r "$1" '+%A %b %-d at %-I:%M %p'; else date -r "$1" '+%-I:%M %p'; fi
}

if [ "$mode" = "preview" ]; then
    verify_dialog || die "SwiftDialog $dialogTeamID not found/valid at '$dialogApp'."
    compute_layout
    say "preview: logo='$logo_arg' iconsize=$logoSize logoHeight=$logoHeight window=${winWidth}x${winHeight}"
    if choice=$(prompt_duration); then
        show_message "You now have administrative rights for **$choice**.\n\nThis is a preview - nothing was changed."
    fi
    exit 0
fi

for d in "$logDir" "$persist_dir"; do
    [ -L "$d" ] && die "$d is a symlink; refusing to continue."
    mkdir -p "$d" || die "Cannot create $d"
    chown root:wheel "$d"
    chmod 755 "$d"
done

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

state_get() { /usr/bin/awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$stateFile" 2>/dev/null; }

remove_artifacts() {
    /bin/launchctl bootout "system/$daemonLabel" 2>/dev/null
    rm -f "$stateFile" "$lastSeenFile" "$snapshotFile" "$helperScript" "$daemonPlist"
}

rollback() {
    [ -n "$grantedUser" ] && /usr/sbin/dseditgroup -o edit -d "$grantedUser" -t user admin >/dev/null 2>&1
    remove_artifacts
    provisioning=0
}

# Variables are baked in, then a quoted body is appended, so nothing in the body expands here.
write_helper() {
    local tmp
    tmp=$(mktemp "$persist_dir/.helper.XXXXXX") || die "mktemp failed"
    {
        echo '#!/bin/bash'
        echo '# Generated by MakeMeAnAdmin.sh; regenerated on every run.'
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
MAX_SECONDS=604800        # longest valid grant
CLOCK_SLACK=120           # tolerated backwards clock step

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
    rm -f "$STATE" "$LASTSEEN" "$SNAPSHOT" "$SELF" "$PLIST"
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null   # last: stops this process
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

    if [ ! -f "$STATE" ]; then teardown; return 0; fi

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
        reason="clock-rewound"
    fi

    if [ -z "$reason" ]; then
        [ "$now" -gt "$last" ] && echo "$now" > "$LASTSEEN"
        return 0
    fi

    if ! [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_event "unknown" "state-invalid" "" "$reason"
        teardown; return 0
    fi

    if ! demote "$user"; then
        log_event "$user" "demote-failed" "$duration" "$reason (will retry)"
        return 1                       # stay armed; launchd retries
    fi

    cmds=""
    if [ -f "$SUDOLOG" ] && [[ "$offset" =~ ^[0-9]+$ ]]; then
        size=$(stat -f%z "$SUDOLOG" 2>/dev/null || echo 0)
        [ "$size" -lt "$offset" ] && offset=0
        cmds=$(tail -c "+$((offset + 1))" "$SUDOLOG" 2>/dev/null | /usr/bin/grep -F -- " : $user : " | tr '\n' ';' | head -c 8000)
    fi
    log_event "$user" "demoted" "$duration" "reason=$reason; ${cmds}"

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

arm_daemon() {
    /bin/launchctl bootout "system/$daemonLabel" 2>/dev/null
    write_helper
    write_daemon
    /bin/launchctl bootstrap system "$daemonPlist" || return 1
    /bin/launchctl print "system/$daemonLabel" >/dev/null 2>&1
}

setup_sudo_logging() {
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

if [ "$mode" = "enforce" ]; then
    if [ ! -f "$stateFile" ]; then
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
    /bin/bash "$helperScript"
    exit 0
fi

[ -n "$consoleUser" ] || die "No user is logged in at the console."
verify_dialog || die "SwiftDialog (Team ID $dialogTeamID) is required but was not found or failed signature verification at '$dialogApp'. Deploy it with your MDM first."
compute_layout

if [ -f "$stateFile" ]; then
    arm_daemon >/dev/null 2>&1
    /bin/bash "$helperScript"
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

provisioning=0
log_event "$consoleUser" "elevated" "$choice" ""

show_message "You now have administrative rights until **$(format_expiry "$expiry" "$interval")** ($choice).\n\nAdministrative actions are logged and rights are removed automatically."
exit 0
