#!/bin/sh
set -eu

project_root=$(CDPATH= cd "$(dirname "$0")" && pwd)
binary="$project_root/zig-out/bin/zed2api"
pid_path="$project_root/zed2api.pid"

if [ ! -f "$pid_path" ]; then
    echo "zed2api.pid was not found; no process was recorded by start.sh."
    exit 0
fi

pid=$(tr -d '[:space:]' <"$pid_path")
case "$pid" in
    ''|*[!0-9]*)
        echo "Invalid PID file content: $pid" >&2
        exit 1
        ;;
esac

if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_path"
    echo "PID $pid no longer exists; the stale PID file was removed."
    exit 0
fi

command_line=$(ps -p "$pid" -o command=)
case "$command_line" in
    "$binary"|"$binary "*) ;;
    *)
        echo "PID $pid is not this directory's zed2api. Stop cancelled. Actual command: $command_line" >&2
        exit 1
        ;;
esac

kill "$pid"
attempt=0
while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done
if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid"
fi

rm -f "$pid_path"
echo "zed2api stopped: PID=$pid"
