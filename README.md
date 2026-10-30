# Minerva

A gRPC interface for reading the state of a military simulation and commanding its units
and groups, with one adapter per engine. Currently supported: Arma 3.

| Directory | What it is |
|---|---|
| [`proto/`](proto) | Protobuf contract, package `minerva.v1`, published to the [Buf Schema Registry](https://buf.build/voron-simulations/minerva) |
| [`server/`](server) | `minerva-server`: reusable Rust library with the state cache, command dispatch and tonic services |
| [`arma3/`](arma3) | `minerva-arma3`: Arma 3 extension and HEMTT addon built on `minerva-server` |

Start with [`docs/architecture.md`](docs/architecture.md); the wire contract is in
[`docs/contract.md`](docs/contract.md). Build and test instructions, for people and agents,
are in [`AGENTS.md`](AGENTS.md).

```sh
cargo build --release   # produces target/release/libminerva.so (minerva.dll on Windows)
cargo test --workspace
```

Licensed under the [MIT License](LICENSE).
