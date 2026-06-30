# Drogon server

Minimal [Drogon](https://github.com/drogonframework/drogon) implementation of
the shared test-program interface. Listens on port `8082` by default (override
with the `PORT` environment variable), so it can run alongside the other
servers.

| Route            | Description                                  |
|------------------|----------------------------------------------|
| `POST /echo`     | Echoes the request body back.                |
| `GET /log`       | Returns the contents of the log file.        |
| `POST /log`      | Appends the request body to the log file.    |
| `GET /smallfile` | Serves `assets/smallfile` (1 KiB).           |
| `GET /bigfile`   | Serves `assets/bigfile` (1 MiB).             |

Static files are read from the project-root `assets/` directory by default.
Override the location with the `ASSETS_DIR` environment variable. The log file
lives at `<assets-dir>/server.drogon.log`.

## Build

Requires [vcpkg](https://github.com/microsoft/vcpkg) and CMake >= 3.16.

```sh
cmake -B build -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
cmake --build build
```

vcpkg installs Drogon (and its dependencies) from `vcpkg.json` during configure.

## Run

```sh
./build/drogon_server            # listens on :8082
PORT=9000 ./build/drogon_server  # or a port of your choosing
```

## Smoke test

```sh
curl -d 'hello' localhost:8082/echo            # -> hello
curl -d 'line 1' localhost:8082/log            # append
curl localhost:8082/log                        # -> line 1
curl -O localhost:8082/smallfile               # 1 KiB
curl -O localhost:8082/bigfile                 # 1 MiB
```
