# shellmux dev container
# ---------------------------------------------------------------------------
# WHAT THIS PROVIDES
#   The exact Linux toolchain shellmux's correctness depends on, pinned for
#   reproducibility. The host is darwin/arm64 — macOS ships bash 3.2 (no
#   fractional `read -t`, ~1s timer resolution) and BSD userland (no `flock`,
#   no GNU `timeout`). Develop, run the chaos test, and benchmark IN HERE, not
#   on bare macOS, so FIFO semantics, `flock`, and fractional `read -t` behave
#   consistently.
#
#   Provides:
#     - bash >= 4  (Debian bookworm ships bash 5.2) -> fractional `read -t`,
#       enabling sub-100ms wake latency. The ~1s floor on bash3/dash remains
#       faithful (the reference scheduler uses a whole-second timer).
#     - coreutils  -> mkfifo, timeout, dd  (the bounded-write fallback path)
#     - util-linux -> flock                (the shared-counter lock)
#     - socat                              (fork-per-connection acceptor, TCP + UNIX)
#     - procps + lsof                      (the flood test's flat-process/fd assertions)
#
# CAPABILITIES / PRIVILEGE
#   None required. shellmux uses only plain named pipes (mkfifo), advisory
#   file locks (flock), and userland socat listeners. No --privileged, no
#   --cap-add, no host networking. Run it as a normal container:
#
#     docker build -t shellmux-dev .
#     docker run --rm -it -v "$PWD:/work" -w /work shellmux-dev bash
#     # inside:  bash tests/chaos_deadline.sh
#
#   If you bind a TCP listener and want to reach it from the host, publish the
#   port explicitly (e.g. -p 9999:9999); the UNIX-socket path needs nothing.
#
# WHY DEBIAN, WHY PINNED
#   Debian bookworm gives a stable bash 5.2 + util-linux flock without the
#   musl/busybox surprises an Alpine image would introduce (busybox flock and
#   read -t differ). The digest pin keeps the bash/socat versions reproducible;
#   bump it deliberately, not by accident.
# ---------------------------------------------------------------------------

# Debian 12 (bookworm) slim. Pin by digest so the toolchain versions are stable.
# To refresh: `docker pull debian:bookworm-slim` then copy the new digest here.
FROM debian:bookworm-slim@sha256:2424c1850714a4d94666ec928e24d86de958646737b1d113f5b2207be44d37d8

# Faithful, non-interactive apt.
ENV DEBIAN_FRONTEND=noninteractive

# Toolchain. Versions reflect Debian bookworm's stable set at time of writing;
# they are what the chaos/flood/crash tests are validated against.
#   bash 5.2.x | socat 1.7.4.x | util-linux (flock) 2.38.x | coreutils 9.1.x
RUN apt-get update && apt-get install --no-install-recommends -y \
        bash \
        coreutils \
        util-linux \
        socat \
        procps \
        lsof \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Make bash the shell for RUN and the default entrypoint shell. shellmux is a
# bash>=4 project; never let /bin/sh (dash) be assumed.
SHELL ["/bin/bash", "-c"]

WORKDIR /work

# Sanity self-check at build time: fail the build early if any required tool or
# the bash>=4 fractional-timer capability is missing. (Does NOT run the project.)
RUN set -euo pipefail; \
    for t in bash socat flock timeout mkfifo dd ps lsof; do \
        command -v "$t" >/dev/null || { echo "MISSING: $t" >&2; exit 1; }; \
    done; \
    bv="${BASH_VERSINFO[0]}"; \
    [[ "$bv" -ge 4 ]] || { echo "bash >= 4 required, got $bv" >&2; exit 1; }; \
    echo "shellmux toolchain OK: bash $BASH_VERSION, $(socat -V 2>&1 | head -1)"

CMD ["bash"]
