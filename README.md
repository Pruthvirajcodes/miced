<img src="assets/icon.svg" width="64" height="64" alt="">

# miced

Native macOS screen-break app, based on the Screen Dimmer app copied from
`/Users/codetorso/Desktop/hello-world`.

Every 20 minutes the screen goes black on every display for 50 seconds.

## Focus pill

A small pill in the bottom-right corner of the main display shows the time to
the next break, with a cat. Hover it and it grows into a card with:

- **Focus | Break** to start a break now or end one early
- **Pause / Resume**: resuming continues the countdown where it stopped
- the countdown, with the cat walking toward the break (or napping during one)

The same actions are in the `Dim` menu-bar item. The state survives restarts:
a paused timer stays paused with its time left, and a running countdown keeps
going after a relaunch or reinstall. Time with the Mac asleep or the displays
off counts as a break, so waking the Mac never starts with a black screen.
Pausing during a break ends the break. No macOS privacy permissions are needed.

## Build and run

```sh
swift build -c release
.build/release/screen-dimmer
```

Stop the installed login item before running a second copy.

## Install

```sh
./scripts/install-login-item.sh
```

This builds and signs the app in a temporary folder and verifies the signature
before it stops the running copy. It then installs
`~/Library/Application Support/screen-dimmer/miced.app/`, replaces the
`com.codetorso.screen-dimmer` login item, and checks that the new app starts.
If the new app does not start, the installer restores the previous one. Each
install keeps the previous app as a ZIP in `backups/`.

`scripts/setup-signing.sh` (run by the installer) creates a local self-signed
code-signing certificate once, in its own keychain at
`~/Library/Application Support/miced/signing/`, so the app keeps a stable
identity across rebuilds. `MICED_SIGNING_IDENTITY` (plus `MICED_KEYCHAIN`) can
name a different identity, and `-` forces ad-hoc signing.

`./scripts/uninstall-login-item.sh` removes the login item. Add `--remove-app` to
delete the installed bundle as well; ZIP backups are kept.

## Archived features

The always-visible right sidebar, the laptop keyboard/mouse remote (port 8787),
the webcam lid detector, and the voice placeholder were removed. Notes on how
they worked are in `Sources/ScreenDimmer/Archive.swift`; their code is not
published.
