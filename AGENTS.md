# MidiMapper repository guidance

## Scope and authority

This file is the authoritative repository guidance for engineering work. Follow the current user instruction and agreed task scope, then this guidance. Verify the current repository, installed service, and GitHub state directly; previous chats provide context rather than evidence. Record durable conclusions in the README, code, or relevant issue.

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
- Share build schemes under `xcshareddata/xcschemes/`. Do not commit Xcode user data, breakpoints, or `.DS_Store` files.
- Keep generated builds, diagnostic captures, machine-specific data, and captured executables out of Git.
- `make install` builds, signs, installs, and restarts the LaunchAgent. It changes `/usr/local/bin` and the user's LaunchAgents directory; use it only when that machine-level change is intended.

## Working-tree and issue workflow

- Run Git commands from this repository root, not its parent directory.
- Preserve pre-existing or unrelated changes. Unless the user explicitly requests reconciliation, do not modify, stage, stash, reset, commit, or otherwise disturb them.
- For reconciliation, compare staged contents and histories first. Archive unique work and evidence outside disposable checkouts before removing workspaces or intermediate patches; never force-push shared history.
- Before modifying files for a GitHub issue, create a dedicated branch and linked Git worktree from the current default branch. Do not implement an issue in the primary checkout or in a worktree containing unrelated changes.
- Before committing, inspect the staged diff and ensure it contains only changes required by the issue.

## Build and test

- Use `make build` to build the Release app through the workspace.
- Use `make test` to run the hardware-free regression suite through the workspace.
- If a newer SDK rejects macOS 11, pass `XCODEBUILD_ARGS=MACOSX_DEPLOYMENT_TARGET=12.0` consistently to build, test, and install, as documented in the README.
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

## Incident investigations

- Preserve live process state, logs, and existing reports before recovery or restart. Review existing diagnostics first.
- Treat restart as a workaround; trace the cause and continue through a focused fix, tests, Release build, and installation when feasible.
- Before deleting investigation workspaces, archive significant reports, relevant logs, source/staged patches, and conclusions in a documented local diagnostics directory outside the checkout. Include source revisions and checksums; leave live diagnostic reports intact.
- After an intended installation, verify the executable and signature, the LaunchAgent plist and label, and the running job. Avoid restarting an already verified service solely for repository housekeeping.
