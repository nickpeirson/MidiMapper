#  MacOS app to control Spotify from a KORG nanoKONTROL2

I got fed up of trying to find volume controls on my screen and wanted some physical buttons and sliders. I bought a second hand KORG nanoKONTROL2 and wrote this application.

It's my first foray into writing code for MacOS, so I suspect there's things that don't follow best practice. It's a personal project not intended for distribution so it's very much written on a "good enough" basis.

## Requirements

- macOS 11 or later
- Xcode (including the macOS SDK) and its command-line tools
- CocoaPods (`pod`)
- A KORG nanoKONTROL2

## Build and install

Run these commands from the repository root:

```sh
make test
make build
make install
```

`make build` installs CocoaPods dependencies in deployment mode using `Podfile.lock` and builds the shared Release scheme. `make install` also signs the executable, installs it at `/usr/local/bin/MidiMapper`, and restarts the `com.nickpeirson.MidiMapper` LaunchAgent. `install.sh` delegates to this same target.

The installed plist is `~/Library/LaunchAgents/com.nickpeirson.midimapper.plist`; its service label remains `com.nickpeirson.MidiMapper`. The tracked source plist uses `MidiMapper` capitalisation. `toggle-midimapper.sh` loads or unloads that same installed job.

The install target changes the local machine and may require permission to write to `/usr/local/bin` and the user's `~/Library/LaunchAgents` directory.

## Operations

```sh
make status  # Show the LaunchAgent state
make logs    # Follow Unified Log output (including debug messages)
```

Operational logs are written to macOS Unified Logging with subsystem
`com.nickpeirson.MidiMapper`. Use `make logs` to follow them, or filter in
Console by subsystem and category (MIDI, Action, Spotify, Hue, or CoreAudio).

## Spotify failure diagnostics

Spotify commands retain their existing `kAENoReply` send mode and execution
queues. Diagnostics do not query playback, retry commands, recreate connections,
or restart either application. `CALL_RETURNED` means the call returned; it does
not confirm playback. Errors include the event ID, Apple-event error details,
command duration, and calling thread. A return at or beyond the five-second
deadline is classified as `deadline-exceeded`, even if the existing timeout
callback runs late. The circuit breaker's existing behaviour is unchanged.

An independent watchdog notices Spotify calls still running after two seconds
and runs `/usr/bin/sample <pid> 1 1 -file <path>` to capture one second of stacks.
Reports are saved under `~/Library/Logs/MidiMapper/Diagnostics/`. Override this
directory with `MIDIMAPPER_DIAGNOSTICS_DIR` for a temporary smoke-test launch.
Each incident directory contains:

- `stacks.txt`: the stack sample, if macOS permits sampling.
- `context.json`: the triggering call and its final outcome, the last 20 completed
  Spotify calls, process elapsed time, calling thread, and the last 20 lifecycle
  events (including sleep and wake observed since launch).
- `sampler.log`: output and errors from the sampling utility.

Sampling occurs once per incident; a command returning within two seconds
without an error starts a new incident. Sampling is capped at 10 attempts per
process lifetime. Existing reports are retained. A slow command need not be a
failure: correlate its final outcome and error with the sample. Sampling failure
is logged and does not change Spotify execution. The sampler is given a separate
10-second termination watchdog.

On recurrence, retain the report directory and Unified Log entries for the
matching event ID before restarting anything. Archive significant evidence and
a short conclusion outside disposable checkouts (for example in a sibling
`diagnostics/` directory); keep logs, captured executables, and local paths out
of Git. If the failure persists, manually sample MidiMapper in Activity Monitor as well. The instrumented build adds no
automatic recovery.

## Running a build temporarily

To smoke test without installation, build with `make build`, sign the resulting
`build/DerivedData/Build/Products/Release/MidiMapper`, and load a temporary
LaunchAgent plist with the same label as the installed job but with
`ProgramArguments` pointing at that build. Boot out the existing job first to
avoid having two MIDI listeners. Leave `/usr/local/bin/MidiMapper` and the saved
LaunchAgent plist untouched. Restore the installed job by booting out the
temporary job and bootstrapping the saved plist. A logout/login loads the saved
installed job again. A build at a new path may need its own macOS Automation
permission; success in Script Editor does not establish that permission.

If the active Xcode SDK rejects the saved macOS 11 deployment target, build and
test locally with `make build XCODEBUILD_ARGS=MACOSX_DEPLOYMENT_TARGET=12.0` and
`make test XCODEBUILD_ARGS=MACOSX_DEPLOYMENT_TARGET=12.0`; use the same override
with `make install`. This override applies to the local artifacts and does not
change the project's deployment settings.
