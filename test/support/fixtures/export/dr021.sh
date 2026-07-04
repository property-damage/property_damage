#!/bin/bash
# Failure Reproduction Script
# Generated: 2025-01-01T00:00:00Z
# Failure: assertion_failed
# Seed: 1
#
# Prerequisites: curl, jq
# Run with: bash reproduce_1_HASH.sh

set -e  # Exit on error

BASE_URL="${BASE_URL:-http://localhost:4000}"


echo ""
echo "=== Step 1: Provision ==="
# Command: %Provision{spec: :}
RESP1=$(curl -s \
  -X POST \
  "$BASE_URL/api/provision" \
  -H "Content-Type: application/json")
echo "$RESP1"
provisioned_id_0=$(echo "$RESP1" | jq -r '.id // empty')
if [ -n "$provisioned_id_0" ]; then
  echo "  -> bound provisioned_id_0: $provisioned_id_0"
fi



echo ""
echo "=== Step 2: Consume (FAILURE POINT) ==="
# Command: %Consume{target: external(Provisioned.id)}
RESP2=$(curl -s \
  -X GET \
  "$BASE_URL/api/things/$provisioned_id_0" \
  -H "Content-Type: application/json")
echo "$RESP2"


echo ""
echo "=== Reproduction Complete ==="
echo "Seed: 1"
