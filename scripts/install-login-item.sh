#!/bin/zsh
# Builds, signs, verifies and installs miced as a login item.
#
# Order matters: the new bundle is built, signed and verified in a staging
# folder before the running app is stopped, and the previous bundle is put
# back if the new one does not come up.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.codetorso.screen-dimmer"
OLD_LABEL="com.codetorso.hello-world-overlay"
BUNDLE_ID="com.codetorso.miced"
DOMAIN="gui/$(id -u)"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
LOG_DIR="$HOME/Library/Logs/screen-dimmer"
INSTALL_DIR="$HOME/Library/Application Support/screen-dimmer"
BACKUP_DIR="$INSTALL_DIR/backups"
APP_PATH="$INSTALL_DIR/miced.app"
BIN_PATH="$APP_PATH/Contents/MacOS/screen-dimmer"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_DIR" "$INSTALL_DIR" "$BACKUP_DIR"

if [[ ! -w "$(dirname "$PLIST_PATH")" ]]; then
    echo "Cannot write to $(dirname "$PLIST_PATH")."
    ls -ld "$(dirname "$PLIST_PATH")"
    echo "Fix it once with: sudo chown \"$USER\":staff \"$HOME/Library/LaunchAgents\""
    exit 1
fi

STAGE="$(mktemp -d)"
ORIGINAL_KEYCHAINS=("${(@f)$(/usr/bin/security list-keychains -d user | sed 's/^ *"//;s/"$//')}")
KEYCHAIN_ADDED=0
cleanup() {
    if (( KEYCHAIN_ADDED )); then
        /usr/bin/security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT

designated_requirement() {
    /usr/bin/codesign -d -r- "$1" 2>/dev/null | sed -n 's/^\(# \)\{0,1\}designated => //p'
}

# 1. Build and sign in staging. Nothing running is touched yet.
cd "$ROOT_DIR"
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
STAGED_APP="$STAGE/miced.app"
mkdir -p "$STAGED_APP/Contents/MacOS"
/usr/bin/ditto "$BUILD_DIR/screen-dimmer" "$STAGED_APP/Contents/MacOS/screen-dimmer"
/usr/bin/ditto "$ROOT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
chmod 755 "$STAGED_APP/Contents/MacOS/screen-dimmer"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null

if [[ -n "${MICED_SIGNING_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="$MICED_SIGNING_IDENTITY"
    MICED_KEYCHAIN="${MICED_KEYCHAIN:-}"
else
    # A persistent local certificate keeps macOS permissions across updates.
    eval "$("$ROOT_DIR/scripts/setup-signing.sh")"
    SIGNING_IDENTITY="$MICED_SIGNING_IDENTITY"
fi
if [[ "$SIGNING_IDENTITY" != "-" && -n "${MICED_KEYCHAIN:-}" ]]; then
    /usr/bin/security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$MICED_KEYCHAIN"
    KEYCHAIN_ADDED=1
fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$STAGED_APP"
/usr/bin/codesign --verify --strict --verbose=1 "$STAGED_APP"
NEW_DR="$(designated_requirement "$STAGED_APP")"
echo "Designated requirement: $NEW_DR"
if [[ "$NEW_DR" == cdhash* ]]; then
    echo "Warning: ad-hoc signature. macOS permissions will need approval again after every update."
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")" != "$BUNDLE_ID" ]]; then
    echo "Staged bundle has the wrong identifier." >&2
    exit 1
fi

# 2. Old .app backups share the bundle ID, so System Settings may show a
#    backup's name instead of miced. Keep them as zip archives only.
setopt local_options null_glob
for old in "$BACKUP_DIR"/miced-*.app; do
    archive="${old%.app}.zip"
    /usr/bin/ditto -c -k --keepParent "$old" "$archive"
    /usr/bin/unzip -tq "$archive" >/dev/null
    "$LSREGISTER" -u "$old" >/dev/null 2>&1 || true
    rm -rf "$old"
    echo "Archived $(basename "$old") to $(basename "$archive")"
done

# 3. Swap bundles. Keep the previous one for rollback and as a zip backup.
PREVIOUS="$STAGE/previous.app"
if [[ -d "$APP_PATH" ]]; then
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$BACKUP_DIR/miced-$(date +%Y%m%d-%H%M%S).zip"
fi
launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "$DOMAIN" "$OLD_PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$OLD_PLIST_PATH"
[[ -d "$APP_PATH" ]] && mv "$APP_PATH" "$PREVIOUS"
mv "$STAGED_APP" "$APP_PATH"
"$LSREGISTER" -f "$APP_PATH"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>WorkingDirectory</key>
    <string>$INSTALL_DIR</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/stderr.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF
/usr/bin/plutil -lint "$PLIST_PATH" >/dev/null

start_agent() {
    launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
    launchctl enable "$DOMAIN/$LABEL"
    launchctl kickstart -k "$DOMAIN/$LABEL"
}

healthy() {
    local pid
    for _ in {1..20}; do
        sleep 0.5
        pid="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^\tpid = / { print $3 }')"
        [[ -n "$pid" ]] || continue
        sleep 2
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

start_agent
if ! healthy; then
    echo "New build did not start correctly." >&2
    if [[ -d "$PREVIOUS" ]]; then
        echo "Restoring the previous app." >&2
        launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
        rm -rf "$APP_PATH"
        mv "$PREVIOUS" "$APP_PATH"
        "$LSREGISTER" -f "$APP_PATH"
        start_agent
    fi
    exit 1
fi

echo "Installed $APP_PATH and login item $LABEL."
