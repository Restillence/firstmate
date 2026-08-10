#!/usr/bin/env bash
# bin/fm-wedge-alarm-lib.sh - the ONE fleet-wide owner of the away-mode wedge
# alarm's ACTIVE ALERT CHANNELS: which channels exist, whether a given channel
# can actually deliver on this machine right now, how `auto` resolves, and how
# each channel is fired. Two callers share it, and they must ask the same
# question:
#
#   - bin/fm-supervise-daemon.sh fires the alarm when a buffered escalation
#     cannot be delivered past FM_MAX_DEFER_SECS.
#   - bin/fm-afk-launch.sh runs the same resolution as an away-mode ENTRY
#     pre-flight, so a home with no reachable channel is told BEFORE the captain
#     walks away, not after.
#
# WHY THE AVAILABILITY PROBE EXISTS (task fm-afk-wedge-unreachable). On
# 2026-08-09 an away-mode daemon deferred 4714 escalations over 19 hours and the
# alarm reached nobody. Two separate reasons, both fixed here:
#
#   1. `auto` resolved an OS channel on macOS only. On Linux it resolved
#      NOTHING and logged that the durable marker was the only signal, even
#      though notify-send was installed - a last-resort alarm whose only channel
#      is a file nobody reads is not an alarm.
#   2. Presence is not deliverability. On that same host `notify-send` is
#      installed but no org.freedesktop.Notifications owner exists, so it exits
#      1; and `herdr notification show` exits 0 while reporting
#      {"shown":false,"reason":"disabled"} - a channel that looked like a
#      success and displayed nothing. So every channel here is classified by a
#      probe of the thing that actually carries the notification, and the herdr
#      notifier believes herdr's own `shown` field rather than its exit status.
#
# THE THREE-STATE CLASSIFICATION each channel reports:
#   available   the carrier was positively confirmed (or the captain configured
#               the channel explicitly, which is their own assertion).
#   unavailable positively disproven: wrong platform, missing binary, or a
#               carrier that answered "no".
#   unproven    the channel might work and nothing short of delivering can tell.
#               Callers that need a verdict resolve this with a real self-test
#               (wedge_alarm_selftest), never by assuming.
# Only `available` counts as a reachable alarm; `unproven` alone is reported as
# a gap so it is fixed at entry rather than discovered during a wedge.
#
# Details in a status line are FIXED strings. A `command:` directive and an
# unrecognized directive are never echoed back, because the captain's alarm
# command can carry a pager token.
#
# Re-sourcing is a cheap idempotent redefinition, so this file needs no include
# guard (matching bin/fm-composer-lib.sh).

WEDGE_ALARM_TIMEOUT_SECS_DEFAULT=10
WEDGE_ALARM_NOTIFIER_PID=

# Diagnostic sink. Callers override it: the daemon points it at its timestamped
# daemon log, the away launcher at its own captain-facing reporter. The default
# keeps a bare `source` usable without either.
fm_wedge_alarm_log() { printf '%s\n' "$*" >&2; }

# Print the configured channel directives, one per line. FM_WEDGE_ALARM_CHANNEL
# wins (a single directive); else each non-empty, non-comment line of
# config/wedge-alarm; else "auto".
wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  cfg="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/wedge-alarm"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

# Does the freedesktop notification service currently have an owner on the
# session bus? That D-Bus name, not the notify-send binary, is what carries a
# Linux desktop notification, so it is the structural signal. Three independent
# clients are accepted (glib, systemd, dbus) and any one of them answers; when
# none is installed the answer is genuinely unknown and that is reported as
# such rather than guessed either way.
#   0 = owned, 1 = not owned, 2 = no probe tool installed
wedge_alarm_notification_service_owned() {
  local name=org.freedesktop.Notifications
  if command -v gdbus >/dev/null 2>&1; then
    gdbus call --session --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner "$name" 2>/dev/null | grep -qw true
    return
  fi
  if command -v busctl >/dev/null 2>&1; then
    busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
      org.freedesktop.DBus NameHasOwner s "$name" 2>/dev/null | grep -qw true
    return
  fi
  if command -v dbus-send >/dev/null 2>&1; then
    dbus-send --session --print-reply --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner "string:$name" 2>/dev/null |
      grep -qw true
    return
  fi
  return 2
}

# Is a herdr server running and compatible? Read-only: `herdr status --json`
# never starts a server and never touches a session.
wedge_alarm_herdr_server_running() {
  local out
  command -v herdr >/dev/null 2>&1 || return 1
  out=$(herdr status --json 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -e '.server.running == true' >/dev/null 2>&1
    return
  fi
  printf '%s' "$out" | grep -q '"running"[[:space:]]*:[[:space:]]*true'
}

# wedge_alarm_channel_status: classify ONE directive as
# "<available|unavailable|unproven|disabled><TAB><fixed detail>".
wedge_alarm_channel_status() {  # <directive>
  local directive=$1
  case "$directive" in
    off)
      printf 'disabled\tactive alerts turned off in config/wedge-alarm' ;;
    osascript)
      if [ "$(uname)" != Darwin ]; then
        printf 'unavailable\tosascript posts a macOS notification and this is not macOS'
      elif ! command -v osascript >/dev/null 2>&1; then
        printf 'unavailable\tosascript is not installed'
      else
        printf 'available\tmacOS Notification Center'
      fi ;;
    notify-send)
      if ! command -v notify-send >/dev/null 2>&1; then
        printf 'unavailable\tnotify-send is not installed'
      else
        case "$(wedge_alarm_notification_service_owned; printf '%s' $?)" in
          0) printf 'available\tdesktop notification service' ;;
          1) printf 'unavailable\tnotify-send is installed but no desktop notification service is running' ;;
          *) printf 'unproven\tnotify-send is installed but no gdbus, busctl, or dbus-send is available to confirm a notification service' ;;
        esac
      fi ;;
    herdr)
      if ! command -v herdr >/dev/null 2>&1; then
        printf 'unavailable\therdr is not installed'
      elif ! wedge_alarm_herdr_server_running; then
        printf 'unavailable\tno herdr server is running'
      else
        printf 'unproven\therdr is running but only a real notification proves it is not suppressed'
      fi ;;
    command:*)
      if [ -n "${directive#command:}" ]; then
        printf 'available\tconfigured alert command'
      else
        printf 'unavailable\tthe command: directive carries no command'
      fi ;;
    *)
      printf 'unavailable\tunrecognized channel directive' ;;
  esac
}

# A directive's safe display name. A `command:` directive can carry a pager
# token, so it is never echoed back to a caller that reports or records it.
wedge_alarm_channel_label() {  # <directive>
  case "$1" in
    osascript|notify-send|herdr|off|auto|default) printf '%s' "$1" ;;
    command:*) printf 'command' ;;
    *) printf 'unrecognized directive' ;;
  esac
}

# Ordered platform channels `auto` may resolve to. Built-in OS notification
# first, then herdr, which is pane-independent and reaches a captain whose whole
# fleet runs inside it. Every candidate is filtered through the probe above, so
# `auto` never resolves to a channel already known not to deliver.
wedge_alarm_auto_channels() {
  local candidate state
  case "$(uname)" in
    Darwin) set -- osascript herdr ;;
    *) set -- notify-send herdr ;;
  esac
  for candidate in "$@"; do
    state=$(wedge_alarm_channel_status "$candidate" | cut -f1)
    case "$state" in
      available|unproven) printf '%s\n' "$candidate" ;;
    esac
  done
}

# Expand the configured directives into the concrete channels that will actually
# be attempted: `auto`/`default` become this platform's resolvable channels, and
# an `auto` that resolves to nothing prints nothing. `off` is preserved so the
# caller can honor it.
wedge_alarm_resolved_channels() {
  local ch
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    case "$ch" in
      auto|default) wedge_alarm_auto_channels ;;
      *) printf '%s\n' "$ch" ;;
    esac
  done < <(wedge_alarm_configured_channels)
}

wedge_alarm_run_bounded() {
  local channel=$1 timeout monitor_was_on=0 pid start elapsed rc
  shift
  timeout=${FM_WEDGE_ALARM_TIMEOUT_SECS:-$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case $- in
    *m*) ;;
    *) fm_wedge_alarm_log "wedge alarm: ${channel} notifier skipped because its watchdog could not start"; return 125 ;;
  esac
  "$@" &
  pid=$!
  WEDGE_ALARM_NOTIFIER_PID=$pid
  start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      wedge_alarm_stop_active_notifier
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fm_wedge_alarm_log "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  WEDGE_ALARM_NOTIFIER_PID=
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return "$rc"
}

wedge_alarm_stop_active_notifier() {
  local pid=${WEDGE_ALARM_NOTIFIER_PID:-}
  [ -n "$pid" ] || return 0
  WEDGE_ALARM_NOTIFIER_PID=
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The single execution seam for every configured notifier channel.
# FM_WEDGE_ALARM_EXEC, when set, REPLACES the real notifier: the resolved channel
# name and summary are handed to that command instead of ever invoking osascript
# or notify-send or herdr or a captain-supplied command. This is the one injection point the test harness forces to a recorder
# so no test can post a real desktop notification - the library-mode guard at the
# foot of this file defaults it to "discard" whenever this library is SOURCED by
# anything other than the executed daemon, which is the only way a test reaches
# these functions. The special value "discard" fires nothing; unset means
# production (the executed daemon), so the real channels fire.
wedge_alarm_os_notifier_override() {  # <channel> <summary>
  local channel=$1 summary=$2 rc exec_override=${FM_WEDGE_ALARM_EXEC:-}
  case "$exec_override" in
    '') return 2 ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      fm_wedge_alarm_log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
}

# Post a macOS Notification Center banner. `display notification` is OS-level,
# independent of any terminal pane or multiplexer status-line. The summary is
# passed as an argv item (never interpolated into the AppleScript source) so its
# text can never break the script. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_osascript() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override osascript "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v osascript >/dev/null 2>&1 || {
    WEDGE_ALARM_CHANNEL_REASON="osascript is not installed"
    fm_wedge_alarm_log "wedge alarm: osascript not found; cannot post a macOS notification"; return 1; }
  wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "firstmate: away-mode escalations WEDGED" sound name "Basso"' \
    -e 'end run' "$summary" >/dev/null 2>&1 && return 0
  WEDGE_ALARM_CHANNEL_REASON="osascript could not post a notification"
  fm_wedge_alarm_log "wedge alarm: osascript notification failed"
  return 1
}

# Post a freedesktop desktop notification, the Linux/BSD counterpart of the
# macOS banner above and equally independent of any pane. Critical urgency
# because the alarm only ever fires on a real wedge; both the title and the
# summary are argv items. Best-effort: logs and returns 1 on failure, which is
# what a missing notification service produces.
wedge_alarm_via_notify_send() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override notify-send "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v notify-send >/dev/null 2>&1 || {
    WEDGE_ALARM_CHANNEL_REASON="notify-send is not installed"
    fm_wedge_alarm_log "wedge alarm: notify-send not found; cannot post a desktop notification"; return 1; }
  wedge_alarm_run_bounded notify-send notify-send --urgency=critical --app-name=firstmate \
    "firstmate: away-mode escalations WEDGED" "$summary" >/dev/null 2>&1 && return 0
  WEDGE_ALARM_CHANNEL_REASON="notify-send failed, which is what an absent desktop notification service produces"
  fm_wedge_alarm_log "wedge alarm: notify-send notification failed (no desktop notification service?)"
  return 1
}

# Post a herdr UI notification - herdr's own surface, separate from the pane and
# its status-line.
#
# herdr's EXIT STATUS is not the delivery verdict: a suppressed notification
# still exits 0 and reports {"shown":false,"reason":"disabled"} (observed on
# herdr 0.7.4), so trusting the exit status would report a silent channel as a
# working one - the precise failure this alarm exists to avoid. The verdict is
# herdr's own `shown` field. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_herdr() {  # <summary>
  local summary=$1 rc out reason shown
  wedge_alarm_os_notifier_override herdr "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v herdr >/dev/null 2>&1 || {
    WEDGE_ALARM_CHANNEL_REASON="herdr is not installed"
    fm_wedge_alarm_log "wedge alarm: herdr not found; cannot post a herdr notification"; return 1; }
  out=$(mktemp "${TMPDIR:-/tmp}/fm-wedge-herdr.XXXXXX") || {
    WEDGE_ALARM_CHANNEL_REASON="the herdr notification result could not be captured"
    fm_wedge_alarm_log "wedge alarm: could not capture the herdr notification result"; return 1; }
  wedge_alarm_run_bounded herdr herdr notification show "firstmate: away-mode escalations WEDGED" \
    --body "$summary" --sound request >"$out" 2>/dev/null
  rc=$?
  shown=1
  if [ "$rc" -ne 0 ]; then
    shown=0
    reason="herdr exited $rc"
  elif command -v jq >/dev/null 2>&1; then
    jq -e '.result.shown == true' "$out" >/dev/null 2>&1 || {
      shown=0
      reason=$(jq -r '.result.reason // "no reason reported"' "$out" 2>/dev/null) || reason="no reason reported"
    }
  elif ! grep -q '"shown"[[:space:]]*:[[:space:]]*true' "$out"; then
    shown=0
    reason="herdr reported the notification was not shown"
  fi
  rm -f "$out"
  [ "$shown" -eq 1 ] && return 0
  WEDGE_ALARM_CHANNEL_REASON="herdr accepted the notification but did not show it (${reason})"
  fm_wedge_alarm_log "wedge alarm: $WEDGE_ALARM_CHANNEL_REASON"
  return 1
}

# Run a captain-supplied command with the summary on $1 and on stdin, so an
# alert can reach a phone/pager (ntfy, Slack, SMS) even when the captain is away
# from the machine entirely. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_command() {  # <cmd> <summary>
  local cmd=$1 summary=$2 rc
  if [ "${WEDGE_ALARM_EMIT_ACTIVE:-}" != 1 ]; then
    wedge_alarm_emit command "$summary" "$cmd"
    return $?
  fi
  [ -n "$cmd" ] || {
    WEDGE_ALARM_CHANNEL_REASON="the command: directive carries no command"
    fm_wedge_alarm_log "wedge alarm: empty command: channel; nothing to run"; return 1; }
  wedge_alarm_run_bounded command sh -c "$cmd" fm-wedge-alarm "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  WEDGE_ALARM_CHANNEL_REASON="the configured alert command exited $rc"
  fm_wedge_alarm_log "wedge alarm: command channel exited $rc (command redacted)"
  return 1
}

wedge_alarm_emit() {  # <channel> <summary> [command]
  local channel=$1 summary=$2 cmd=${3:-} rc exec_override=${FM_WEDGE_ALARM_EXEC:-} WEDGE_ALARM_EMIT_ACTIVE=1
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      fm_wedge_alarm_log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
  case "$channel" in
    osascript) wedge_alarm_via_osascript "$summary" ;;
    notify-send) wedge_alarm_via_notify_send "$summary" ;;
    herdr) wedge_alarm_via_herdr "$summary" ;;
    command) wedge_alarm_via_command "$cmd" "$summary" ;;
  esac
}

# Fire ONE resolved channel and report whether it delivered. Returns 0 when the
# channel reported success, 1 otherwise, and leaves the concrete failure cause
# in WEDGE_ALARM_CHANNEL_REASON so a caller reports what actually happened
# instead of restating the probe's guess. Callers hold the ordering policy.
wedge_alarm_fire_channel() {  # <channel> <summary>
  local ch=$1 summary=$2 rc
  WEDGE_ALARM_CHANNEL_REASON=
  case "$ch" in
    osascript|notify-send|herdr) wedge_alarm_emit "$ch" "$summary" ;;
    command:*) wedge_alarm_emit command "$summary" "${ch#command:}" ;;
    *)
      fm_wedge_alarm_log "wedge alarm: unrecognized active-alert channel directive (redacted); marker still written"
      WEDGE_ALARM_CHANNEL_REASON="unrecognized channel directive"
      return 1 ;;
  esac
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  # A fallback reason must never echo the directive back: a `command:` directive
  # can carry a pager token, and this reason ends up in the durable marker.
  case "$ch" in
    command:*) WEDGE_ALARM_CHANNEL_REASON=${WEDGE_ALARM_CHANNEL_REASON:-"the configured alert command did not deliver"} ;;
    *) WEDGE_ALARM_CHANNEL_REASON=${WEDGE_ALARM_CHANNEL_REASON:-"$ch did not deliver"} ;;
  esac
  return 1
}

# Fire every configured active-alert channel, best-effort, and record the
# outcome in WEDGE_ALARM_LAST_OUTCOME as a short fixed phrase a caller can put
# in front of the captain. Always returns 0: a channel failure can never abort
# the caller or the daemon loop. Any `off` directive disables the alert
# regardless of position. Every notifier routes through the test-forced
# recorder seam.
#
# ALARM TIME ATTEMPTS EVERY RESOLVED CHANNEL, including one the probe calls
# unavailable: attempting costs nothing, a probe can be stale, and the alarm is
# the last line of defence. The probe's job is resolving `auto` and answering
# the entry pre-flight, not vetoing a delivery the captain configured.
#
# The UNREACHABLE outcome is the point of this function. Before this task an
# `auto` that resolved to nothing merely logged that the marker was the only
# signal, so a wedge with no channel looked exactly like a wedge that alerted;
# the caller now gets a distinct outcome it can put in the durable record.
wedge_alarm_notify() {  # <summary> <marker>
  local summary=$1 marker=$2 ch delivered='' reasons=''
  local -a channels=()
  WEDGE_ALARM_LAST_OUTCOME=
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    if [ "$ch" = off ]; then
      WEDGE_ALARM_LAST_OUTCOME="active alert turned off in config/wedge-alarm"
      return 0
    fi
  done < <(wedge_alarm_configured_channels)
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    channels+=("$ch")
  done < <(wedge_alarm_resolved_channels)
  for ch in "${channels[@]}"; do
    if wedge_alarm_fire_channel "$ch" "$summary"; then
      delivered="${delivered:+$delivered, }$ch"
    else
      reasons="${reasons:+$reasons; }${WEDGE_ALARM_CHANNEL_REASON:-$ch did not deliver}"
    fi
  done
  if [ -n "$delivered" ]; then
    WEDGE_ALARM_LAST_OUTCOME="active alert delivered via $delivered"
    return 0
  fi
  [ "${#channels[@]}" -gt 0 ] \
    || reasons="no active alert channel resolves on $(uname)"
  WEDGE_ALARM_LAST_OUTCOME="ALERT UNREACHABLE: ${reasons:-no channel delivered}; set config/wedge-alarm (e.g. a command: directive) - durable marker $marker is the only remaining signal"
  fm_wedge_alarm_log "ERROR: $WEDGE_ALARM_LAST_OUTCOME"
  return 0
}

# wedge_alarm_selftest: resolve an `unproven` channel by actually delivering a
# clearly-labeled check through it, because nothing short of delivering can tell
# (herdr accepts and silently suppresses). Used by the away-mode entry
# pre-flight only, never by the alarm itself: the alarm's own delivery is its
# test. Returns 0 when the channel demonstrably delivered.
wedge_alarm_selftest() {  # <channel>
  wedge_alarm_fire_channel "$1" \
    "away-mode alert channel check - firstmate can reach you while you are away"
}

# wedge_alarm_preflight: report, one channel per line as
# "<state><TAB><channel><TAB><detail>", whether this home can raise an active
# alarm at all. Each `unproven` channel is resolved by one real self-test
# delivery, so the report states what the channel DID, not what it might do.
#   0  at least one channel can reach the captain
#   1  no channel can reach the captain
#   2  the captain turned active alerts off, accepting the durable marker alone
wedge_alarm_preflight() {
  local ch state detail deliverable='' off=''
  while IFS= read -r ch; do
    [ "$ch" = off ] || continue
    off=1
  done < <(wedge_alarm_configured_channels)
  if [ -n "$off" ]; then
    printf 'disabled\toff\tactive alerts turned off in config/wedge-alarm\n'
    return 2
  fi
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    IFS=$'\t' read -r state detail <<< "$(wedge_alarm_channel_status "$ch")"
    if [ "$state" = unproven ]; then
      if wedge_alarm_selftest "$ch"; then
        state=available
        detail="a check notification was delivered"
      else
        state=unavailable
        detail="a check notification was not delivered: ${WEDGE_ALARM_CHANNEL_REASON:-no reason reported}"
      fi
    fi
    [ "$state" = available ] && deliverable=1
    printf '%s\t%s\t%s\n' "$state" "$(wedge_alarm_channel_label "$ch")" "$detail"
  done < <(wedge_alarm_resolved_channels)
  [ -n "$deliverable" ]
}

# Library-mode notifier safety. This file is ALWAYS sourced, so "am I library
# mode" is decided by the program that did the sourcing. Exactly two executed
# programs deliver real notifications - the away-mode daemon raising an alarm
# and the away-mode launcher running its entry pre-flight - and everything else,
# every test included, defaults the FM_WEDGE_ALARM_EXEC seam to "discard" unless
# the embedder already wired one (e.g. the recorder in tests/wake-helpers.sh).
# It is exported so a real daemon a test later spawns inherits the safe default
# too. A test that runs either of those two scripts as a subprocess must set the
# seam itself; the pre-flight's own blast radius is bounded to a channel the
# probe left `unproven`, and never to a `command:` pager.
case "${0##*/}" in
  fm-supervise-daemon.sh|fm-afk-launch.sh) ;;
  *)
    : "${FM_WEDGE_ALARM_EXEC:=discard}"
    export FM_WEDGE_ALARM_EXEC
    ;;
esac
