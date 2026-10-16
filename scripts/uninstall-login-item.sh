#!/bin/zsh

set -euo pipefail

LABEL="com.codetorso.screen-dimmer"
OLD_LABEL="com.codetorso.hello-world-overlay"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"

if [[ ! -w "$(dirname "$PLIST_PATH")" ]]; then
    echo "Cannot modify $(dirname "$PLIST_PATH")."
    echo "Current ownership:"
    ls -ld "$(dirname "$PLIST_PATH")"
    echo
    echo "Fix it once with:"
    echo "sudo chown \"$USER\":staff \"$HOME/Library/LaunchAgents\""
    exit 1
fi

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$OLD_PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -f "$OLD_PLIST_PATH"

if [[ "${1:-}" == "--remove-app" ]]; then
    APP_PATH="$HOME/Library/Application Support/screen-dimmer/miced.app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP_PATH" >/dev/null 2>&1 || true
    rm -rf "$APP_PATH"
    echo "Removed $APP_PATH (zip backups are kept)."
fi

echo "Removed login item: $LABEL"
