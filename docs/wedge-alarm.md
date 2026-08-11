# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

`bin/fm-wedge-alarm-lib.sh` is the single owner of the channels below: which exist, whether each can deliver on this machine, how `auto` resolves, and how each is fired.
The same owner answers the away-mode entry pre-flight in `bin/fm-afk-launch.sh`, so entry and alarm never disagree about whether an alarm can reach the captain.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
  It is also the captain's explicit consent to the durable marker alone, so away-mode entry accepts it instead of refusing.
- `auto` or `default` resolves this platform's own reachable channels in order: `osascript` then `herdr` on macOS, `notify-send` then `herdr` elsewhere.
  A candidate whose carrier is positively disproven is dropped rather than proposed.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `notify-send` posts a freedesktop desktop notification at critical urgency, the Linux and BSD counterpart of that banner.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on wherever a channel resolves.
This is deliberate because the alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window.

## Whether a channel can actually deliver

A channel's binary being installed is not the same as its carrier working, and treating the two as equivalent is how a 19-hour stall alerted nobody on a host that had `notify-send` all along.
Each directive is therefore classified by probing the thing that carries the notification:

| directive | `available` when | `unavailable` when | `unproven` when |
| --- | --- | --- | --- |
| `osascript` | macOS with `osascript` installed | not macOS, or not installed | - |
| `notify-send` | installed and `org.freedesktop.Notifications` has an owner on the session bus | installed with no owner, or not installed | installed but no `gdbus`, `busctl`, or `dbus-send` can answer, or the one that ran did not answer within the watchdog |
| `herdr` | - | not installed, or no herdr server running | a herdr server is running, or `herdr status` did not answer within the watchdog |
| `command:<cmd>` | a command is present, which is the captain's own assertion | the directive carries no command | - |

A carrier probe is run under the same process-group watchdog as the notifiers, because the probes sit on the daemon's own alarm path and a hung session bus or herdr server would otherwise block the single-threaded housekeeping loop during the alarm.
A probe the watchdog stops is `unproven`, never `available`: the safe direction is to leave the doubt for the self-test or the alarm's own delivery attempt to resolve.

`herdr` is never better than `unproven` from a probe because `herdr notification show` exits 0 while reporting `{"shown":false,"reason":"disabled"}`, so its exit status cannot distinguish a delivered notification from a suppressed one.
The notifier reads herdr's own `shown` field instead, and away-mode entry resolves the remaining doubt by delivering one clearly-labeled check notification.

That check carries its own title and body on every carrier - "firstmate: away-mode alert channel check (nothing is wrong)" - and never the alarm's "firstmate: away-mode escalations WEDGED".
It is delivered on every away-mode entry, every idempotent refresh, and every `preflight` report, so wearing the alarm's title would teach the captain to dismiss on sight the one notification this alarm exists to make credible.

At alarm time every resolved channel is attempted regardless of its classification: attempting costs nothing, a probe can be stale, and the alarm is the last line of defence.
The classification decides what `auto` resolves to and what the entry pre-flight reports.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `notify-send`, `herdr`, the carrier probes above, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## When no channel can deliver

An alarm that reaches nobody must not look like an alarm that reached someone.
When no configured or resolved channel delivers, the alarm records an `ALERT UNREACHABLE` outcome naming each channel's concrete failure, logs it as an error, and puts it on the FIRST line of `state/.subsuper-inject-wedged` - the line `bin/fm-afk-return.sh` surfaces on the "while you were out" catch-up.
A delivered alarm names its channel there instead, and a configured `off` records the captain's own choice.

That is the last-resort record, not the fix.
The fix is that a FIRST away-mode entry refuses to start a supervisor whose alarm cannot reach anyone, while the captain is still there to fix it.
A re-entry over an away mode that is already armed reports the same failure just as loudly and still re-arms the supervisor, because refusing there would leave away mode flagged active with no daemon left to raise any alarm at all.
See the `/afk` skill for the entry contract and `bin/fm-afk-launch.sh preflight` to ask the same question at any time.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
Exactly two executed programs deliver real notifications: the away-mode daemon raising an alarm, and the away-mode launcher running its entry pre-flight.
Everything else that sources the library, tests included, defaults that seam to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation, and a suite that runs either of those two scripts as a subprocess sets the seam itself.
Production leaves the seam unset and uses the configured real channels.

The pre-flight's own blast radius is bounded to a channel the probe left `unproven`, and never to a `command:` directive, so entering away mode can never page the captain's phone as a side effect.

`tests/fm-daemon.test.sh` covers directive parsing, platform resolution, carrier probes, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, the herdr `shown` verdict, the unreachable outcome, and safe `command:` summary delivery.
`tests/fm-afk-preflight-live-e2e.test.sh` is the opt-in guard that measures each channel's classification against an independent observation of its carrier on a real machine.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the dated per-platform proof.
