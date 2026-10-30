# 1. One repository for protocol, server and adapters

Date: 2026-10-30

## Status

Accepted

## Context

Minerva lived in three repositories: `minerva-protocol` (protobuf contract, published to
the Buf Schema Registry), `minerva-server` (Rust library generated from the BSR module) and
`minerva-arma3` (the Arma 3 adapter, depending on a pinned `minerva-server` git revision).
A protocol change therefore needed three pull requests in order: protocol, then a server
regeneration, then an adapter bump of the pinned revision. Local development against
unreleased changes needed a BSR-less `buf generate` path and a `[patch]` override in
`.cargo/config.toml`. CI, Renovate and lint configuration were triplicated, and planned
adapters for other engines (DCS, CMO) would have added more repositories to that chain.

## Decision

Merge the three repositories into one, `voron-simulations/minerva`, with history preserved:

- `proto/` is the buf module root; the module name stays `buf.build/voron-simulations/minerva`.
  The BSR module is now pushed from this repository.
- `server/` and `arma3/` are members of one Cargo workspace with one `Cargo.lock`.
  `minerva-arma3` depends on `minerva-server` by path.
- `server/buf.gen.yaml` generates from `../proto`, not from the BSR, so the committed
  bindings always correspond to the protos in the same commit.
- One CI workflow covers all parts; the addon build and the nightly release are separate
  workflows.

## Consequences

- A protocol, server and adapter change ships as a single reviewed commit, and CI proves
  they build and pass tests together.
- The breaking-change check (`buf breaking`) still guards the published contract, but a
  breaking change no longer needs coordinated bumps across repositories.
- Every pull request runs the CI for all parts. The cost is accepted for now; per-path job
  filtering can be added if CI time becomes a problem.
- Adapters share the server's release cadence. The crates are not published independently;
  that decision is deferred until an external consumer needs it.
- External consumers of the BSR module are unaffected. The old repositories become
  read-only archives pointing here.
