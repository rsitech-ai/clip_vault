#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:99
export GSK_RENDERER=cairo
export GTK_A11Y=none
export XDG_SESSION_TYPE=x11
export XDG_DATA_HOME=/tmp/clipvault-ui-data
export XDG_CONFIG_HOME=/tmp/clipvault-ui-config
export XDG_RUNTIME_DIR=/tmp/clipvault-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
Xvfb "$DISPLAY" -screen 0 1100x800x24 >/tmp/xvfb.log 2>&1 &
printf '%s' 'isolated-ui-keyring-password' | gnome-keyring-daemon --unlock --components=secrets >/tmp/keyring.log 2>&1
"${CLIPVAULT_LINUX_BINARY:-/build/debug/clipvault-linux}" >/tmp/clipvault-ui.log 2>&1 &
app_pid=$!
trap 'kill "$app_pid" >/dev/null 2>&1 || true' EXIT
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
xdotool mousemove --window "$window_id" 730 85 click 1
sleep 2
printf %s 'ClipVault Linux UI capture receipt' | xclip -selection clipboard
sleep 3
import -window root /evidence/linux-history.png
# An ordinary session-bus caller must not be accepted as the GNOME adapter.
bridge_reply="$(dbus-send --session --print-reply --dest=com.rsitech.ClipVault.Capture /com/rsitech/ClipVault/Capture com.rsitech.ClipVault.Capture.Heartbeat)"
[[ "$bridge_reply" == *'boolean false'* ]]
# Replace the clipboard while capture is off, then verify the row's Copy action.
xdotool mousemove --window "$window_id" 730 85 click 1
sleep 2
printf %s 'controlled replacement while capture is off' | xclip -selection clipboard
xdotool mousemove --window "$window_id" 670 328 click 1
sleep 1
[[ "$(xclip -selection clipboard -o)" == 'ClipVault Linux UI capture receipt' ]]
# Capture a controlled PNG, then verify Copy preserves its exact bytes.
xdotool mousemove --window "$window_id" 730 85 click 1
sleep 2
printf %s 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQbD/+HwAEywJ3k0b7vgAAAABJRU5ErkJggg==' | base64 -d > /tmp/clipvault-fixture.png
xclip -selection clipboard -target image/png -i /tmp/clipvault-fixture.png
sleep 3
import -window root /evidence/linux-image.png
xdotool mousemove --window "$window_id" 730 85 click 1
sleep 2
printf %s 'controlled replacement before image Copy' | xclip -selection clipboard
xdotool mousemove --window "$window_id" 670 328 click 1
sleep 1
xclip -selection clipboard -target image/png -o > /tmp/clipvault-copied.png
cmp /tmp/clipvault-fixture.png /tmp/clipvault-copied.png
xdotool mousemove --window "$window_id" 560 29 click 1
sleep 2
import -window root /evidence/linux-devices.png
kill -0 "$app_pid"
cat /tmp/clipvault-ui.log
printf '%s\n' 'PASS: GTK text/PNG capture and exact Copy; capture toggle; untrusted bridge caller rejected; screenshots captured.'
