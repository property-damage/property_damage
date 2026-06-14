# openapi_bench

Phase 6e of the PropertyDamage bench ladder: validate the **generated-adapter
path** end to end. `mix pd.scaffold --from <openapi spec>` is supposed to emit
commands, events, an HTTP adapter, and a model that compile and actually drive a
real REST API. This bench proves that output is real code, not codegen drift,
the core risk thesis for the whole project.

Unlike the other benches the SUT is **in-process**: a tiny Bandit/Plug HTTP API
(`OpenapiBench.Api`, an integer-keyed value register) started in the bench VM.
The thing under validation is the scaffold codegen, not the HTTP transport, so a
real socket on loopback is the honest, low-ceremony choice (no Docker). Set
`PD_OPENAPI_URL` to point the bench at an external server instead (CI service
container / BYO); then it starts nothing locally.

## The SUT

```
PUT  /kv/{key}   {"value": int}  -> 200 {"key": int, "value": int}
GET  /kv/{key}                   -> 200 {"key": int, "value": int} | 404
POST /__reset__  {"bug": bool}   -> 200 {"ok": true}   (harness only, not in the spec)
```

`spec/openapi.json` is the OpenAPI 3.0 document fed to `mix pd.scaffold`. Keys
are constrained to `0..4` so generated `PUT`/`GET` sequences collide and the
read-consistency invariant is actually exercised.

The `bug` flag (`OpenapiBench.Store`) seeds a real SUT bug for non-vacuity: with
it set, `PUT` answers `200` with the requested value but silently drops the
write, so a later `GET` is `404`, a read-consistency violation the generated
suite must catch and shrink.

## Running

```bash
mix test          # starts the in-process server, then runs
PD_OPENAPI_URL=http://host:port mix test   # point at an external SUT instead
```
