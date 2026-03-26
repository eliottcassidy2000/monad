#!/usr/bin/env bash
# cluster-memory.sh — Shared key-value state across all agents and sessions
#
# A lightweight "blackboard" that any agent can read/write. Backed by a JSON file
# in the repo, so it's version-controlled and available everywhere via git pull.
#
# Usage:
#   cluster-memory.sh get <key>                    # read a value
#   cluster-memory.sh set <key> <value> [ttl_days]  # write a value (optional TTL)
#   cluster-memory.sh delete <key>                  # remove a key
#   cluster-memory.sh list [prefix]                 # list keys (optional prefix filter)
#   cluster-memory.sh gc                            # garbage-collect expired entries
#   cluster-memory.sh dump                          # print full state as JSON
#
# Design principles:
#   - Git-backed: changes are committed and pushed so all nodes see them
#   - TTL-aware: entries can expire (cleaned by gc)
#   - Namespaced: use dot-separated keys (research.momentum, compute.priorities)
#   - Lightweight: a single JSON file, no dependencies beyond python3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MEMORY_FILE="$REPO_DIR/cluster-memory.json"

# Initialize if missing
if [ ! -f "$MEMORY_FILE" ]; then
    echo '{}' > "$MEMORY_FILE"
fi

cmd_get() {
    local key="$1"
    python3 -c "
import json, sys, time
with open('$MEMORY_FILE') as f:
    data = json.load(f)
entry = data.get('$key')
if entry is None:
    sys.exit(1)
# Check TTL
if 'expires' in entry and entry['expires'] < time.time():
    sys.exit(1)  # expired
print(entry.get('value', ''))
" 2>/dev/null
}

cmd_set() {
    local key="$1"
    local value="$2"
    local ttl_days="${3:-0}"

    python3 -c "
import json, time
key = '$key'
value = '''$value'''
ttl_days = int('$ttl_days')

with open('$MEMORY_FILE') as f:
    data = json.load(f)

entry = {
    'value': value,
    'updated': time.time(),
    'updated_by': '$(hostname)',
}
if ttl_days > 0:
    entry['expires'] = time.time() + (ttl_days * 86400)

data[key] = entry

with open('$MEMORY_FILE', 'w') as f:
    json.dump(data, f, indent=2, sort_keys=True)

print(f'Set {key}')
" 2>/dev/null
}

cmd_delete() {
    local key="$1"
    python3 -c "
import json
with open('$MEMORY_FILE') as f:
    data = json.load(f)
if '$key' in data:
    del data['$key']
    with open('$MEMORY_FILE', 'w') as f:
        json.dump(data, f, indent=2, sort_keys=True)
    print('Deleted $key')
else:
    print('Key not found: $key')
" 2>/dev/null
}

cmd_list() {
    local prefix="${1:-}"
    python3 -c "
import json, time
with open('$MEMORY_FILE') as f:
    data = json.load(f)
now = time.time()
for key in sorted(data.keys()):
    if '$prefix' and not key.startswith('$prefix'):
        continue
    entry = data[key]
    expires = entry.get('expires', 0)
    if expires > 0 and expires < now:
        status = '(expired)'
    elif expires > 0:
        days_left = (expires - now) / 86400
        status = f'(expires in {days_left:.1f}d)'
    else:
        status = ''
    value = str(entry.get('value', ''))[:60]
    updated_by = entry.get('updated_by', '?')
    print(f'  {key}: {value} {status} [{updated_by}]')
" 2>/dev/null
}

cmd_gc() {
    python3 -c "
import json, time
with open('$MEMORY_FILE') as f:
    data = json.load(f)
now = time.time()
expired = [k for k, v in data.items() if v.get('expires', 0) > 0 and v['expires'] < now]
for k in expired:
    del data[k]
with open('$MEMORY_FILE', 'w') as f:
    json.dump(data, f, indent=2, sort_keys=True)
print(f'Garbage collected {len(expired)} expired entries')
" 2>/dev/null
}

cmd_dump() {
    python3 -m json.tool "$MEMORY_FILE" 2>/dev/null || cat "$MEMORY_FILE"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    get)    cmd_get "${2:?key required}" ;;
    set)    cmd_set "${2:?key required}" "${3:?value required}" "${4:-0}" ;;
    delete) cmd_delete "${2:?key required}" ;;
    list)   cmd_list "${2:-}" ;;
    gc)     cmd_gc ;;
    dump)   cmd_dump ;;
    *)
        echo "Usage: cluster-memory.sh <get|set|delete|list|gc|dump> [args...]"
        echo ""
        echo "Namespacing conventions:"
        echo "  research.*     — math research state (priorities, momentum)"
        echo "  compute.*      — computation queue and results metadata"
        echo "  cluster.*      — cluster-wide state (capabilities, preferences)"
        echo "  node.<name>.*  — per-node state"
        exit 1
        ;;
esac
