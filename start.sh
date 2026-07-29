#!/bin/sh
set -eu

port=${1:-8001}
case "$port" in
    ''|*[!0-9]*)
        echo "Invalid port: $port" >&2
        exit 1
        ;;
esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Invalid port: $port" >&2
    exit 1
fi

project_root=$(CDPATH= cd "$(dirname "$0")" && pwd)
binary="$project_root/zig-out/bin/zed2api"
pid_path="$project_root/zed2api.pid"
log_dir="$project_root/logs"
stdout_path="$log_dir/zed2api.out.log"
stderr_path="$log_dir/zed2api.err.log"

if [ ! -x "$binary" ]; then
    echo "Release binary not found: $binary" >&2
    echo "Build it first with: zig build -Doptimize=ReleaseSafe" >&2
    exit 1
fi

listener=$(/usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)
if [ -n "$listener" ]; then
    echo "Port $port is already in use by PID $(printf '%s\n' "$listener" | head -n 1)." >&2
    exit 1
fi

if [ ! -f "$project_root/accounts.json" ]; then
    echo "Warning: accounts.json is missing. Run ./zig-out/bin/zed2api login my-account before sending model requests." >&2
fi

mkdir -p "$log_dir"
(
    cd "$project_root"
    nohup "$binary" serve "$port" >"$stdout_path" 2>"$stderr_path" &
    printf '%s\n' "$!" >"$pid_path"
)

pid=$(cat "$pid_path")
ready=false
attempt=0
while [ "$attempt" -lt 40 ]; do
    sleep 0.25
    if ! kill -0 "$pid" 2>/dev/null; then
        break
    fi
    if /usr/bin/curl -fsS --max-time 3 "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then
        ready=true
        break
    fi
    attempt=$((attempt + 1))
done

if [ "$ready" != true ]; then
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_path"
    echo "zed2api readiness check failed. PID=$pid" >&2
    if [ -f "$stderr_path" ]; then
        tail -n 20 "$stderr_path" >&2
    fi
    exit 1
fi

echo "zed2api started: PID=$pid, URL=http://127.0.0.1:$port"
echo "Error log: $stderr_path"
