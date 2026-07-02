#!/bin/bash
# Failure Reproduction Script
# Generated: 2025-12-26T14:30:00Z
# Failure: NonNegativeBalance check failed
# Seed: 512902757
#
# Prerequisites: curl, jq
# Run with: bash reproduce_512902757_HASH.sh

set -e  # Exit on error

BASE_URL="${BASE_URL:-http://localhost:4000}"


echo ""
echo "=== Step 1: CreateAccount ==="
# Command: %CreateAccount{currency: :USD}
RESP1=$(curl -s \
  -X POST \
  "$BASE_URL/api/accounts" \
  -H "Content-Type: application/json" \
  -d '{"currency":"USD"}')
echo "$RESP1"


echo ""
echo "=== Step 2: CreditAccount ==="
# Command: %CreditAccount{account_ref: "acc_0", amount: 100}
RESP2=$(curl -s \
  -X POST \
  "$BASE_URL/api/accounts/acc_0/credit" \
  -H "Content-Type: application/json" \
  -d '{"amount":100}')
echo "$RESP2"


echo ""
echo "=== Step 3: DebitAccount (FAILURE POINT) ==="
# Command: %DebitAccount{account_ref: "acc_0", amount: 200}
RESP3=$(curl -s \
  -X POST \
  "$BASE_URL/api/accounts/acc_0/debit" \
  -H "Content-Type: application/json" \
  -d '{"amount":200}')
echo "$RESP3"


echo ""
echo "=== Reproduction Complete ==="
echo "Seed: 512902757"
