<p align="center">
  <img src="assets/logo.svg" alt="shellmux — race-free timed delivery, proven in shell" width="620">
</p>

<p align="center">
  <b>A content-blind topic pub/sub broker in shell — whose one hard, <i>proven</i> trick is a ~190-line deadline scheduler that fires timed messages race-free, with ~0% idle CPU and no timer wheel.</b>
</p>

<p align="center">
  <a href="#the-proof-why-this-exists"><img alt="proof" src="https://img.shields.io/badge/chaos%20N%3D5000-missed%3D0%20dup%3D0-2ea44f"></a>
  <img alt="idle cpu" src="https://img.shields.io/badge/idle%20CPU-~0%25-2ea44f">
  <img alt="tests" src="https://img.shields.io/badge/tests-10%20suites%2C%20each%20with%20a%20must--fail%20control-2ea44f">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="platform" src="https://img.shields.io/badge/platform-Linux%20(bash%E2%89%A54%20%2B%20socat%20%2B%20util--linux)-lightgrey">
</p>

---

## What is this?

`shellmux` is a tiny publish/subscribe message broker. A publisher writes a line to a **topic**;
every connected **subscriber** of that topic gets it. You can also schedule a message for later
(`--delay 30`, `--at <epoch>`) and it fires **on time**, even while the broker is otherwise idle.

It's built from `socat`, named pipes (FIFOs), and `flock` — no daemon to configure, no wire protocol,
no database. **The entire broker state is the filesystem**, so you inspect it with `ls` and `cat`.

```bash
# terminal 1 — start a broker (no config)
shellmux serve /tmp/bus --unix /tmp/bus.sock

# terminal 2 — subscribe to a topic
shellmux sub /tmp/bus alerts --unix /tmp/bus.sock

# terminal 3 — publish (terminal 2 prints it instantly)
echo "disk 91% full" | shellmux pub /tmp/bus alerts --unix /tmp/bus.sock

# …or schedule it to fire in 30 seconds, on the second, at ~0% CPU the whole time
echo "reboot now"   | shellmux pub /tmp/bus alerts --delay 30 --unix /tmp/bus.sock
```

## Who is it for?

The class of deployments that need **correct fan-out + correct timing** but where a clustered broker
is the wrong dependency: a homelab event bus, sensors on a boat, CI runners on a LAN, an air-gapped
factory floor, a $5 single-board computer. If your whole stack is shell and you want a delayed/timed
message to fire reliably without standing up a daemon, this is for you.

**It is deliberately not** a competitor to Mosquitto / NATS / Redis / Kafka. No clustering, no
persistence, no millions of messages per second. It does a *small* thing and **proves** it does it
correctly — that proof is the product.

## The proof (why this exists)

Per-subscriber isolation and forget-on-death are free from fork-per-connection — not the achievement.
The one genuinely hard thing in a language with **no threads, no atomics, and only advisory locks**
is **timed delivery that is race-free against concurrent publishes, with no busy-spin.** The classic
bug: a publish lands in the window between "scheduler computed the next deadline" and "scheduler went
to sleep," so the deadline is slept through.

shellmux makes that bug **structurally absent**, and proves it with an adversarial test that injects
a publish into *exactly* that window on **every one of 5000 trials**:

```
$ bash tests/chaos_deadline.sh                       # the M0 gate (run from a clone)
[1/5] CORRECT     missed=0 dup=0 ontime=5000 total_fires=5000   over N=5000   PASS
[2/5] naivesleep  missed=120/120        control fails as required
[3/5] drainfirst  missed=120/120        control fails as required
[4/5] nocommit    dup=1770              control fails as required
[5/5] idle CPU    0.00%                 PASS
```

`missed=0 dup=0`, at **0.00% idle CPU**. It's only a proof because three deliberately-broken
schedulers (each one knob different) are *shown to fail* — and it has been re-confirmed on real ARM64
hardware (AWS Graviton, bare metal) and survived two independent adversarial-verification passes.
The full story is in [`DEMO.md`](./DEMO.md) and [`docs/evidence/`](./docs/evidence/).

## Requirements

**Linux**, with: `bash` ≥ 4 (for sub-second timers), `socat`, `flock` (util-linux), and
`timeout`/`mkfifo` (coreutils). This is the honest dependency set — *not* "POSIX sh anywhere."

> **macOS note:** macOS ships bash 3.2 (no fractional `read -t`) and lacks `flock`/`timeout`. Don't
> run it on bare macOS — use the Docker dev container (see [Contributing](#contributing-and-development)).
> On bash 3 / dash timer resolution falls back to ~1 second (faithful to the algorithm we port, just
> coarser).

Install the deps:

```bash
sudo apt-get install -y bash socat util-linux coreutils   # Debian/Ubuntu
sudo dnf install -y     bash socat util-linux coreutils   # Fedora/RHEL
sudo apk add            bash socat util-linux coreutils   # Alpine
```

## Install

```bash
git clone https://github.com/bobbyrathoree/shellmux.git
cd shellmux
./install.sh                 # installs to ~/.local (bin/ + libexec/); checks deps + smoke-tests
# or system-wide:  sudo ./install.sh --prefix /usr/local
# verify deps only: ./install.sh --check
# remove:           ./install.sh --uninstall
```

Then make sure `~/.local/bin` is on your `PATH` and run `shellmux --help`. No build step — it's shell.

## Usage

```
shellmux serve <dir> [--unix <path>] [--tcp <port>]   start the broker
shellmux sub   <dir> <topic> [--unix <path>|--tcp <port>]
shellmux pub   <dir> <topic> [--at <epoch>|--delay <s>] [--unix <path>|--tcp <port>]
shellmux --version | --help
```

- **Topics are directories** under `<dir>/topics/`. They're created on first use.
- **Subscribers** are forked processes with a private FIFO mailbox; when one dies it's forgotten
  automatically (its FIFO is unlinked, fan-out skips it).
- **Deferred publishes** (`--at`/`--delay`) are staged on disk and fired by the deadline scheduler.
- **Introspect everything with the filesystem** — there is no admin protocol:

```bash
ls   <dir>/topics/                          # live topics
ls   <dir>/topics/alerts/sub_*.fifo | wc -l # live subscriber count
cat  <dir>/topics/alerts/drops_* 2>/dev/null# per-subscriber dropped-record counts
ls   <dir>/deferred/ | sort | head -1       # the next deadline (filename = <run_at_ms>.<seq>)
```

Transport is `--unix <path>` (local) or `--tcp <port>` (LAN). There is **no auth** — a UNIX socket
with filesystem permissions is the access boundary; for TCP over an untrusted network, front it with
`socat OPENSSL` or an SSH tunnel.

## The delivery contract (read before piping data at it)

A record is **one newline-delimited line of NUL-free text**. The broker parses *only* the one-line
control header and never inspects your payload, but delivery is line-oriented:

- Each newline-terminated line you publish becomes **its own record** (a multi-line payload fans out
  as N records, one per line — not one blob, not one truncated line).
- An unterminated trailing line waits for a newline before delivery. Embedded NUL bytes are stripped.
- Frame integrity holds even under concurrent publishers and records larger than the pipe buffer.

It is **best-effort, not lossless.** A subscriber that can't keep up has its overflow dropped and
**counted** (`drops_<pid>`) — visible, never silent. A subscriber offline at publish time misses the
message; there is no replay or persistence. Crash semantics are **at-most-once-modulo-crash**. These
are stated plainly, not hidden — see [`DEMO.md`](./DEMO.md) §"Why it's honest" and
[`docs/prior-art.md`](./docs/prior-art.md).

## How fast / how big?

Throughput is **fork-bound** (one bounded write per record per subscriber). On a 2-vCPU ARM box
that's ~50–60 msg/s/sub; on a 14-core x86 dev box ~1300 msg/s. The subscriber ceiling is **RAM-bound**
(~2.6 MB/sub) — about **150–175 subscribers on a 512 MB box**. Idle CPU is genuinely ~0% (the
scheduler blocks in a real syscall, not a poll loop). Numbers are platform-qualified in
[`docs/evidence/R3-aws-graviton.md`](./docs/evidence/R3-aws-graviton.md) — measured on real hardware,
not hand-waved.

## Contributing and development

Contributions welcome — please read **[`CONTRIBUTING.md`](./CONTRIBUTING.md)** first. The one
non-negotiable rule: **every correctness test ships a must-fail negative control** (a deliberately
broken variant the test is shown to reject). A green test that can't fail a wrong implementation
proves nothing — that discipline is the whole point of this project.

```bash
docker build -t shellmux-dev .
docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/run_all.sh   # all 10 suites
docker run --rm -v "$PWD:/work" -w /work shellmux-dev bash tests/chaos_deadline.sh   # the spine
```

Deep docs: [`docs/spec.md`](./docs/spec.md) (canonical design), [`docs/design.md`](./docs/design.md)
(how it works), [`docs/prior-art.md`](./docs/prior-art.md) (what we borrow and how we differ), and
[`HANDOFF.md`](./HANDOFF.md) (current build state).

## License

MIT — see [`LICENSE`](./LICENSE).
