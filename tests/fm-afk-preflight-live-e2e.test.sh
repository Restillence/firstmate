#!/usr/bin/env bash
# tests/fm-afk-preflight-live-e2e.test.sh - opt-in live guard for the away-mode
# ENTRY PRE-FLIGHT (bin/fm-afk-launch.sh), which refuses to start away mode when
# its delivery path is already blocked.
#
# Why this file exists: both halves of that pre-flight read a surface somebody
# else controls, and a stub can only confirm the assumption already written into
# the stub.
#
#   COMPOSER (harness-dependent). The verdict comes from how a harness draws its
#   own composer - box borders, prompt glyph, ghost/placeholder text - all of
#   which a vendor changes without notice. A harness whose IDLE composer stops
#   reading `empty` would make /afk refuse for no reason; one whose composer
#   stops reading `pending` when text is sitting in it would let away mode start
#   over a captain's half-typed line. Each installed harness is launched bare,
#   with no prompt, so this consumes no model tokens.
#
#   ALERT CHANNEL (platform-dependent). A channel's binary being installed is
#   not the same as its carrier working: notify-send exits 1 with no
#   org.freedesktop.Notifications owner, and herdr exits 0 while reporting
#   {"shown":false}. This half checks each classification against an INDEPENDENT
#   observation of the same carrier, so a drifted probe fails here instead of
#   silently reporting a silent alarm as a working one.
#
# Standard CI has no harness binaries, no desktop session, and no herdr server,
# so this is opt-in and on-demand. The portable counterparts that pin the logic
# in CI are tests/fm-afk-launch.test.sh (entry pre-flight, real tmux panes) and
# tests/fm-daemon.test.sh (channel resolution and the alarm outcome). Run this
# guard after any harness upgrade, after a desktop or herdr change, and before
# trusting a refreshed docs/verification/supervision.md entry.
#
# FM_AFK_PREFLIGHT_LIVE_HERDR_NOTIFY=1 additionally resolves the herdr channel
# the only way it can be resolved - by asking herdr to show one clearly-labeled
# notification. It is separately opt-in because it is visible.
set -u

if [ "${FM_AFK_PREFLIGHT_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AFK_PREFLIGHT_LIVE_E2E=1 to run the installed-harness away-mode pre-flight guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-afk-preflight-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-preflight-live.XXXXXX")
SESSION=preflight

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wedge-alarm-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Mirror bin/fm-spawn.sh's own resolution order so this guard covers the same
# binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

wait_for_composer_state() {  # <target> <wanted> <attempts>
  local target=$1 wanted=$2 attempts=$3 state=
  while [ "$attempts" -gt 0 ]; do
    state=$(fm_backend_composer_state tmux "$target")
    [ "$state" = "$wanted" ] && return 0
    attempts=$((attempts - 1))
    sleep 0.2
  done
  printf '%s' "$state"
  return 1
}

# Is the harness's window still there? A first-run prompt can be an update
# offer that EXITS the harness when answered, and every later probe against a
# gone window would otherwise spray raw tmux errors over the report.
harness_window_alive() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" list-panes -t "$1" >/dev/null 2>&1
}

# Has the harness actually PUT A COMPOSER ON SCREEN yet? Without this, a pane
# still painting, sitting on a first-run notice, or dead at a blank row can
# report `empty` from the non-bordered fallback row and turn the whole case
# vacuous - a guard that proves the harness renders nothing at all. The signal is
# structural and independent of the verdict under test: the cursor sits inside a
# composer box, or on a row that starts with an agent prompt glyph.
composer_is_on_screen() {  # <target>
  local target=$1 cy plain row
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || return 1
  case "$cy" in ''|*[!0-9]*) return 1 ;; esac
  plain=$(tmux capture-pane -p -t "$target" -S 0 -E - 2>/dev/null) || return 1
  fm_tmux_find_composer_box "$cy" "$plain" >/dev/null 2>&1 && return 0
  row=$(printf '%s\n' "$plain" | sed -n "$((cy + 1))p")
  row=${row#"${row%%[![:space:]]*}"}
  case "$row" in
    '❯'*|'›'*|'⟩'*) return 0 ;;
  esac
  return 1
}

wait_for_composer_on_screen() {  # <target> <attempts>
  local target=$1 attempts=$2
  while [ "$attempts" -gt 0 ]; do
    composer_is_on_screen "$target" && return 0
    attempts=$((attempts - 1))
    sleep 0.2
  done
  return 1
}

# --- 1. composer verdict per installed harness ------------------------------

CHECKED=0
SKIPPED=

for harness in claude codex opencode pi pi-signed grok kimi muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its composer verdict is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"
  cursor_row=
  dismissed=0
  settled_a=
  settled_b=

  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" \
    || fail "$harness ($version): could not launch a window for the composer probe"

  # A first-run notice - folder trust, an update prompt - sits in front of the
  # composer on a fresh home, and some of them are drawn with the SAME prompt
  # glyph as a composer, so structure alone cannot tell them apart. Dismiss with
  # a bounded number of Enters (an Enter on an already-empty composer is a
  # no-op), then require the pane to hold still, so the verdict below is read
  # from a settled composer rather than a dialog mid-teardown.
  # One unconditional Enter first. A first-run prompt is drawn with the SAME
  # prompt glyph as a composer and can sit perfectly still, so no structural test
  # distinguishes the two - and on an already-accepted harness an Enter into an
  # empty composer is a no-op. This is why the guard runs against a throwaway
  # working directory.
  sleep 3
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Enter 2>/dev/null || true
  sleep 3
  dismissed=0
  while [ "$dismissed" -lt 3 ]; do
    harness_window_alive "$target" || break
    wait_for_composer_on_screen "$target" 100 || true
    settled_a=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null || true)
    sleep 2
    settled_b=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null || true)
    if [ "$settled_a" = "$settled_b" ] && composer_is_on_screen "$target"; then
      break
    fi
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Enter 2>/dev/null || true
    dismissed=$((dismissed + 1))
    sleep 2
  done
  if ! harness_window_alive "$target"; then
    SKIPPED="$SKIPPED $harness"
    note "unmeasured: $harness $version exited during its first-run prompt here, so its verdict is unverified"
    continue
  fi
  if ! composer_is_on_screen "$target"; then
    SKIPPED="$SKIPPED $harness"
    note "unmeasured: $harness $version never settled on a composer here (first-run prompt, or not authenticated), so its verdict is unverified"
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true
    continue
  fi

  # An idle harness must read affirmatively empty, or away-mode entry refuses a
  # delivery path that is in fact fine.
  if ! observed=$(wait_for_composer_state "$target" empty 150); then
    cursor_row=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" \
      | sed -n "$(("$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{cursor_y}')" + 1))p" \
      | od -An -c | tr -s ' ')
    fail "PRE-FLIGHT DRIFT: $harness $version has a composer on screen and IDLE, yet it reads '${observed:-unreadable}', not 'empty'. Away-mode entry refuses a healthy delivery path on this harness, and the daemon defers every escalation into it. Composer row bytes:${cursor_row}. Teach the composer owner (bin/fm-composer-lib.sh plus this backend's row capture) the shape this release actually draws."
  fi

  # Text sitting in the composer must read pending, or away-mode entry would
  # start a supervisor whose first escalation types over a captain's line.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" -l "here is my runpod api key:"
  if ! observed=$(wait_for_composer_state "$target" pending 150); then
    fail "PRE-FLIGHT DRIFT: $harness $version has unsubmitted text in its composer but reads '${observed:-unreadable}', not 'pending'. Away-mode entry would accept a blocked delivery path, and the injection guard that protects a half-typed line reads this same verdict."
  fi

  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true
  pass "away-mode pre-flight: $harness $version reads empty when idle and pending when text is waiting"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no installed harness put a composer on screen here, so this run proved nothing about the composer verdict; dismiss any first-run prompt or authenticate a harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed, or never presented a composer):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

# --- 2. alert-channel classification against an independent observation ------
#
# Each case observes the CARRIER directly and requires the library's verdict to
# agree. Both halves are stated so a disagreement names which one moved.

channel_state() {  # <directive>
  wedge_alarm_channel_status "$1" | cut -f1
}

expect_channel_state() {  # <directive> <expected> <because>
  local directive=$1 expected=$2 because=$3 actual
  actual=$(channel_state "$directive")
  [ "$actual" = "$expected" ] || fail \
    "ALERT CHANNEL DRIFT: the wedge alarm classifies '$directive' as '$actual', but $because says it should be '$expected'. bin/fm-wedge-alarm-lib.sh's probe for this channel no longer matches its carrier."
  note "channel $directive: $expected ($because)"
}

case "$(uname)" in
  Darwin)
    if command -v osascript >/dev/null 2>&1; then
      expect_channel_state osascript available "macOS with osascript installed"
    else
      expect_channel_state osascript unavailable "macOS without osascript installed"
    fi
    expect_channel_state notify-send unavailable "notify-send does not post macOS notifications"
    ;;
  *)
    expect_channel_state osascript unavailable "osascript posts macOS notifications and this is not macOS"
    if ! command -v notify-send >/dev/null 2>&1; then
      expect_channel_state notify-send unavailable "notify-send is not installed"
    elif command -v dbus-send >/dev/null 2>&1; then
      # An INDEPENDENT client for the same D-Bus name, so the probe and the
      # check cannot both be wrong in the same way.
      if dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
        string:org.freedesktop.Notifications 2>/dev/null | grep -qw true; then
        expect_channel_state notify-send available "dbus-send reports an org.freedesktop.Notifications owner"
      else
        expect_channel_state notify-send unavailable "dbus-send reports no org.freedesktop.Notifications owner"
      fi
    else
      note "channel notify-send: no independent D-Bus client installed, so its classification is unverified here"
    fi
    ;;
esac

if ! command -v herdr >/dev/null 2>&1; then
  expect_channel_state herdr unavailable "herdr is not installed"
elif herdr status --json 2>/dev/null | grep -q '"running"[[:space:]]*:[[:space:]]*true'; then
  expect_channel_state herdr unproven "a herdr server is running but only a real notification proves delivery"
  if [ "${FM_AFK_PREFLIGHT_LIVE_HERDR_NOTIFY:-0}" = 1 ]; then
    # The only way to resolve `unproven`: ask herdr to show one, and believe its
    # own `shown` field rather than its exit status.
    if FM_WEDGE_ALARM_EXEC='' wedge_alarm_via_herdr "FIRSTMATE TEST - IGNORE (away-mode alert channel check)"; then
      note "channel herdr: a real notification was shown, so this machine has a reachable alert channel"
    else
      note "channel herdr: herdr accepted a real notification and did not show it, so this machine has no reachable herdr alert channel"
    fi
  else
    note "channel herdr: set FM_AFK_PREFLIGHT_LIVE_HERDR_NOTIFY=1 to resolve it with one visible notification"
  fi
else
  expect_channel_state herdr unavailable "no herdr server is running"
fi

note "auto resolves to: $(wedge_alarm_auto_channels | tr '\n' ' ')"
pass "away-mode pre-flight: every alert channel's classification matches an independent observation of its carrier"

cleanup_all
trap - EXIT
