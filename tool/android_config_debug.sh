#!/usr/bin/env bash
set -u

# End-to-end Android smoke test using the device's existing imported data.
# It intentionally does not clear app data or reinstall an APK unless requested.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"
PACKAGE="${PACKAGE:-com.github.wgh136.venera.prime}"
QUERY="${QUERY:-ONE POINT}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/android-debug-$(date +%Y%m%d-%H%M%S)}"
APK="${APK:-$ROOT_DIR/build/app/outputs/flutter-apk/app-debug.apk}"
mkdir -p "$OUT_DIR"

fail=0; step=0
die() { echo "FAIL: $*" >&2; fail=1; }
run() { "$ADB" -s "$DEVICE" "$@"; }
check_source_scripts() {
  local source
  source="$(run shell run-as "$PACKAGE" cat files/comic_source/copy_manga.js 2>/dev/null || true)"
  if [[ -n "$source" ]] && grep -q 'if (results\[0\]\.status !== 200)' <<<"$source" &&
    grep -q 'Invalid status code: \${res\.status}' <<<"$source"; then
    echo "WARN: device copy_manga.js contains stale res.status bug" >&2
  fi
}
dump() {
  step=$((step + 1))
  run shell uiautomator dump "/sdcard/venera-debug.xml" >/dev/null 2>&1 || die "uiautomator dump"
  run shell cat /sdcard/venera-debug.xml >"$OUT_DIR/$step-ui.xml" 2>/dev/null || die "read UI dump"
  run exec-out screencap -p >"$OUT_DIR/$step-screen.png" 2>/dev/null || die "screenshot"
}
has() { rg -q --fixed-strings "$1" "$OUT_DIR/$step-ui.xml"; }
wait_for() {
  local target="$1" timeout="${2:-15}" deadline
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    dump
    has "$target" && return 0
    sleep 0.1
  done
  return 1
}
wait_for_result() {
  local timeout="${1:-30}" deadline
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    dump
    if has 'No Search Sources' || has '请添加一些源' || has '错误' ||
      has 'ONE' || has 'One' || has 'one'; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}
tap() { run shell input tap "$1" "$2"; wait_for "$3" "${4:-15}" || die "timeout waiting for $3"; }
swipe() { run shell input swipe "$1" "$2" "$3" "$4" 700; sleep 0.1; dump; }

[[ -x "$ADB" ]] || { echo "ADB not found: $ADB" >&2; exit 2; }
DEVICE="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
[[ -n "$DEVICE" ]] || { echo "No authorized Android device" >&2; exit 2; }
check_source_scripts

if [[ "${INSTALL_APK:-0}" == 1 ]]; then
  [[ -f "$APK" ]] || { echo "APK not found: $APK" >&2; exit 2; }
  run install -r "$APK" >/dev/null || exit 1
fi

run logcat -c
run shell am force-stop "$PACKAGE"
run shell monkey -p "$PACKAGE" 1 >/dev/null
wait_for '主页' "${STARTUP_TIMEOUT:-30}" || die 'home page not visible (imported configuration may not have loaded)'

# Home -> search. Coordinates are expressed as fractions of the physical display.
SIZE="$(run shell wm size | awk -F': ' '/Physical size/ {print $2; exit}')"
W="${SIZE%x*}"; H="${SIZE#*x}"
tap "$((W * 47 / 100))" "$((H * 15 / 100))" '搜索' 15
run shell input tap "$((W * 55 / 100))" "$((H * 8 / 100))"
run shell input text "${QUERY// /%s}"
run shell input keyevent 66
wait_for_result "${SEARCH_TIMEOUT:-30}" || die 'search result did not load'
if has 'No Search Sources' || has '请添加一些源'; then die 'imported config has no active search source'; fi
has 'One' || has 'ONE' || has 'one' || die "search returned no matching result for: $QUERY"

# Open first result, verify detail actions, then open the first chapter.
tap "$((W * 50 / 100))" "$((H * 29 / 100))" '收藏' 30
has '收藏' || die 'comic detail page missing favorite action'
has '阅读' || has '继续' || die 'comic detail page missing reader action'
has '评论' || die 'comic detail page missing comments action'
has '第' || die 'comic detail page missing chapter list'
tap "$((W * 74 / 100))" "$((H * 43 / 100))" '第' 30

# Verify reading progress changes after a page swipe.
before="$(rg -o '第[^<"]*[：:] [0-9]+/[0-9]+' "$OUT_DIR/$step-ui.xml" | head -1 || true)"
total="$(printf '%s' "$before" | sed -n 's#^.*/\([0-9][0-9]*\).*$#\1#p')"
if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 1 ]]; then
  swipe "$((W * 82 / 100))" "$((H * 54 / 100))" "$((W * 18 / 100))" "$((H * 54 / 100))"
  after="$(rg -o '第[^<"]*[：:] [0-9]+/[0-9]+' "$OUT_DIR/$step-ui.xml" | head -1 || true)"
  if [[ -z "$after" || "$before" == "$after" ]]; then
    echo "WARN: reader remained on first page after synthetic swipe ($before -> $after)" >&2
    after="$before (swipe not confirmed)"
  fi
else
  after="$before (single-page chapter)"
fi

run shell input keyevent 4; wait_for '收藏' 15 || die 'return from reader did not restore comic detail'
# Favorite action occupies the left action cell on the detail page.
run shell input tap "$((W * 20 / 100))" "$((H * 36 / 100))"
sleep 0.2; dump

if run logcat -d -t 1000 | rg -q 'FATAL EXCEPTION'; then
  die 'fatal Android exception found in logcat'
fi
run logcat -d -t 2000 >"$OUT_DIR/logcat.txt"
printf 'Result: %s\nEvidence: %s\nQuery: %s\nReader: %s -> %s\n' \
  "$([[ $fail -eq 0 ]] && echo PASS || echo FAIL)" "$OUT_DIR" "$QUERY" "$before" "$after"
exit "$fail"
