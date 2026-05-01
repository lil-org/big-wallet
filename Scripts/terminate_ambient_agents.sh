#!/bin/sh

if [ "$CONFIGURATION" != "Debug" ]; then
    exit 0
fi

pids=$(/usr/bin/pgrep -x "Big Wallet Ambient" || true)

if [ -z "$pids" ]; then
    exit 0
fi

echo "Terminating Big Wallet Ambient processes: $pids."
/bin/kill -TERM $pids 2>/dev/null || true
sleep 0.5
/bin/kill -KILL $pids 2>/dev/null || true
