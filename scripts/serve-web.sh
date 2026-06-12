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

# The headgate web server is VAULT-ONLY: /chat answers questions about the vault
# dir (HEADGATE_VAULT_DIR, else $DACULAR_VAULT / $HEADGATE_DATA / ~/dacular). The
# dacular vault tools that the generated program calls (search/ask_local) reach
# the local inference server over loopback at DACULAR_EMBED_URL (embeddings) and
# DACULAR_LOCAL_URL (chat) — both default to the combined server on :8000/v1.
# Export them so the headgate-server process env propagates to the sandboxed
# generated program (which inherits the parent's environment) over loopback.
# (The server is unconditionally vault-only — no HEADGATE_VAULT gate.)
export HEADGATE_VAULT_DIR="${HEADGATE_VAULT_DIR:-}"
export DACULAR_VAULT="${DACULAR_VAULT:-$HEADGATE_VAULT_DIR}"
export DACULAR_EMBED_URL="${DACULAR_EMBED_URL:-http://127.0.0.1:8000/v1}"
export DACULAR_LOCAL_URL="${DACULAR_LOCAL_URL:-http://127.0.0.1:8000/v1}"
echo "mode:     VAULT (dir: ${HEADGATE_VAULT_DIR:-<resolved>})" >&2

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
    # server. Expose over HTTP on the tailnet — carried over the encrypted
    # WireGuard tunnel, tailnet-only (never LAN/public). HTTP (not HTTPS) so it
    # works without enabling the Serve/HTTPS-certificates feature in the admin
    # console (which otherwise blocks waiting for a one-time enable).
    (
        if _with_timeout 8 "$TS" serve --bg --yes --http="$PORT" "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
            echo "tailnet:  exposed via 'tailscale serve' (over the encrypted tailnet):" >&2
            "$TS" serve status 2>/dev/null | sed 's/^/  /' >&2
        else
            echo "tailscale: 'serve' unavailable (may need a one-time approval) —" >&2
            echo "           serving localhost only." >&2
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
