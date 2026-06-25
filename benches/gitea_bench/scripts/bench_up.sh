#!/usr/bin/env sh
# Bring up the two ephemeral Gitea instances and ensure each has a known admin.
#
# Idempotent: `docker compose up -d --wait` is a no-op when the stack is already
# healthy, and `gitea admin user create` is tolerated to fail (the admin already
# exists on a reused container). Skipped entirely when the bench is pointed at
# external instances via PD_GITEA_API_URL / PD_GITEA_UI_URL.
set -eu

if [ -n "${PD_GITEA_API_URL:-}" ] && [ -n "${PD_GITEA_UI_URL:-}" ]; then
  echo "PD_GITEA_API_URL / PD_GITEA_UI_URL set; skipping Docker."
  exit 0
fi

ADMIN_USER="${PD_GITEA_ADMIN_USER:-pdadmin}"
ADMIN_PASSWORD="${PD_GITEA_ADMIN_PASSWORD:-Pd-Admin-12345}"

docker compose up -d --wait

for svc in gitea-api gitea-ui; do
  # The first user a fresh Gitea has is created here; on a reused container this
  # is a no-op (user exists), so we swallow the error.
  docker compose exec -T -u git "$svc" gitea admin user create \
    --admin \
    --username "$ADMIN_USER" \
    --password "$ADMIN_PASSWORD" \
    --email "admin@pd.local" \
    --must-change-password=false >/dev/null 2>&1 || true
done

echo "Gitea instances ready (admin: $ADMIN_USER)."
