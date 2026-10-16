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

## T3 thread status

The top-right corner of the main display shows the T3 Code threads that are
still in motion, one small floating card each, on a faint 20% tint with no blur,
so what is behind them stays visible. The white text has a thin dark outline so
it reads on light and dark content alike. Each card has a status dot on the left
and, on the right, the thread name and a short status line (with how long it has
been working):

- **blue**: working, queued or starting (the dot breathes)
- **gray**: waiting, on a subagent, monitor or background task that will wake
  it, or on you for an approval or an answer (its own or a subagent's); the
  status line says which

Only threads in motion appear, needs-you first, then in the order of T3's
Working section (the last message you sent, newest first). This follows T3's
own rules (`isThreadWorking` and `shellRuntime` in T3's client runtime):
finished, idle, failed, interrupted and cancelled threads are left out even when
pinned, as are threads whose only leftover is a command such as a dev server.
Settled threads stay hidden, and leftover background-task records cannot make
a cancelled or interrupted thread appear to be waiting.
Subagent threads are not listed; a subagent waiting on you marks the thread
above it. Up to 8 cards are shown. When nothing is in motion the corner is
empty.

Hovering a card deepens its tint slightly (to about 28%) and swaps the status
line for the project and what the thread is waiting on. About 3 seconds after
the pointer leaves the corner, the text softens to about half strength and the
tint to about 12%; the dots stay. Moving the pointer back, or a thread changing
state, brings them back. Cards slide in, out and into their new places; with
Reduce Motion on they cross-fade instead and the dot does not breathe. The cards
stay on every Space and over full-screen apps, ignore clicks, never take focus,
and sit under the break overlay.

The status comes live from the T3 Code server on this Mac
(`~/.t3/userdata/server-runtime.json`) through the `orchestration.subscribeShell`
stream, the same one T3's sidebar uses; transcripts are never read. If T3 is not
running or the connection drops, a single **T3 offline** card with a hollow dot
replaces the threads instead of old dots, and the feed reconnects on its own.

On first launch miced asks the T3 CLI for a read-only session
(`t3 auth session issue --scope orchestration:read`, labelled "miced thread
status (read-only)", valid 30 days) and keeps it in the login keychain under
`com.codetorso.miced.t3-thread-status`. It renews it three days before it
expires and revokes the replaced session only after the new one is saved. If
the keychain cannot save a new session, miced revokes that new session, keeps
the old one, and shows the error instead of retrying in a loop.

The session appears in T3 under **Settings → Connections**. If you revoke it
there (or T3 otherwise refuses it before it expires), miced treats that as
final: a **T3 access revoked** card shows, the feed stops, and no new session is
issued, even after miced restarts. The refused session stays in the keychain,
marked as rejected. To turn the panel back on, choose **Re-enable T3 Thread
Status** in the `Dim` menu (it appears only in this state); miced then issues
one new read-only session. A token refused after its expiry date is renewed
automatically.

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
