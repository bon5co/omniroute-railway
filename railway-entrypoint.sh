#!/bin/sh
# Railway entrypoint for OmniRoute.
#
# Runs as root only long enough to repair the volume and size the heap, then
# drops to the image's own `node` user (uid 1000) and execs the stock server.
set -e

DATA_DIR="${DATA_DIR:-/app/data}"
export DATA_DIR

# --- 1. Make DATA_DIR writable by the app -----------------------------------
#
# OmniRoute keeps ALL of its state under DATA_DIR: storage.sqlite (providers,
# endpoints, API keys, routing rules) and server.env, which holds the
# auto-generated JWT_SECRET and STORAGE_ENCRYPTION_KEY that the stored provider
# credentials are encrypted with. The image's own Dockerfile says DATA_DIR
# "must match the volume mount", so a Railway volume has to land on /app/data
# and not anywhere else.
#
# Railway mounts that volume owned by uid 0 while the app runs as uid 1000, and
# the failure mode is silent rather than loud: the container reports HEALTHY,
# `[DB] SQLite database ready` is logged, and every write fails underneath --
#
#   [bootstrap] Could not persist secrets to /app/data/server.env: EACCES
#   [sqljsAdapter] save failed: Error: EACCES ... open '/app/data/storage.sqlite'
#
# so the gateway serves traffic and stores nothing. Repairing ownership before
# the privilege drop is what makes the mount actually usable.
if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR/lost+found" 2>/dev/null || true
    chown -R 1000:1000 "$DATA_DIR"
fi

# --- 2. Size the V8 heap from the container, not from the image -------------
#
# The image hardcodes a 1024 MB ceiling. Upstream's own Dockerfile comment says
# to raise it "for large fusion-combo panels (many models fanned out in
# parallel, each response buffered in full)". On Railway the container size is
# a deploy-time choice, so read the cgroup instead and take 70% of it, leaving
# the rest for the Node process's non-heap RSS. `max` (no limit) falls back to
# upstream's value.
if [ -z "$OMNIROUTE_MEMORY_MB" ]; then
    limit=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        limit="$(cat /sys/fs/cgroup/memory.max)"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        limit="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    fi
    case "$limit" in
        ''|max|*[!0-9]*) OMNIROUTE_MEMORY_MB=1024 ;;
        *)
            mb=$(( limit / 1024 / 1024 * 70 / 100 ))
            # Guard both ends: a cgroup reporting the host's whole RAM would
            # otherwise hand V8 a ceiling it can never reach.
            [ "$mb" -lt 512 ] && mb=512
            [ "$mb" -gt 8192 ] && mb=8192
            OMNIROUTE_MEMORY_MB="$mb"
            ;;
    esac
fi
export OMNIROUTE_MEMORY_MB
NODE_OPTIONS="--max-old-space-size=${OMNIROUTE_MEMORY_MB}"
export NODE_OPTIONS

# Upstream's guard for the reverse-proxy subpath build. Only does anything when
# OMNIROUTE_BASE_PATH is set; kept so this entrypoint is a superset of the stock
# one it replaces (a Docker ENTRYPOINT is replaced, never appended to).
if [ -f docker/ensure-docker-base-path.mjs ]; then
    node docker/ensure-docker-base-path.mjs || exit 1
fi

echo "railway-entrypoint: DATA_DIR=$DATA_DIR owner=$(stat -c %u:%g "$DATA_DIR" 2>/dev/null || echo none) heap=${OMNIROUTE_MEMORY_MB}MB port=${PORT:-unset}"

exec setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all "$@"
