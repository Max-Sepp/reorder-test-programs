# Rocket server

Minimal [Rocket](https://rocket.rs/) implementation of the shared test-program
interface. Listens on port `8085` by default (override with the `PORT`
environment variable), so it can run alongside the other servers.

| Route            | Description                                  |
|------------------|----------------------------------------------|
| `POST /echo`     | Echoes the request body back.                |
| `GET /log`       | Returns the contents of the log file.        |
| `POST /log`      | Appends the request body to the log file.    |
| `GET /smallfile` | Serves `assets/smallfile` (1 KiB).           |
| `GET /bigfile`   | Serves `assets/bigfile` (1 MiB).             |

Static files are read from the project-root `assets/` directory by default.
Override the location with the `ASSETS_DIR` environment variable. The log file
lives at `<assets-dir>/server.rocket.log`.

## Build

Part of the `rust/` Cargo workspace. From the repository root:

```sh
cargo build -p rocket-server                 # or: make rocket-debug
cargo build -p rocket-server --release       # or: make rocket-release
```

## Run

```sh
./rust/target/debug/rocket_server            # listens on :8085
PORT=9000 ./rust/target/debug/rocket_server  # or a port of your choosing
```

The server binds `0.0.0.0:<port>` via a Rocket figment, overriding Rocket's
default `127.0.0.1:8000` and any `ROCKET_*` configuration.

## Compile-time endpoint selection

Each endpoint is gated behind a Cargo feature (`echo`, `log`, `smallfile`,
`bigfile`), all enabled by default. Turn one off and its handler is not compiled
into the binary at all. For example, to build with only `/echo` and `/smallfile`:

```sh
cargo build -p rocket-server --no-default-features --features echo,smallfile
# or: make rocket-release EXTRA_CARGO_ARGS="--no-default-features --features echo,smallfile"
```

## Smoke test

```sh
curl -d 'hello' localhost:8085/echo            # -> hello
curl -d 'line 1' localhost:8085/log            # append
curl localhost:8085/log                        # -> line 1
curl -O localhost:8085/smallfile               # 1 KiB
curl -O localhost:8085/bigfile                 # 1 MiB
```
