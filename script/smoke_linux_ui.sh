#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo "python3 is required for the ClipVault Linux UI smoke test." >&2; exit 1; }
SMOKE_IMAGE_COPY_Y="${SMOKE_IMAGE_COPY_Y:-373}"
if [[ ! "$SMOKE_IMAGE_COPY_Y" =~ ^[0-9]+$ ]]; then
  echo "SMOKE_IMAGE_COPY_Y must be a non-negative integer." >&2
  exit 1
fi
export DISPLAY=:99
export GSK_RENDERER=cairo
export GTK_A11Y=none
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=GNOME

wait_for_window_focus() {
  local expected_window_id="$1"
  local focused_window_id
  for attempt in $(seq 1 20); do
    focused_window_id="$(xdotool getwindowfocus 2>/dev/null || true)"
    if [[ "$focused_window_id" == "$expected_window_id" ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "FAIL: window $expected_window_id did not receive focus (focused: ${focused_window_id:-none})." >&2
  return 1
}

accept_visible_dialog_if_open() {
  local title_regex="$1"
  local dialog_id geometry dialog_width dialog_height
  dialog_id="$(xdotool search --onlyvisible --name "$title_regex" 2>/dev/null | head -1 || true)"
  [[ -n "$dialog_id" ]] || return 0
  wait_for_window_focus "$dialog_id"
  geometry="$(xdotool getwindowgeometry --shell "$dialog_id")"
  dialog_width="$(printf '%s\n' "$geometry" | sed -n 's/^WIDTH=//p')"
  dialog_height="$(printf '%s\n' "$geometry" | sed -n 's/^HEIGHT=//p')"
  if [[ ! "$dialog_width" =~ ^[0-9]+$ || ! "$dialog_height" =~ ^[0-9]+$ ]]; then
    echo "FAIL: could not read geometry for dialog $dialog_id." >&2
    return 1
  fi
  xdotool mousemove --window "$dialog_id" "$((dialog_width-62))" "$((dialog_height-29))" click 1
}

SMOKE_ROOT="$(mktemp -d /tmp/clipvault-ui-smoke.XXXXXX)"
SMOKE_SAVE_PATH="$PWD/.clipvault-save-smoke-$$.txt"
export XDG_DATA_HOME="$SMOKE_ROOT/data"
export XDG_CONFIG_HOME="$SMOKE_ROOT/config"
export XDG_RUNTIME_DIR="$SMOKE_ROOT/runtime"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
Xvfb "$DISPLAY" -screen 0 1100x800x24 >/tmp/xvfb.log 2>&1 &
for attempt in $(seq 1 20); do
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then break; fi
  sleep 1
done
dbus-update-activation-environment DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_HOME
printf '%s' 'isolated-ui-keyring-password' | gnome-keyring-daemon --unlock --components=secrets >/tmp/keyring.log 2>&1
"${CLIPVAULT_LINUX_BINARY:-/build/debug/clipvault-linux}" >/tmp/clipvault-ui.log 2>&1 &
app_pid=$!
trap 'kill "$app_pid" >/dev/null 2>&1 || true; rm -rf "$SMOKE_ROOT"; rm -f "$SMOKE_SAVE_PATH"' EXIT
for attempt in $(seq 1 30); do
  if xdotool search --name '^ClipVault$' >/tmp/clipvault-window; then break; fi
  sleep 1
done
window_id="$(head -1 /tmp/clipvault-window)"
test -n "$window_id"
sleep 3
# Opening the application again must present its existing window and worker.
"${CLIPVAULT_LINUX_BINARY:-/build/debug/clipvault-linux}" >/tmp/clipvault-reactivate.log 2>&1 &
reactivate_pid=$!
wait "$reactivate_pid"
sleep 1
window_count="$(xdotool search --name '^ClipVault$' | wc -l)"
if [[ "$window_count" -ne 1 ]]; then
  echo "FAIL: repeated activation created $window_count ClipVault windows; expected one." >&2
  exit 1
fi
xdotool mousemove --window "$window_id" 730 78 click 1
sleep 2
printf %s 'ClipVault Linux UI capture receipt' | xclip -selection clipboard
sleep 3
import -window root /evidence/linux-history.png
# An ordinary session-bus caller must not be accepted as the GNOME adapter.
bridge_reply="$(dbus-send --session --print-reply --dest=com.rsitech.ClipVault.Capture /com/rsitech/ClipVault/Capture com.rsitech.ClipVault.Capture.Heartbeat)"
[[ "$bridge_reply" == *'string ""'* ]]
files_reply="$(dbus-send --session --print-reply --dest=com.rsitech.ClipVault.Capture /com/rsitech/ClipVault/Capture com.rsitech.ClipVault.Capture.CaptureFiles string:1 string:'file:///tmp/untrusted.txt')"
[[ "$files_reply" == *'boolean false'* ]]
oversized_uri_list="$(python3 -c 'print("x" * (64 * 1024 + 1), end="")')"
oversized_files_reply="$(dbus-send --session --print-reply --dest=com.rsitech.ClipVault.Capture /com/rsitech/ClipVault/Capture com.rsitech.ClipVault.Capture.CaptureFiles string:1 "string:$oversized_uri_list")"
[[ "$oversized_files_reply" == *'boolean false'* ]]
# Replace the clipboard while capture is off, then verify the row's Copy action.
xdotool mousemove --window "$window_id" 730 78 click 1
sleep 2
printf %s 'controlled replacement while capture is off' | xclip -selection clipboard
xdotool mousemove --window "$window_id" 688 268 click 1
sleep 1
[[ "$(xclip -selection clipboard -o)" == 'ClipVault Linux UI capture receipt' ]]
# Capture a controlled PNG, then verify Copy preserves its exact bytes.
xdotool mousemove --window "$window_id" 730 78 click 1
sleep 2
printf %s 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQbD/+HwAEywJ3k0b7vgAAAABJRU5ErkJggg==' | base64 -d > /tmp/clipvault-fixture.png
xclip -selection clipboard -target image/png -i /tmp/clipvault-fixture.png
sleep 3
import -window root /evidence/linux-image.png
xdotool mousemove --window "$window_id" 730 78 click 1
sleep 2
printf %s 'controlled replacement before image Copy' | xclip -selection clipboard
xdotool mousemove --window "$window_id" 688 "$SMOKE_IMAGE_COPY_Y" click 1
sleep 1
xclip -selection clipboard -target image/png -o > /tmp/clipvault-copied.png
cmp /tmp/clipvault-fixture.png /tmp/clipvault-copied.png

# Clipboard file lists are parsed locally and stage encrypted file content,
# never the URI or path. The isolated smoke workspace starts unpaired.
xdotool mousemove --window "$window_id" 730 78 click 1
sleep 2
printf '%s' 'ClipVault file transfer fixture' > "$SMOKE_ROOT/local-file.txt"
printf 'file://%s\r\n' "$SMOKE_ROOT/local-file.txt" | xclip -selection clipboard -target text/uri-list
for attempt in $(seq 1 30); do
  if python3 - "$XDG_DATA_HOME/clipvault/clips.sqlite" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
try:
    ok = db.execute("select count(*) from file_transfers where state='staged'").fetchone()[0] > 0
except sqlite3.Error:
    ok = False
raise SystemExit(0 if ok else 1)
PY
  then break; fi
  sleep 1
done
python3 - "$XDG_DATA_HOME/clipvault/clips.sqlite" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("select count(*) from file_transfers where state='staged'").fetchone()[0] > 0
PY
for attempt in $(seq 1 30); do
  if python3 - "$XDG_DATA_HOME/clipvault/clips.sqlite" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
raise SystemExit(0 if db.execute("select count(*) from events where payload is not null").fetchone()[0] >= 3 else 1)
PY
  then break; fi
  sleep 1
done
python3 - "$XDG_DATA_HOME/clipvault/clips.sqlite" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("select count(*) from events where payload is not null").fetchone()[0] >= 3
PY
sleep 1
import -window root /evidence/linux-history.png

# The explicit Add File control opens a native multi-select chooser. Pick one
# local file and verify it creates another staged descriptor.
xdotool mousemove --window "$window_id" 730 78 click 1
sleep 2
printf '%s' 'ClipVault explicit picker fixture' > "$SMOKE_ROOT/picker-file.txt"
xdotool mousemove --sync 28 28 click 1
sleep 2
import -window root /evidence/linux-file-picker.png
picker_id="$(xdotool search --onlyvisible --name '^Add files to share; available storage determines the size$' | head -1 || true)"
if [[ -z "$picker_id" ]]; then
  echo "FAIL: native Add File chooser did not open." >&2
  exit 1
fi
wait_for_window_focus "$picker_id"
xdotool key ctrl+l
sleep 1
printf %s "$SMOKE_ROOT/picker-file.txt" | xclip -selection clipboard
xdotool key ctrl+a ctrl+v
sleep 1
xdotool key Return
sleep 1
accept_visible_dialog_if_open '^Add files to share; available storage determines the size$'
sleep 3
python3 - "$XDG_DATA_HOME/clipvault/clips.sqlite" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("select count(*) from file_transfers where state='staged'").fetchone()[0] >= 2
assert db.execute("select count(*) from events where payload is not null").fetchone()[0] >= 4
PY
sleep 1
import -window root /evidence/linux-attachments.png

# Save one verified attachment through the native Save picker and verify exact
# bytes at the chosen destination (the recipient-side action users perform).
xdotool mousemove --window "$window_id" 670 267 click 1
sleep 2
import -window root /evidence/linux-file-save-picker.png
save_id="$(xdotool search --onlyvisible --name '^Save file from ClipVault$' | head -1 || true)"
if [[ -z "$save_id" ]]; then
  echo "FAIL: native Save picker did not open." >&2
  exit 1
fi
wait_for_window_focus "$save_id"
xdotool key ctrl+a
xdotool type --clearmodifiers "$SMOKE_SAVE_PATH"
sleep 1
xdotool key Return
sleep 1
accept_visible_dialog_if_open '^Save file from ClipVault$'
sleep 3
cmp "$SMOKE_ROOT/picker-file.txt" "$SMOKE_SAVE_PATH"

xdotool mousemove --window "$window_id" 638 28 click 1
sleep 2
import -window root /evidence/linux-devices.png
kill -0 "$app_pid"
cat /tmp/clipvault-ui.log
printf '%s\n' 'PASS: GTK text/PNG capture and exact Copy; URI-list and native file picker staging; verified attachment Save roundtrip; capture toggle; untrusted bridge caller rejected; screenshots captured.'
