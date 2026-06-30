# Rust implementations

A Cargo workspace with one crate per framework, each implementing the shared
test-program interface. They mirror the C++ servers (`cpp/`) endpoint-for-endpoint.

| Crate          | Framework                         | Package name    | Default port |
|----------------|-----------------------------------|-----------------|--------------|
| `axum/`        | [Axum](https://github.com/tokio-rs/axum) | `axum-server`   | `8083`       |
| `actix-web/`   | [Actix Web](https://actix.rs/)    | `actix-web-server` | `8084`    |
| `rocket/`      | [Rocket](https://rocket.rs/)      | `rocket-server` | `8085`       |

Each crate reads from and writes to the shared project-root `assets/` directory
(override with `ASSETS_DIR`), and writes its log to `assets/server.<name>.log`.

## Build

```sh
cargo build                       # whole workspace (debug)
cargo build --release             # whole workspace (release)
cargo build -p axum-server        # a single implementation
```

Or via the top-level Makefile: `make axum-release`, `make rust` is covered by
`make release` (which builds every C++ and Rust project).

## Compile-time endpoint selection

Each crate exposes one Cargo feature per endpoint — `echo`, `log`, `smallfile`,
`bigfile` — all enabled by default. Turning one off excludes that route's handler
from the build entirely (it is not registered and its code is not compiled), the
Cargo analogue of the C++ servers' `ENDPOINT_*` CMake options. For example, to
build the Axum server with only `/echo` and `/smallfile`:

```sh
cargo build -p axum-server --no-default-features --features echo,smallfile
# or: make axum-release EXTRA_CARGO_ARGS="--no-default-features --features echo,smallfile"
```

Unlike the shared C++ CMake options, Cargo features are per-crate, so a feature
selection applies to whichever package you build.

See each crate's own `README.md` for run and smoke-test instructions.
