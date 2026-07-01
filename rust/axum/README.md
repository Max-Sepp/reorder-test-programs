# Axum server

Minimal [Axum](https://github.com/tokio-rs/axum) implementation of the shared
test-program interface. Listens on port `8083` by default (override with the
`PORT` environment variable), so it can run alongside the other servers.

| Route            | Description                                  |
|------------------|----------------------------------------------|
| `POST /echo`     | Echoes the request body back.                |
| `GET /log`       | Returns the contents of the log file.        |
| `POST /log`      | Appends the request body to the log file.    |
| `GET /smallfile` | Serves `assets/smallfile` (1 KiB).           |
| `GET /bigfile`   | Serves `assets/bigfile` (1 MiB).             |

Static files are read from the project-root `assets/` directory by default.
Override the location with the `ASSETS_DIR` environment variable. The log file
lives at `<assets-dir>/server.axum.log`.

## Build

Part of the `rust/` Cargo workspace. From the repository root:

```sh
cargo build -p axum-server                 # or: make axum-debug
cargo build -p axum-server --release       # or: make axum-release
```

## Run

```sh
./rust/target/debug/axum_server            # listens on :8083
PORT=9000 ./rust/target/debug/axum_server  # or a port of your choosing
```

## Compile-time endpoint selection

Each endpoint is gated behind a Cargo feature (`echo`, `log`, `smallfile`,
`bigfile`), all enabled by default. Turn one off and its handler is not compiled
into the binary at all. For example, to build with only `/echo` and `/smallfile`:

```sh
cargo build -p axum-server --no-default-features --features echo,smallfile
# or: make axum-release EXTRA_CARGO_ARGS="--no-default-features --features echo,smallfile"
```

## Smoke test

```sh
curl -d 'hello' localhost:8083/echo            # -> hello
curl -d 'line 1' localhost:8083/log            # append
curl localhost:8083/log                        # -> line 1
curl -O localhost:8083/smallfile               # 1 KiB
curl -O localhost:8083/bigfile                 # 1 MiB
```
