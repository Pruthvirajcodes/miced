<img src="assets/icon.svg" width="64" height="64" alt="">

# miced

Native macOS screen-break app, based on the Screen Dimmer app copied from
`/Users/codetorso/Desktop/hello-world`.

Every 20 minutes the screen goes black on every display for 50 seconds. Pause or
resume breaks from the `Dim` menu-bar item or from the focus card.

## Focus card

Rest the pointer in the right edge of the main display (the right 280 points,
below the menu bar) and a small card appears in the top-right corner after a
short delay. It shows the focus countdown to the next break, the time left
during a break, or that breaks are paused, plus a Pause/Resume button. It hides
again when the pointer leaves that area. The card follows the system light or
dark appearance and needs no macOS privacy permissions.

## Build and run

```sh
swift build -c release
.build/release/screen-dimmer
```

Use `--preview-break` to show a five-second break immediately, and
`--preview-panel` to keep the focus card open without hovering. Stop the
installed login item before running a second copy.

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
