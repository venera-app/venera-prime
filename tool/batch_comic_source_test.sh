#!/usr/bin/env bash
set -u

# Batch smoke checks for configured comic sources and an attached Android device.
# Usage: tool/batch_comic_source_test.sh [source-dir] [apk]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${1:-${VENERA_SOURCE_DIR:-$HOME/.local/share/com.github.wgh136.venera.prime/comic_source}}"
APK="${2:-${VENERA_APK:-$ROOT_DIR/build/app/outputs/flutter-apk/app-debug.apk}}"
ADB="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"
PACKAGE="${PACKAGE:-com.github.wgh136.venera.prime}"
REPORT="${REPORT:-$ROOT_DIR/build/batch-source-report.tsv}"

mkdir -p "$(dirname "$REPORT")"
printf 'source\turls\treachable\tstatus\n' >"$REPORT"
pass=0; fail=0; skipped=0

check_url() {
  local url="$1" code
  code="$(curl -L -k -A 'Venera-source-smoke/1.0' --connect-timeout 8 --max-time 15 -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || printf '000')"
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

printf '%-28s %-6s %-10s %s\n' SOURCE URLS REACHABLE STATUS
for file in "$SOURCE_DIR"/*.js; do
  [[ -f "$file" ]] || continue
  name="$(basename "$file")"
  mapfile -t urls < <(rg -o 'https?://[^"'"'"'` )}]+' "$file" | sed 's/[),;].*$//' | sort -u | head -1)
  if ((${#urls[@]} == 0)); then
    printf '%-28s %-6s %-10s %s\n' "$name" 0 '-' SKIP
    printf '%s\t0\t-\tSKIP\n' "$name" >>"$REPORT"
    ((skipped++))
    continue
  fi
  reachable=0
  for url in "${urls[@]}"; do check_url "$url" && ((reachable++)) || true; done
  status=FAIL
  ((reachable > 0)) && status=PASS && ((pass++)) || ((fail++))
  printf '%-28s %-6s %-10s %s\n' "$name" "${#urls[@]}" "$reachable" "$status"
  printf '%s\t%s\t%s\t%s\n' "$name" "${#urls[@]}" "$reachable" "$status" >>"$REPORT"
done

android_status=SKIP
if [[ "${RUN_ANDROID_SMOKE:-1}" == 1 ]] && [[ -x "$ADB" ]]; then
  device="$($ADB devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [[ -n "$device" ]]; then
    android_status=PASS
    if [[ -f "$APK" ]]; then
      "$ADB" -s "$device" install -r "$APK" >/dev/null || android_status=FAIL
    else
      android_status=FAIL
      echo "APK not found: $APK" >&2
    fi
    if [[ "$android_status" == PASS ]]; then
      "$ADB" -s "$device" shell am force-stop "$PACKAGE"
      "$ADB" -s "$device" shell monkey -p "$PACKAGE" 1 >/dev/null
      sleep "${ANDROID_STARTUP_WAIT:-8}"
      if ! "$ADB" -s "$device" shell pidof "$PACKAGE" >/dev/null; then android_status=FAIL; fi
      if "$ADB" -s "$device" logcat -d -t 500 | rg -q 'FATAL EXCEPTION|AndroidRuntime'; then android_status=FAIL; fi
    fi
  else
    android_status=SKIP
    echo 'No authorized Android device found; set RUN_ANDROID_SMOKE=0 to silence this.' >&2
  fi
fi

printf '\nSource summary: PASS=%d FAIL=%d SKIP=%d\n' "$pass" "$fail" "$skipped"
printf 'Android smoke: %s\nReport: %s\n' "$android_status" "$REPORT"
[[ "$fail" -eq 0 && "$android_status" != FAIL ]]
