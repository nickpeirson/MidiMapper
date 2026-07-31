#  MacOS app to control Spotify from a KORG nanoKONTROL2

I got fed up of trying to find volume controls on my screen and wanted some physical buttons and sliders. I bought a second hand KORG nanoKONTROL2 and wrote this application.

It's my first foray into writing code for MacOS, so I suspect there's things that don't follow best practice. It's a personal project not intended for distribution so it's very much written on a "good enough" basis.

## Requirements

- macOS 11 or later
- Xcode command-line tools
- CocoaPods (`pod`)
- A KORG nanoKONTROL2

## Build and install

Run these commands from the repository root:

```sh
make build
make install
```

`make build` installs the locked CocoaPods dependencies and builds the Release executable. `make install` also signs the executable, installs it at `/usr/local/bin/MidiMapper`, and restarts the `com.nickpeirson.MidiMapper` LaunchAgent.

The install target changes the local machine and may require permission to write to `/usr/local/bin` and the user's `~/Library/LaunchAgents` directory.

## Operations

```sh
make status  # Show the LaunchAgent state
make logs    # Follow the service log
```

The service log is written to `/tmp/MidiMapper.err`.
