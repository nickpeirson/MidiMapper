#!/usr/local/bin/bash

# Define the plist path and label
PLIST_PATH="$HOME/Library/LaunchAgents/com.nickpeirson.MidiMapper.plist"
LABEL="com.nickpeirson.MidiMapper"

# Check if the service is loaded
if launchctl list | grep -q "$LABEL"; then
    echo "MidiMapper is currently loaded. Unloading..."
    launchctl unload "$PLIST_PATH"
    if [ $? -eq 0 ]; then
        echo "MidiMapper unloaded successfully."
    else
        echo "Failed to unload MidiMapper."
    fi
else
    echo "MidiMapper is currently unloaded. Loading..."
    launchctl load "$PLIST_PATH"
    if [ $? -eq 0 ]; then
        echo "MidiMapper loaded successfully."
    else
        echo "Failed to load MidiMapper."
    fi
fi
