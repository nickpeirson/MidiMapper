# MidiMapper project guidance

## Repository and layout

- This directory is the Git repository root. Do not run Git commands from its parent directory.
- Application source is in `MidiMapper/`.
- `MidiMapper.xcworkspace` is the canonical Xcode entry point. Open and build the workspace, not `MidiMapper.xcodeproj` directly.

## Dependencies and builds

- CocoaPods owns `Pods/`; change dependencies in `Podfile`, then run `pod install`.
- Keep `Podfile.lock` committed so dependency resolution is reproducible.
- Build the Release app through the workspace with the `MidiMapper (Release)` scheme.
- In Codex, CocoaPods/Xcode builds may need elevated execution: Xcode runs nested sandboxed script phases and writes to DerivedData. Do not work around this by manually building Pods or adding custom linker paths.

## Generated and local files

- Do not edit `Pods/`, `build/`, or DerivedData directly.
- Do not commit Xcode user data, breakpoints, or `.DS_Store` files.
