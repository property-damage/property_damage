#!/usr/bin/env sh
# Bring up the dedicated, ephemeral Ory Kratos instance and wait until its admin
# API is ready.
#
# Idempotent: `docker compose up -d --wait` is a no-op when the stack is already
# healthy. Skipped entirely when the bench is pointed at an external Kratos via
# PD_KRATOS_PUBLIC_URL / PD_KRATOS_ADMIN_URL.
set -eu

if [ -n "${PD_KRATOS_PUBLIC_URL:-}" ] && [ -n "${PD_KRATOS_ADMIN_URL:-}" ]; then
  echo "PD_KRATOS_PUBLIC_URL / PD_KRATOS_ADMIN_URL set; skipping Docker."
  exit 0
fi

docker compose up -d --wait

echo "Ory Kratos ready."
