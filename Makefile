SHELL := /bin/bash

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
WORKSPACE := $(PROJECT_ROOT)/MidiMapper.xcworkspace
SCHEME := MidiMapper (Release)
CONFIGURATION := Release
BUILD_ROOT := $(PROJECT_ROOT)/build
BUILD_DIR := $(BUILD_ROOT)/DerivedData
BINARY := $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/MidiMapper

LAUNCH_AGENT_LABEL := com.nickpeirson.MidiMapper
USER_ID := $(shell id -u)
INSTALL_PATH := /usr/local/bin/MidiMapper
LAUNCH_AGENT_SOURCE := $(PROJECT_ROOT)/com.nickpeirson.MidiMapper.plist
LAUNCH_AGENT_DEST := $(HOME)/Library/LaunchAgents/$(LAUNCH_AGENT_LABEL).plist

.DEFAULT_GOAL := help
.PHONY: help pods build test install status logs clean

help:
	@echo "MidiMapper build targets"
	@echo "  make pods     Install locked CocoaPods dependencies"
	@echo "  make build    Build the Release executable through the workspace"
	@echo "  make test     Run the hardware-free regression suite through the workspace"
	@echo "  make install  Build, sign, install, and restart the LaunchAgent"
	@echo "  make status   Show LaunchAgent status"
	@echo "  make logs     Follow the LaunchAgent error log"
	@echo "  make clean    Remove local build output"

pods:
	pod install

build: pods
	xcodebuild \
		-workspace "$(WORKSPACE)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(BUILD_DIR)" \
		build CODE_SIGNING_ALLOWED=NO

test: pods
	xcodebuild \
		-workspace "$(WORKSPACE)" \
		-scheme "MidiMapperTests" \
		-configuration Debug \
		-derivedDataPath "$(BUILD_DIR)" \
		test CODE_SIGNING_ALLOWED=NO

install: build
	@test -x "$(BINARY)"
	/usr/bin/install -d /usr/local/bin "$(HOME)/Library/LaunchAgents"
	/usr/bin/install -m 755 "$(BINARY)" "$(INSTALL_PATH)"
	/usr/bin/codesign --force --sign - "$(INSTALL_PATH)"
	/usr/bin/install -m 644 "$(LAUNCH_AGENT_SOURCE)" "$(LAUNCH_AGENT_DEST)"
	-/bin/launchctl bootout gui/$(USER_ID)/$(LAUNCH_AGENT_LABEL)
	/bin/launchctl bootstrap gui/$(USER_ID) "$(LAUNCH_AGENT_DEST)"
	/bin/launchctl print gui/$(USER_ID)/$(LAUNCH_AGENT_LABEL)

status:
	/bin/launchctl print gui/$(USER_ID)/$(LAUNCH_AGENT_LABEL)

logs:
	tail -f /tmp/MidiMapper.err

clean:
	rm -rf "$(BUILD_ROOT)"
