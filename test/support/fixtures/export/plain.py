#!/usr/bin/env python3
"""
Failure Reproduction Script
Generated: 2025-12-26T14:30:00Z
Failure: NonNegativeBalance check failed
Seed: 512902757

Prerequisites: pip install requests
Run with: python reproduce_512902757_HASH.py
"""
import os
import json
import requests

base_url = os.environ.get("BASE_URL", "http://localhost:4000")
refs = {}


print()
print(f"=== Step 1: CreateAccount ===")
# Command: %CreateAccount{currency: :USD}
resp1 = requests.post(f"{base_url}" + "/api/accounts", json={"currency": "USD"})
print(f"Response: {resp1.json()}")


print()
print(f"=== Step 2: CreditAccount ===")
# Command: %CreditAccount{account_ref: "acc_0", amount: 100}
resp2 = requests.post(f"{base_url}" + f"/api/accounts/{"acc_0"}/credit", json={"amount": 100})
print(f"Response: {resp2.json()}")


print()
print(f"=== Step 3: DebitAccount (FAILURE POINT) ===")
# Command: %DebitAccount{account_ref: "acc_0", amount: 200}
resp3 = requests.post(f"{base_url}" + f"/api/accounts/{"acc_0"}/debit", json={"amount": 200})
print(f"Response: {resp3.json()}")


print()
print("=== Reproduction Complete ===")
print(f"Seed: 512902757")
