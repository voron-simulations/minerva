# AGENTS.md

Minerva: a gRPC contract for reading simulation state and commanding units, a reusable Rust
server for it, and per-engine adapters. Why one repo: `adr/0001-monorepo.md`. How the parts
fit and how to add an engine: `docs/architecture.md`.

## Layout

- `proto/` — buf module `buf.build/voron-simulations/minerva` (the wire contract). See `proto/AGENTS.md`.
- `server/` — Rust crate `minerva-server`, engine-agnostic, with committed generated bindings. See `server/AGENTS.md`.
- `arma3/` — Rust crate `minerva-arma3` (cdylib `minerva`) plus the HEMTT Arma addon. See `arma3/AGENTS.md`.
- `docs/` — `contract.md` (protocol), `adapter.md` and `in-game-testing.md` (Arma 3), `architecture.md`.
- `adr/` — architecture decision records.
- `.github/workflows/` — `proto.yml` (buf lint/breaking/BSR push), `ci.yml` (Rust, generated-code and addon checks), `build.yml` (reusable addon build), `nightly.yml`. `ci.yml` skips PRs that only touch Markdown or top-level dotfiles; any other PR runs every job.

## Build and test

From the repo root, one Cargo workspace (`server`, `arma3`) and one `Cargo.lock`:

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo bench --workspace --no-run
cargo llvm-cov --workspace --all-features --ignore-filename-regex 'server/src/gen/'   # coverage, as in CI
cargo build --release   # target/release/libminerva.so (minerva.dll on Windows)
```

Protocol and generated code:

```sh
(cd proto && buf lint && buf format --diff --exit-code && buf build)
(cd server && buf generate)   # then commit any diff under server/src/gen
```

Addon (needs `hemtt`): `cd arma3 && hemtt check`. `hemtt release` packaging is described in `arma3/AGENTS.md`.

A protocol change touches `proto/`, the regenerated `server/src/gen/`, and any adapter code
that uses the changed API, all in one PR. CI fails if the generated code is stale.
