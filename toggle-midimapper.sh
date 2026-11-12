#!/bin/bash
set -euo pipefail

PLIST_PATH="$HOME/Library/LaunchAgents/com.nickpeirson.midimapper.plist"
LABEL="com.nickpeirson.MidiMapper"
SERVICE="gui/$(id -u)/$LABEL"

if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
    /bin/launchctl bootout "$SERVICE"
    echo "MidiMapper unloaded."
else
    /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    echo "MidiMapper loaded."
fi
