#!/bin/bash
#
# Start the headgate web server on 127.0.0.1:10000 and open the chat UI. If
# Tailscale is up, ALSO expose it on your tailnet over HTTPS via `tailscale
# serve` (other tailnet devices reach https://<this-host>.<tailnet>.ts.net,
# reverse-proxied to the local server). Falls back to localhost-only when
# Tailscale isn't installed/up, or when `serve` fails or is slow to respond.
#
# The server itself only ever binds 127.0.0.1 — `tailscale serve` is a reverse
# proxy, so no port is opened on the LAN or the internet. The serve attempt runs
# time-bounded in the background, so it can never block the local server.
#
# Run from the headgate install dir with the toolchain env set (CONDA_PREFIX,
# MODULAR_HOME, PATH). Used by `pixi run serve-web` and `millrace headgate web`.
set -u
PORT=10000

if [ ! -x ./build/headgate-server ]; then
    echo "headgate web server not built — run: millrace headgate install" >&2
    exit 1
fi

# Locate the Tailscale CLI (on PATH, or the macOS app bundle).
TS=""
if command -v tailscale >/dev/null 2>&1; then
    TS="$(command -v tailscale)"
elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

# Run a command with a timeout (macOS has no `timeout`); returns 124 if it hangs.
_with_timeout() {
    local secs="$1"; shift
    "$@" & local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) & local watch=$!
    wait "$pid" 2>/dev/null; local rc=$?
    kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null
    return $rc
}

TS_ATTEMPTED=0
PRIOR_EMPTY=0
if [ -n "$TS" ] && "$TS" status >/dev/null 2>&1; then
    # Remember whether there was a prior serve config, so cleanup only undoes ours.
    if "$TS" serve status 2>/dev/null | grep -qi "no serve config"; then
        PRIOR_EMPTY=1
    fi
    TS_ATTEMPTED=1
    # Best-effort, in the background + time-bounded so it can NEVER block the
    # server. `tailscale serve` may need a one-time GUI approval the first run.
    (
        if _with_timeout 10 "$TS" serve --bg --yes "$PORT" >/dev/null 2>&1; then
            echo "tailnet:  exposed via 'tailscale serve' (HTTPS):" >&2
            "$TS" serve status 2>/dev/null | sed 's/^/  /' >&2
        else
            echo "tailscale: 'serve' unavailable (needs approval, or HTTPS certs" >&2
            echo "           disabled in the admin console) — serving localhost only." >&2
        fi
    ) &
fi

# Undo only what we added, and only if there was no prior serve config.
cleanup() {
    if [ "$TS_ATTEMPTED" = 1 ] && [ "$PRIOR_EMPTY" = 1 ]; then
        "$TS" serve reset >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

echo "local:    http://127.0.0.1:$PORT"
( sleep 1.5 && open "http://127.0.0.1:$PORT" ) >/dev/null 2>&1 &

# Run the server in the foreground; Ctrl-C stops it (and triggers cleanup).
./build/headgate-server &
SRV=$!
wait "$SRV"
