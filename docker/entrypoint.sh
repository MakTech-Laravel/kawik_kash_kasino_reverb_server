#!/usr/bin/env bash
set -euo pipefail

cd /var/www

# Ensure runtime dirs exist (Coolify / volume mounts may wipe them)
mkdir -p storage/framework/{views,sessions,cache} storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache || true

# Confirm Redis PHP extension is loaded (required for CACHE_STORE/QUEUE_CONNECTION=redis)
if ! php -m | grep -qi '^redis$'; then
    echo "ERROR: PHP redis extension is not loaded." >&2
    exit 1
fi

# Optional: wait for Coolify Redis when REDIS_HOST is set
if [[ -n "${REDIS_HOST:-}" && "${REDIS_HOST}" != "127.0.0.1" ]]; then
    echo "Waiting for Redis at ${REDIS_HOST}:${REDIS_PORT:-6379}..."
    for i in $(seq 1 30); do
        if php -r "try { \$r=new Redis(); \$r->connect(getenv('REDIS_HOST') ?: '127.0.0.1', (int) (getenv('REDIS_PORT') ?: 6379), 1.0); echo 'ok'; exit(0);} catch (Throwable \$e) { exit(1);}" 2>/dev/null; then
            echo "Redis is reachable."
            break
        fi
        if [[ "$i" -eq 30 ]]; then
            echo "WARNING: Redis not reachable after 30s; continuing anyway." >&2
        else
            sleep 1
        fi
    done
fi

# Optional: wait for Meilisearch when using Scout
if [[ "${SCOUT_DRIVER:-}" == "meilisearch" && -n "${MEILISEARCH_HOST:-}" ]]; then
    echo "Waiting for Meilisearch at ${MEILISEARCH_HOST}..."
    for i in $(seq 1 30); do
        if curl -fsS "${MEILISEARCH_HOST%/}/health" >/dev/null 2>&1; then
            echo "Meilisearch is reachable."
            break
        fi
        if [[ "$i" -eq 30 ]]; then
            echo "WARNING: Meilisearch not reachable after 30s; continuing anyway." >&2
        else
            sleep 1
        fi
    done
fi

# Sync Firebase web config into storage for the messaging service worker route
if php artisan firebase:sync-web-config; then
    echo "Firebase web config synced to storage."
else
    echo "WARNING: firebase:sync-web-config failed; continuing anyway." >&2
fi

exec "$@"
