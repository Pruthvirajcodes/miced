// ARCHIVED FEATURES — notes only; no code in this file is compiled.
//
// The code itself is not published. A snapshot is kept on the author's Mac on
// the local branch `archive/sidebar-remote-lid` (commit 84de44c). There, a
// file comes back with:
//     git checkout archive/sidebar-remote-lid -- <path>
//
// ── Laptop remote (keyboard and mouse from the Windows laptop) ──────────────
// Files: Sources/ScreenDimmer/RemoteServer.swift, RemoteInput.swift,
//        RemotePage.swift, scripts/verify-remote-input.sh
// - RemoteServer: one-request-per-connection HTTP server on TCP 8787 (Network
//   framework), local addresses only. Re-published the LAN address when the
//   network path changed. Four-digit pairing code stored at
//   ~/Library/Application Support/miced/remote-token (0600). Five wrong codes in
//   a minute blocked every authenticated request for the rest of that minute.
// - RemotePage: the browser page (Chrome/Edge, nothing to install). Pointer
//   lock trackpad, clicks, drag with heartbeat release after 5 s, scroll,
//   keyboard capture, Unicode text, Mac shortcuts; Windows Ctrl -> Command.
//   Mouse moves were coalesced to one in flight; failed requests dropped queued
//   input instead of replaying it late.
// - RemoteInput: posted CGEvents. Needed Privacy & Security > Accessibility for
//   miced; requestAccess() registered the app (switched off) and opened that
//   pane. A person must approve it — never bypass.
// - AppDelegate wiring: `remoteEnabled` pref (screen-dimmer domain), /status and
//   /event routes, a "toggleBreaks" event, and a 2 s timer that refreshed the
//   permission state. Info.plist had NSLocalNetworkUsageDescription. The
//   installer's health check waited for HTTP 200 on 127.0.0.1:8787.
//
// ── Webcam lid detector ─────────────────────────────────────────────────────
// Files: Sources/LidDetection/LidDetector.swift, Sources/WebcamLid/WebcamLid.swift
// (Package.swift targets `LidDetection` and executable `webcam-lid`).
// - Mean image brightness from AVCaptureVideoDataOutput: LID_ON below 12,
//   LID_OFF above 25 (0–255), stable for 0.8 s; UNKNOWN when frames stop, with a
//   watchdog that reopened unplugged or stalled cameras.
// - Prefers the Logitech "Brio 100" (vendor ID 1133). Never uses virtual
//   cameras; the system default is OBS Virtual Camera.
// - Needed Camera permission (NSCameraUsageDescription). The sidebar showed
//   "Lid: ON" red / "Lid: OFF" green with an "Open Camera settings" button.
//
// ── Voice workspace ─────────────────────────────────────────────────────────
// Placeholder only: the sidebar's "VOICE WORKSPACE" heading and a "Voice not
// connected" note. Microphone capture, transcription and Codex were never wired.
//
// ── Right sidebar ───────────────────────────────────────────────────────────
// SidebarController.swift: a 280 pt always-visible NSPanel on the primary
// display hosting all of the above. Breaks used to leave it uncovered. Replaced
// by FocusPanelController, which appears only while the pointer rests there.
