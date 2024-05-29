#!/usr/local/bin/bash

# Get the directory of the script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Set paths relative to the script directory
PROJECT_DIR="${SCRIPT_DIR}"
BUILD_DIR="${HOME}/Library/Developer/Xcode/DerivedData/MidiMapper-eatjinxpgaantqdomgoihvksjeqc/Build/Products/Release"
EXECUTABLE_NAME="MidiMapper"
DEST_DIR="/usr/local/bin"
PLIST_SRC="${PROJECT_DIR}/com.nickpeirson.MidiMapper.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.nickpeirson.MidiMapper.plist"

# Copy the executable
echo "Copying executable to ${DEST_DIR}"
cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${DEST_DIR}"

# Copy the plist file
echo "Copying plist to ${PLIST_DEST}"
cp "${PLIST_SRC}" "${PLIST_DEST}"

# Provide feedback
echo "Install complete."
