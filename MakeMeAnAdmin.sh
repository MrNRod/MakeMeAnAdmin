#!/bin/bash

###############################################
# This script will provide temporary admin    #
# rights to a standard user right from self   #
# service. First it will grab the username of #
# the logged in user, elevate them to admin   #
# and then create a launch daemon that will   #
# count down from the selected time and then  #
# create and run a secondary script that will #
# demote the user back to a standard account. #
# The launch daemon will continue to count    #
# down no matter how often the user logs out  #
# or restarts their computer.                 #
###############################################

# Variable Initialization
# Logic: Check Jamf Script Parameter ($4-$6) -> Check Environment Variable -> Default Value
# This single line handles both Jamf Pro (parameters) and Workspace ONE (script variables/environment vars).
companyName="${4:-"${companyName:-"mrnrod45"}"}"
companyLogo="${5:-"${companyLogo:-""}"}"
allowDialogInstall="${6:-"${allowDialogInstall:-"true"}"}"

######################################################
# Create a directory to store the MakeMeAnAdmin logs   #
######################################################

logDir="/Library/Logs/MakeMeAnAdmin"
mkdir -p "$logDir"
chmod 755 "$logDir"

logFile="$logDir/MakeMeAnAdminEvents.log"
archiveFile="$logDir/MakeMeAnAdminEvents_Archive.csv"

######################################################
# Create a directory to store the MakeMeAnAdmin files  #
######################################################

persist_dir="/Library/Application Support/MakeMeAnAdmin"
mkdir -p "$persist_dir"
chmod 755 "$persist_dir"

expiryFile="$persist_dir/adminExpireAt"
elevationTimestampFile="$persist_dir/adminStartTime"

#############################################
# find the logged in user and let them know #
#############################################

currentUser=$(who | awk '/console/{print $1}')
echo $currentUser

######################################
# Check if SwiftDialog is installed  #
######################################

if ! command -v dialog &> /dev/null; then
    if [ "$allowDialogInstall" = "true" ]; then
        echo "SwiftDialog not found. Installing..."

        # Fetch latest SwiftDialog .pkg URL from GitHub
        pkg_url=$(curl -s https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest \
            | grep 'browser_download_url' \
            | grep '.pkg' \
            | awk -F'"' '{print $4}' \
            | grep "dialog-.*\.pkg$" \
            | head -n 1)

        # Download latest SwiftDialog package
        temp_pkg="/tmp/SwiftDialog.pkg"
        curl -Ls -o "$temp_pkg" "$pkg_url"

        # Install it
        installer -pkg "$temp_pkg" -target /

        #Clean up
        rm -f "$temp_pkg"

        # Verify again
        if ! command -v dialog &> /dev/null; then
            echo "Failed to install SwiftDialog"
            exit 1
        fi
    else
        echo "SwiftDialog not found and auto-install is disabled."
        exit 1
    fi
fi

###########################################
# prompt user to select admin time limit #
###########################################

timeChoice=$(dialog \
--title "Make Me Admin" \
--titlefont size=25 \
--icon ${companyLogo} \
--iconsize 250 \
--centericon \
--message "Select how long you need admin access:" \
--alignment center \
--selecttitle "Duration" \
--selectvalues "30 minutes,1 hour,2 hours,4 hours,8 hours,1 day,1 week" \
--button1text "Request" \
--button2text "Cancel" \
--height 300 \
--width 450)

# extract value (SwiftDialog returns 'SelectedOption: <value>')
timeChoice=$(echo "$timeChoice" | awk -F': ' '/SelectedOption/ {print $2}')

if [ -z "$timeChoice" ]; then
    echo "User canceled admin request."
    exit 0
fi

# convert time choice to seconds
case "$timeChoice" in
    "30 minutes") interval=1800 ;;
    "1 hour")     interval=3600 ;;
    "2 hours")    interval=7200 ;;
    "4 hours")    interval=14400 ;;
    "8 hours")    interval=28800 ;;
    "1 day")      interval=86400 ;;
    "1 week")     interval=604800 ;;
    *)            interval=1800 ;; # default fallback
esac

# Write expiration timestamp to file
expiryEpoch=$(($(date +%s) + $interval))
echo "$expiryEpoch" > "$expiryFile"
chmod 644 "$expiryFile"

# Notify user using SwiftDialog instead of AppleScript
dialog \
--title "Access Granted" \
--titlefont size=25 \
--icon ${companyLogo} \
--iconsize 250 \
--centericon \
--message "You now have administrative rights for $timeChoice. DO NOT ABUSE THIS PRIVILEGE." \
--messagefont size=17 \
--alignment center \
--height 300 \
--width 450 \
--button1text "OK"

#########################################################
# write a daemon that will let you remove the privilege #
# with another script and chmod/chown to make 			    #
# sure it'll run, then load it and it will demote user  #
# when timer ends											                  #
#########################################################

cat > /Library/LaunchDaemons/com.${companyName}.adminExpiryCheck.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.${companyName}.adminExpiryCheck</string>
    <key>ProgramArguments</key>
    <array>
        <string>$persist_dir/checkAdminExpiry.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

chmod 644 /Library/LaunchDaemons/com.${companyName}.adminExpiryCheck.plist
chown root:wheel /Library/LaunchDaemons/com.${companyName}.adminExpiryCheck.plist

cat > "$persist_dir/checkAdminExpiry.sh" <<'EOF'
#!/bin/bash

expiryFile="$persist_dir/adminExpireAt"
logFile="/Library/Logs/MakeMeAnAdmin/MakeMeAnAdminEvents.log"
sudo_log="/var/log/sudo_admin.log"

if [ -f "$expiryFile" ]; then
  currentEpoch=$(date +%s)
  expiryEpoch=$(cat "$expiryFile")
  if [ "$currentEpoch" -ge "$expiryEpoch" ]; then
    currentUser=$(/bin/ls -l /dev/console | /usr/bin/awk '{ print $3 }')

    # Remove admin privileges
    /usr/sbin/dseditgroup -o edit -d "$currentUser" -t user admin

    # Log demotion event
    timestamp=$(date -u "+%Y-%m-%d %H:%M:%S")
    hostname=$(scutil --get LocalHostName)
    event="demoted"

    # Get elevation time (if available)
    elevationTimestampFile="$persist_dir/adminStartTime"
    if [ -f "$sudo_log" ] && [ -f "$elevationTimestampFile" ]; then
      granted_at=$(cat "$elevationTimestampFile")
      # Filter sudo log entries after elevation time (BSD awk friendly)
      session_commands=$(awk -v user="$currentUser" -v start="$granted_at" '
        $0 ~ user {
          if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
            ts = substr($0, RSTART, RLENGTH)
            gsub(/[-:]/, " ", ts)
            split(ts, a, " ")
            cmd_epoch = mktime(a[1] " " a[2] " " a[3] " " a[4] " " a[5] " " a[6])
            if (cmd_epoch >= start) print $0
          }
        }' "$sudo_log" | tr '\n' ';')
    else
      session_commands=""
    fi

    # Write to CSV log
    if [ ! -f "$logFile" ]; then
      echo "timestamp,hostname,user,event,duration,command" > "$logFile"
    fi
    echo "$timestamp,$hostname,$currentUser,$event,,\"$session_commands\"" >> "$logFile"

    # Clean up
    rm -f "$expiryFile"
    rm -f "$elevationTimestampFile"
    rm -f $persist_dir/checkAdminExpiry.sh
    rm -f /Library/LaunchDaemons/com.${companyName}.adminExpiryCheck.plist
  fi
fi
EOF

chmod +x "$persist_dir/checkAdminExpiry.sh"
chown root:wheel "$persist_dir/checkAdminExpiry.sh"

######################################################
# write the script that will do the actual demotion  #
# and then clean up the LaunchDaemon and itself      #
######################################################

cat > "$persist_dir/removeAdmin.sh" <<EOF
#!/bin/bash
/usr/sbin/dseditgroup -o edit -d $currentUser -t user admin
rm /Library/LaunchDaemons/com.${companyName}.adminRemoval.plist
rm $persist_dir/removeAdmin.sh
EOF

chmod +x "$persist_dir/removeAdmin.sh"
chown root:wheel "$persist_dir/removeAdmin.sh"

########################################################################
# elevate user and record timestamp unload the daemon before loading   #
########################################################################

/usr/sbin/dseditgroup -o edit -a $currentUser -t user admin
elevationTimestamp=$(date +%s)
echo "$elevationTimestamp" > "$elevationTimestampFile"
launchctl bootout system /Library/LaunchDaemons/com.${companyName}.adminExpiryCheck.plist 2>/dev/null
launchctl bootstrap system /Library/LaunchDaemons/com.${companyName}.adminExpiryCheck.plist

########################################################
# Configure sudo logging (if not already configured)   #
########################################################

sudoers_log="/etc/sudoers.d/admin_logging"
if [ ! -f "$sudoers_log" ]; then
    echo 'Defaults logfile="/var/log/sudo_admin.log"' > "$sudoers_log"
    echo 'Defaults log_input,log_output' >> "$sudoers_log"
    chmod 440 "$sudoers_log"
fi

###############################
# write to a log for tracking #
###############################

timestamp=$(date -u "+%Y-%m-%d %H:%M:%S")
hostname=$(scutil --get LocalHostName)
event="elevated"
logFile="/Library/Logs/MakeMeAnAdmin/MakeMeAnAdminEvents.log"
if [ ! -f "$logFile" ]; then
    echo "timestamp,hostname,user,event,duration,command" > "$logFile"
fi

echo "$timestamp,$hostname,$currentUser,$event,$timeChoice," >> "$logFile"

archiveFile="/Library/Logs/MakeMeAnAdmin/MakeMeAnAdminEvents_Archive.csv"

##############################
# Archive if log exceeds 1MB #
##############################

if [ -f "$logFile" ]; then
    fileSize=$(stat -f%z "$logFile")
    if [ "$fileSize" -ge 1000000 ]; then
        cat "$logFile" >> "$archiveFile"
        echo "" > "$logFile"
    fi
fi
