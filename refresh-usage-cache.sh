#!/bin/bash
# Refresh ~/.claude/usage-cache.json if stale (> 10 min)
# Called by Claude Code Stop hook; uses OAuth token + minimal haiku call

CACHE="$HOME/.claude/usage-cache.json"

# Skip if cache is fresh (< 600 seconds old)
if [ -f "$CACHE" ]; then
    FETCHED_AT=$(python3 -c "import json; print(json.load(open('$CACHE')).get('fetchedAt', 0))" 2>/dev/null || echo 0)
    NOW_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
    AGE_MS=$(( NOW_MS - FETCHED_AT ))
    if [ "$AGE_MS" -lt 600000 ]; then
        exit 0
    fi
fi

# Get OAuth token from Keychain
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['claudeAiOauth']['accessToken'])" 2>/dev/null)
[ -z "$TOKEN" ] && exit 0

# Minimal API call — capture response headers
TMPFILE=$(mktemp)
curl -s -D "$TMPFILE" -o /dev/null \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
    2>/dev/null

# Parse headers and write cache
python3 - <<EOF
import re, json, time, os, sys

headers = open('$TMPFILE').read()
os.unlink('$TMPFILE')

def get_header(name):
    m = re.search(rf'{re.escape(name)}:\\s*(.+)', headers, re.IGNORECASE)
    return m.group(1).strip() if m else None

five_util  = get_header('anthropic-ratelimit-unified-5h-utilization')
five_reset = get_header('anthropic-ratelimit-unified-5h-reset')
seven_util  = get_header('anthropic-ratelimit-unified-7d-utilization')
seven_reset = get_header('anthropic-ratelimit-unified-7d-reset')

if not five_util or not five_reset:
    sys.exit(0)

cache = {
    'fetchedAt': int(time.time() * 1000),
    'rate_limits': {
        'five_hour': {
            'used_percentage': round(float(five_util) * 100),
            'resets_at': int(five_reset)
        },
        'seven_day': {
            'used_percentage': round(float(seven_util) * 100),
            'resets_at': int(seven_reset)
        }
    }
}

with open(os.path.expanduser('~/.claude/usage-cache.json'), 'w') as f:
    json.dump(cache, f)
EOF
