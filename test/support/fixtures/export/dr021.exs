#!/usr/bin/env elixir
# Failure Reproduction Script
# Generated: 2025-01-01T00:00:00Z
# Failure: check_failed
# Seed: 1
#
# Run with: elixir reproduce_1_HASH.exs

Mix.install([{:req, "~> 0.5"}, {:jason, "~> 1.4"}])

base_url = System.get_env("BASE_URL", "http://localhost:4000")
refs = %{}


IO.puts("")
IO.puts("=== Step 1: Provision ===")
# Command: %Provision{spec: :}
resp1 = Req.post!(base_url <> "/api/provision")
IO.inspect(resp1.body, label: "Response")
refs = Map.put(refs, "provisioned_id_0", get_in(resp1.body, ["id"]))
IO.puts("  -> bound provisioned_id_0: #{inspect(refs["provisioned_id_0"])}")


IO.puts("")
IO.puts("=== Step 2: Consume (FAILURE POINT) ===")
# Command: %Consume{target: external(Provisioned.id)}
resp2 = Req.get!(base_url <> "/api/things/#{refs["provisioned_id_0"]}")
IO.inspect(resp2.body, label: "Response")


IO.puts("")
IO.puts("=== Reproduction Complete ===")
IO.puts("Seed: 1")
