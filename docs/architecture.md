# Architecture

One repository holds the whole Minerva stack so that the wire contract, the server
library and every engine adapter change together.

```
proto/            buf module buf.build/voron-simulations/minerva  (the wire contract)
   │  buf generate (server/buf.gen.yaml, local input)
   ▼
server/           minerva-server: generated bindings, StateCache, Dispatcher, tonic services
   │  path dependency
   ▼
arma3/            minerva-arma3: cdylib `minerva` + HEMTT addon (one adapter per engine)
```

- **`proto/`** is the source of truth for the gRPC API (package `minerva.v1`).
  [`contract.md`](contract.md) records what clients and servers may rely on beyond what the
  schema says. CI pushes the module to the [Buf Schema
  Registry](https://buf.build/voron-simulations/minerva) on every push to `main`, which is
  how clients outside this repo (any language) consume it.
- **`server/`** is engine-agnostic. It holds the committed generated code (`src/gen`),
  the `StateCache` an adapter feeds, the `CommandSink` trait an adapter implements, and the
  `Dispatcher` that tracks in-flight commands until the engine acknowledges them.
  Because the bindings are generated from `../proto`, a proto change and the regenerated
  code land in the same commit; CI fails if they drift.
- **`arma3/`** is the Arma 3 adapter: a Rust extension loaded by the game plus the SQF
  addon that calls it. Behavior specific to it is in [`adapter.md`](adapter.md).

Dependencies only point down this chain: adapters depend on `minerva-server` (by path, via
the root `[workspace.dependencies]`), the server never depends on an adapter, and nothing
depends on the extension's C ABI.

## Adding an engine adapter (e.g. DCS or CMO)

1. Create a crate directory at the repo root (say `dcs/`) and add it to `members` in the
   root `Cargo.toml`. Inherit `edition`, `license` and `repository` from
   `[workspace.package]` and take `minerva-server` with `{ workspace = true }`; put any new
   shared dependency in `[workspace.dependencies]` rather than pinning it in the crate.
2. Implement `CommandSink` to turn a dispatched `Command` into an engine action, push
   simulation state into the `StateCache`, and report the engine's acknowledgement with
   `Dispatcher::complete`. Start the server with `ServerHandle::spawn` when the engine
   hosts the plugin in a foreign process, or `serve` when a Tokio runtime already exists.
3. Document what the adapter reports for fields the contract leaves open in its own file
   under `docs/`, and add a short `AGENTS.md` in the crate directory.
4. The `ci.yml` Rust jobs already run with `--workspace`, so formatting, clippy, tests,
   coverage and bench compilation cover the new crate. Add engine-specific packaging as its
   own reusable workflow next to `build.yml` and call it from `ci.yml` and, if it ships
   nightly builds, from a new workflow modelled on `nightly.yml`.
5. If the engine needs a protocol change, make it in `proto/` in the same pull request and
   regenerate `server/src/gen` (see [`../server/AGENTS.md`](../server/AGENTS.md)).
