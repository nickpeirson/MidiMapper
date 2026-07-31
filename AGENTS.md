# MidiMapper repository guidance

## Scope and authority

This file is the execution authority for work in this repository. It defines repository operations, implementation constraints, validation, and completion expectations. ChatGPT Project collaboration and hand-off guidance lives in `docs/chatgpt-project-instructions.md`.

## Repository overview

MidiMapper is a macOS Objective-C application that maps a KORG nanoKONTROL2 MIDI controller to Spotify, system-volume, and Philips Hue actions. The app supports macOS 11 or later.

## Repository structure

- `MidiMapper/` contains the application source.
- `MidiMapperTests/` contains the XCTest regression suite; it is designed to run without MIDI hardware or the external applications the mapper controls.
- `MidiMapper.xcworkspace` is the canonical Xcode entry point. Open and build the workspace, not `MidiMapper.xcodeproj` directly.
- `Podfile` declares CocoaPods dependencies; keep the generated `Podfile.lock` committed for reproducible resolution.
- `Makefile` defines the supported build, test, install, and operational targets.
- `com.nickpeirson.MidiMapper.plist` defines the installed LaunchAgent.

## Dependency, generated-file, and installation rules

- CocoaPods owns `Pods/`; change dependencies in `Podfile`, then run `pod install`.
- Do not edit `Pods/`, `build/`, or DerivedData directly.
- Do not commit Xcode user data, breakpoints, or `.DS_Store` files.
- `make install` builds, signs, installs, and restarts the LaunchAgent. It changes `/usr/local/bin` and the user's LaunchAgents directory; use it only when that machine-level change is intended.

## Working-tree and issue workflow

- Run Git commands from this repository root, not its parent directory.
- Preserve pre-existing or unrelated changes. Do not modify, stage, stash, reset, commit, or otherwise disturb them.
- Before modifying files for a GitHub issue, create a dedicated branch and linked Git worktree from the current default branch. Do not implement an issue in the primary checkout or in a worktree containing unrelated changes.
- Before committing, inspect the staged diff and ensure it contains only changes required by the issue.

## Build and test

- Use `make build` to build the Release app through the workspace.
- Use `make test` to run the hardware-free regression suite through the workspace.
- Run the relevant automated coverage for changed behaviour; add or update focused tests where practical.
- In Codex, a restricted-sandbox error that rejects `MidiMapper.xcworkspace` as “not a workspace file” is a known false negative caused by denied access to macOS services and log locations. Rerun the same `make` target or an `xcodebuild -workspace` command with elevated execution. Do not substitute `MidiMapper.xcodeproj`, manually build Pods, or add custom linker paths. If elevated execution is unavailable, report workspace validation as unperformed.

## Documentation changes and GitHub issues

- Update `README.md` when a code change affects supported usage, requirements, installation, or operations.
- When asked to create an issue, create it in `nickpeirson/MidiMapper` and state the problem, bounded scope, and clear acceptance criteria.
- This repository has no established architecture-decision record format or location; do not assume one exists.

## Definition of done for issues

- Treat automated coverage and passing relevant tests as acceptance criteria.
- Unless an issue or repository guidance explicitly requires review without publication, completion includes a focused commit, push, merge into the default branch through the normal repository workflow, and closing the GitHub issue.
- Do not create extra issues or pull requests merely to document completed work.
- Leave the issue open and report the precise blocker only when validation fails, publication is not authorised or possible, the branch cannot be merged safely, or a genuine product or technical decision is required.
