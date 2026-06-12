#!/usr/bin/env bash
# Verify the Hex package tarball contains only the intended files.
# Guards against repo-only directories (benches/, test/, openspec/, guides/,
# notebooks/, scripts/) ever leaking into the published package.
set -euo pipefail

cd "$(dirname "$0")/.."

mix hex.build --quiet >/dev/null 2>&1 || mix hex.build >/dev/null

tarball=$(ls -t property_damage-*.tar | head -1)

violations=$(tar -xOf "$tarball" contents.tar.gz | tar -tz \
  | grep -vE '^(lib/|mix\.exs$|README\.md$|LICENSE$|CHANGELOG\.md$|\.formatter\.exs$)' || true)

if [ -n "$violations" ]; then
  echo "FAIL: unexpected files in Hex package $tarball:" >&2
  echo "$violations" >&2
  exit 1
fi

echo "OK: $tarball contains only lib/, mix.exs, README.md, LICENSE, CHANGELOG.md, .formatter.exs"
