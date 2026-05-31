# Implementation Plan: shellmux

## Stack & Dependencies

Bash 4+, `socat`, `flock`, `timeout`, `mkfifo`, `dd`, `lsof`/`ps` for tests. Reuse TerminalPhone's socat/fifo/process-cleanup shape and honker's deadline-computation discipline. Write shell scheduler and bounded subscriber path fresh.

## Architecture Units

- `accept`: `socat ... fork EXEC:handler`.
- `handler`: SUB/PUB parser, per-subscriber FIFO, traps.
- `fanout`: length-prefixed record delivery and drop counters.
- `drainer`: bounded per-subscriber ring or timeout fallback.
- `scheduler`: deferred files, min-deadline scan, wake FIFO.
- `tests`: deadline chaos, wedged subscriber, crash recovery.

## Milestones

- M0: deadline chaos test fires publishes inside compute-before-block window for N>=5000 with zero missed/duplicate deliveries.
- M1: file-backed deferred scheduler.
- M2: SUB handler and per-subscriber FIFO.
- M3: length-prefixed fanout and bounded drainer.
- M4: death cleanup and drop counters.
- M5: Pi demo and throughput/fd measurements.

## Core Proof Test

Chaos harness instruments scheduler to pause between `next=min` and `read -t`, publishes due files during that pause, and asserts every sequence fires once. Wedged subscriber flood test asserts publisher process/fd count stays flat.

## Estimate & Risk

Effort: 2-3 days. Biggest risk: backpressure implementation becomes more code than the broker; keep the correctness pitch on deadlines.
