#!/bin/sh
# Lighthouse 2 installer for macOS on Apple silicon.
#
#   curl -fsSL https://raw.githubusercontent.com/dpreil-ydlp/lighthouse-2/main/install.sh | sh
#
# Downloads the release zip from GitHub over HTTPS, checks its SHA-256 against the .sha256 file
# published next to it, installs "/Applications/Lighthouse 2.app" and opens it.
#
#   sh install.sh --uninstall    quits Lighthouse 2 and moves "/Applications/Lighthouse 2.app" to the Trash
#   sh install.sh --help
set -eu

VERSION="${LIGHTHOUSE_VERSION:-0.0.11}"
BUNDLE_ID="com.lighthouse.v2"
APP_NAME="Lighthouse 2.app"
OLD_APP_NAME="Lighthouse.app"
RELEASE_URL="https://github.com/dpreil-ydlp/lighthouse-2/releases/download/v$VERSION/Lighthouse-2-$VERSION.zip"
# Test hooks: LIGHTHOUSE_ZIP_URL may point at a local file:// copy of the zip; LIGHTHOUSE_APPS_DIR
# installs somewhere other than /Applications; LIGHTHOUSE_TRASH_DIR replaces ~/.Trash;
# LIGHTHOUSE_NO_OPEN=1 skips opening the app; LIGHTHOUSE_QUIT_WAIT sets the seconds before SIGKILL.
ZIP_URL="${LIGHTHOUSE_ZIP_URL:-$RELEASE_URL}"
SHA_URL="${LIGHTHOUSE_SHA_URL:-$ZIP_URL.sha256}"
APPS_DIR="${LIGHTHOUSE_APPS_DIR:-/Applications}"
TARGET="$APPS_DIR/$APP_NAME"
OLD_TARGET="$APPS_DIR/$OLD_APP_NAME"
TRASH="${LIGHTHOUSE_TRASH_DIR:-$HOME/.Trash}"
WORK=""

say() { printf '%s\n' "$*"; }
fail() { printf 'Lighthouse 2 install stopped: %s\n' "$*" >&2; exit 1; }
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; }

usage() {
    cat <<'USAGE'
Lighthouse 2 installer

  curl -fsSL https://raw.githubusercontent.com/dpreil-ydlp/lighthouse-2/main/install.sh | sh
  curl -fsSL https://raw.githubusercontent.com/dpreil-ydlp/lighthouse-2/main/install.sh | sh -s -- --uninstall

  (no option)   install or update "/Applications/Lighthouse 2.app" and open it
  --uninstall   quit Lighthouse 2 and move "/Applications/Lighthouse 2.app" to the Trash;
                your settings and its store stay (the README lists them)
  --help        show this text
USAGE
}

# Bundle id of an app folder, or nothing if it has none.
bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# The executable a process runs, from its first `txt` descriptor (lsof). Unlike `ps -o comm`,
# which shows argv[0], this cannot be renamed by the process.
exe_of() {
    /usr/sbin/lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | sed -n 1p
}

# PIDs whose executable is exactly $1 or $2 (literal string comparison, never a pattern):
# `ps` lists candidates by argv[0], then lsof confirms the real executable is $2.
exact_pids() {
    ps -axww -o pid= -o comm= 2>/dev/null | while read -r pid cmd; do
        if [ "$cmd" = "$1" ] || [ "$cmd" = "$2" ]; then
            if [ "$(exe_of "$pid")" = "$2" ]; then printf '%s\n' "$pid"; fi
        fi
    done
}

# Sends signal $2 to PID $1 only if that PID still runs exactly the executable $3.
signal_exact() {
    if [ "$(exe_of "$1")" = "$3" ]; then kill "-$2" "$1" 2>/dev/null || true; fi
}

# Quits the copy of Lighthouse running from the app folder $1, if any: SIGTERM to the processes
# whose executable is exactly "$1/Contents/MacOS/Lighthouse", then SIGKILL to any still running it
# after 10 seconds. No AppleScript, so macOS shows no Automation prompt. Data Lighthouse has
# already committed to its SQLite store survives; work in flight is read again from its checkpoints.
quit_app() {
    exe="$1/Contents/MacOS/Lighthouse"
    real="$(cd "$1/Contents/MacOS" 2>/dev/null && pwd -P)/Lighthouse"
    pids="$(exact_pids "$exe" "$real")"
    if [ -z "$pids" ]; then
        return 0
    fi
    say "Quitting the running copy of \"$1\""
    for pid in $pids; do signal_exact "$pid" TERM "$real"; done
    tries=0
    while :; do
        left=""
        for pid in $pids; do
            if [ "$(exe_of "$pid")" = "$real" ]; then left="$left $pid"; fi
        done
        if [ -z "$left" ]; then
            return 0
        fi
        tries=$((tries + 1))
        if [ "$tries" -gt "${LIGHTHOUSE_QUIT_WAIT:-10}" ]; then
            for pid in $left; do signal_exact "$pid" KILL "$real"; done
            sleep 1
            return 0
        fi
        sleep 1
    done
}

# Moves an app folder to the user's Trash under a name that does not collide.
trash_app() {
    name="$(basename "$1" .app)"
    dest="$TRASH/$name.app"
    if [ -e "$dest" ]; then
        dest="$TRASH/$name $(date +%Y-%m-%d-%H%M%S).app"
    fi
    if ! mv "$1" "$dest"; then
        rm -rf "$TARGET.installing"
        fail "could not move \"$1\" to the Trash. Move it there yourself and run this again."
    fi
    say "Moved \"$1\" to the Trash."
}

check_mac() {
    [ "$(uname -s)" = "Darwin" ] || fail "Lighthouse 2 runs on macOS only."
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
        fail "Lighthouse 2 needs a Mac with Apple silicon (M1 or later)."
    fi
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -ge 14 ] || fail "Lighthouse 2 needs macOS 14 or later. This Mac runs $(sw_vers -productVersion)."
}

download() {
    case "$1" in
        https://*) curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$2" ;;
        file://*)
            [ -n "${LIGHTHOUSE_ZIP_URL:-}" ] || fail "file:// URLs are for local tests only."
            curl --proto '=file' -fsSL "$1" -o "$2"
            ;;
        *) fail "refusing to download from $1 (only https:// is allowed)." ;;
    esac
}

install_app() {
    check_mac
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/lighthouse-2-install.XXXXXX")"
    trap cleanup EXIT INT TERM

    zip="$WORK/Lighthouse-2-$VERSION.zip"
    say "Downloading Lighthouse 2 $VERSION"
    say "  from $ZIP_URL"
    download "$ZIP_URL" "$zip" || fail "download failed: $ZIP_URL"
    download "$SHA_URL" "$WORK/zip.sha256" || fail "download failed: $SHA_URL"

    expected="$(awk 'NR == 1 { print $1 }' "$WORK/zip.sha256")"
    actual="$(shasum -a 256 "$zip" | awk '{ print $1 }')"
    case "$expected" in
        *[!0-9a-f]* | "") fail "the checksum file does not hold a SHA-256 hash." ;;
    esac
    [ "${#expected}" -eq 64 ] || fail "the checksum file does not hold a SHA-256 hash."
    [ "$expected" = "$actual" ] || fail "SHA-256 mismatch. Expected $expected, got $actual. Nothing was installed."
    say "SHA-256 matches: $actual"

    ditto -x -k "$zip" "$WORK/unzipped" || fail "could not unzip the download."
    new="$WORK/unzipped/$APP_NAME"
    [ -d "$new" ] || fail "the zip does not contain \"$APP_NAME\"."
    [ "$(bundle_id "$new")" = "$BUNDLE_ID" ] || fail "the downloaded app is not Lighthouse 2 (unexpected bundle id)."

    if [ -e "$TARGET" ]; then
        found="$(bundle_id "$TARGET")"
        [ "$found" = "$BUNDLE_ID" ] || fail "\"$TARGET\" exists and is not Lighthouse 2 (bundle id: ${found:-none}). Nothing was changed."
        say "Updating the copy at \"$TARGET\""
        quit_app "$TARGET"
    fi

    # Stage the new copy next to the target first, so a failed copy changes nothing else.
    mkdir -p "$APPS_DIR"
    rm -rf "$TARGET.installing"
    if ! ditto "$new" "$TARGET.installing"; then
        rm -rf "$TARGET.installing"
        fail "could not copy the app to \"$APPS_DIR\". No installed app was moved or replaced."
    fi

    # Builds before 0.0.2 were named Lighthouse.app. Keep only one copy.
    if [ -e "$OLD_TARGET" ] && [ "$(bundle_id "$OLD_TARGET")" = "$BUNDLE_ID" ]; then
        say "Found an older build at \"$OLD_TARGET\". Lighthouse 2 replaces it."
        quit_app "$OLD_TARGET"
        trash_app "$OLD_TARGET"
    fi

    rm -rf "$TARGET"
    mv "$TARGET.installing" "$TARGET"
    say "Installed \"$TARGET\"."

    if [ "${LIGHTHOUSE_NO_OPEN:-0}" = "1" ]; then
        say "Not opening it (LIGHTHOUSE_NO_OPEN=1)."
    else
        open "$TARGET"
        say "Lighthouse 2 is running. Look for the lighthouse in the menu bar, or press Control-Option-Space."
    fi
}

uninstall_app() {
    if [ ! -e "$TARGET" ]; then
        say "\"$TARGET\" is not installed. Nothing to do."
        return 0
    fi
    found="$(bundle_id "$TARGET")"
    [ "$found" = "$BUNDLE_ID" ] || fail "\"$TARGET\" is not Lighthouse 2 (bundle id: ${found:-none}). Nothing was changed."
    quit_app "$TARGET"
    trash_app "$TARGET"
    say "Your settings and store are still in ~/Library/Application Support/Lighthouse."
    say "To delete them too: rm -r ~/Library/Application\\ Support/Lighthouse ~/Library/Caches/com.lighthouse.v2 && defaults delete com.lighthouse.v2"
}

main() {
    case "${1:-}" in
        "") install_app ;;
        --uninstall) uninstall_app ;;
        -h | --help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
