#!/usr/bin/env bash
set -Eeuo pipefail

# Deterministic Android smoke runner. It does not depend on translated UI
# labels or coordinate taps; artifacts are always written to OUT_DIR.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ADB:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}/platform-tools/adb}"
PACKAGE="${PACKAGE:-com.github.wgh136.venera.prime}"
APK="${APK:-$ROOT_DIR/build/app/outputs/flutter-apk/app-debug.apk}"
SOURCE="${SOURCE:-$ROOT_DIR/tool/comic_sources/manga_dex.js}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/android-debug-$(date +%Y%m%d-%H%M%S)}"
DEVICE="${DEVICE:-}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-30}"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -x "$ADB" ]] || die "adb not found: $ADB"
mkdir -p "$OUT_DIR"

if [[ -z "$DEVICE" ]]; then
  DEVICE="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi
[[ -n "$DEVICE" ]] || die "no authorized Android device"
adb() { "$ADB" -s "$DEVICE" "$@"; }

printf 'Device: %s\nPackage: %s\n' "$DEVICE" "$PACKAGE"

if [[ "${INSTALL_APK:-1}" == 1 ]]; then
  [[ -f "$APK" ]] || die "APK not found: $APK"
  adb install -r "$APK" >"$OUT_DIR/install.txt" || die "APK installation failed"
fi

if [[ "${INSTALL_MANGADEX_SOURCE:-1}" == 1 ]]; then
  [[ -f "$SOURCE" ]] || die "MangaDex source not found: $SOURCE"
  tmp="/data/local/tmp/venera-manga-dex.js"
  adb push "$SOURCE" "$tmp" >"$OUT_DIR/source-push.txt"
  adb shell run-as "$PACKAGE" mkdir -p files/comic_source
  adb shell run-as "$PACKAGE" cp "$tmp" files/comic_source/manga_dex.js
  adb shell rm -f "$tmp"
  adb shell run-as "$PACKAGE" sha256sum files/comic_source/manga_dex.js \
    >"$OUT_DIR/source-device-sha256.txt"
fi

adb logcat -c
adb shell am force-stop "$PACKAGE"
adb shell monkey -p "$PACKAGE" 1 >"$OUT_DIR/launch.txt"

deadline=$((SECONDS + STARTUP_TIMEOUT))
started=0
while (( SECONDS < deadline )); do
  if adb shell dumpsys activity activities 2>/dev/null | rg -q "$PACKAGE"; then
    started=1
    break
  fi
  sleep 1
done
(( started == 1 )) || die "application did not start within ${STARTUP_TIMEOUT}s"

adb shell uiautomator dump /sdcard/venera-debug.xml >/dev/null
adb pull /sdcard/venera-debug.xml "$OUT_DIR/ui.xml" >/dev/null
adb exec-out screencap -p >"$OUT_DIR/screen.png"
adb shell dumpsys meminfo "$PACKAGE" >"$OUT_DIR/meminfo.txt" || true
adb logcat -d -t 3000 >"$OUT_DIR/logcat.txt"

if rg -q 'FATAL EXCEPTION|AndroidRuntime.*FATAL' "$OUT_DIR/logcat.txt"; then
  printf 'WARN: fatal exception marker found in logcat\n' >&2
  exit 2
fi
printf 'PASS: app started and diagnostics captured in %s\n' "$OUT_DIR"
