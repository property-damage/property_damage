#!/usr/bin/env elixir
# Failure Reproduction Script
# Generated: 2025-12-26T14:30:00Z
# Failure: NonNegativeBalance check failed
# Seed: 512902757
#
# Run with: elixir reproduce_512902757_HASH.exs

Mix.install([{:req, "~> 0.5"}, {:jason, "~> 1.4"}])

base_url = System.get_env("BASE_URL", "http://localhost:4000")
refs = %{}


IO.puts("")
IO.puts("=== Step 1: CreateAccount ===")
# Command: %CreateAccount{currency: :USD}
resp1 = Req.post!(base_url <> "/api/accounts", json: %{currency: :USD})
IO.inspect(resp1.body, label: "Response")


IO.puts("")
IO.puts("=== Step 2: CreditAccount ===")
# Command: %CreditAccount{account_ref: "acc_0", amount: 100}
resp2 = Req.post!(base_url <> "/api/accounts/#{"acc_0"}/credit", json: %{amount: 100})
IO.inspect(resp2.body, label: "Response")


IO.puts("")
IO.puts("=== Step 3: DebitAccount (FAILURE POINT) ===")
# Command: %DebitAccount{account_ref: "acc_0", amount: 200}
resp3 = Req.post!(base_url <> "/api/accounts/#{"acc_0"}/debit", json: %{amount: 200})
IO.inspect(resp3.body, label: "Response")


IO.puts("")
IO.puts("=== Reproduction Complete ===")
IO.puts("Seed: 512902757")
