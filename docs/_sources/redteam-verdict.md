# Red-team: shellmux

## Verdict: survives as a small correctness demo; do not sell it as a serious broker

The idea is credible only because the hard part is narrow: deadline firing with race-free stage-then-poke semantics. The hostile dismissal is that shell pub/sub is an old stunt and a slow subscriber or torn FIFO write will wreck it. The spec now handles this by naming TerminalPhone's `printf > fifo &` pattern as the bug, not the fix.

The risk is dependency honesty. This is not POSIX `sh`: it needs bash features, `flock`, `timeout`, `socat`, and maybe fractional `read -t`. Say that before a judge runs it on macOS bash 3 or dash.

## Patches

- Put the deadline chaos test first in the README and demo. The broker exists to prove that one property.
- Replace "zero idle CPU" with "blocks between computed deadlines; worst-case latency is idle_poll".
- Add a platform matrix: bash 4 fractional timers vs whole-second timers.
- Make length-prefixed framing mandatory if the timeout-write fallback remains.
- If the bounded ring drainer is not actually one long-lived process per subscriber, cut the backpressure claim.

## Source Checks

- honker's next-deadline query: `honker/honker-core/src/honker_ops.rs:536-558`.
- honker watcher prune/death guard: `honker/honker-core/src/lib.rs:908-960`.
- TerminalPhone FIFO/socat shape: `terminalphone/terminalphone.sh:1204-1207`, `:1520`, `:1676`.
- TerminalPhone fd binding: `terminalphone/terminalphone.sh:1886-1887`.
