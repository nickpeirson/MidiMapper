# MidiMapper project guidance

## Repository and layout

- This directory is the Git repository root. Do not run Git commands from its parent directory.
- Application source is in `MidiMapper/`.
- `MidiMapper.xcworkspace` is the canonical Xcode entry point. Open and build the workspace, not `MidiMapper.xcodeproj` directly.

## Dependencies and builds

- CocoaPods owns `Pods/`; change dependencies in `Podfile`, then run `pod install`.
- Keep `Podfile.lock` committed so dependency resolution is reproducible.
- Use `make build` to build the Release app through the workspace.
- Use `make install` to build, sign, install, and restart the LaunchAgent. It changes `/usr/local/bin` and the user's LaunchAgents directory.
- In Codex, CocoaPods/Xcode builds need elevated execution when the restricted sandbox rejects `MidiMapper.xcworkspace` as “not a workspace file”. This is a known false negative caused by Xcode's denied access to macOS services and log locations; it does not mean the workspace is malformed.
- In that case, rerun the same `make` target or `xcodebuild -workspace` command with elevated execution. Do not validate the build or tests through `MidiMapper.xcodeproj`, manually build Pods, or add custom linker paths. If elevated execution is unavailable, report the workspace verification as unperformed rather than using a project-based substitute.

## Generated and local files

- Do not edit `Pods/`, `build/`, or DerivedData directly.
- Do not commit Xcode user data, breakpoints, or `.DS_Store` files.

## GitHub issues

- When asked to create an issue for this project, create it in `nickpeirson/MidiMapper`.
- State the problem, bounded scope, and clear acceptance criteria. Do not create an issue or pull request unless asked.
- When asked to implement an issue, work in a dedicated Git worktree and branch. Do not implement it in the user's active checkout, especially when it has uncommitted changes.
- Keep the worktree limited to the issue's scope. Before committing, review the diff and stage only the files that implement the issue; never include unrelated changes from another checkout.
- Unless the user says otherwise, complete an implemented issue by verifying it, committing the scoped changes, pushing the branch, and closing the GitHub issue with a concise implementation summary and the commit or branch reference.
