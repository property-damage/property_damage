#!/usr/bin/env python3
"""
Failure Reproduction Script
Generated: 2025-01-01T00:00:00Z
Failure: check_failed
Seed: 1

Prerequisites: pip install requests
Run with: python reproduce_1_HASH.py
"""
import os
import json
import requests

base_url = os.environ.get("BASE_URL", "http://localhost:4000")
refs = {}


print()
print(f"=== Step 1: Provision ===")
# Command: %Provision{spec: :}
resp1 = requests.post(f"{base_url}" + "/api/provision")
print(f"Response: {resp1.json()}")
refs["provisioned_id_0"] = resp1.json()["id"]
print(f"  -> bound provisioned_id_0: {refs['provisioned_id_0']}")


print()
print(f"=== Step 2: Consume (FAILURE POINT) ===")
# Command: %Consume{target: external(Provisioned.id)}
resp2 = requests.get(f"{base_url}" + f"/api/things/{refs['provisioned_id_0']}")
print(f"Response: {resp2.json()}")


print()
print("=== Reproduction Complete ===")
print(f"Seed: 1")
