# Crow server

Minimal [Crow](https://crowcpp.org/) implementation of the shared test-program
interface. Listens on port `8080`.

| Route            | Description                                  |
|------------------|----------------------------------------------|
| `POST /echo`     | Echoes the request body back.                |
| `GET /log`       | Returns the contents of the log file.        |
| `POST /log`      | Appends the request body to the log file.    |
| `GET /smallfile` | Serves `assets/smallfile` (1 KiB).           |
| `GET /bigfile`   | Serves `assets/bigfile` (1 MiB).             |

Static files are read from the project-root `assets/` directory by default.
Override the location with the `ASSETS_DIR` environment variable. The log file
lives at `<assets-dir>/server.log`.

## Build

Requires [vcpkg](https://github.com/microsoft/vcpkg) and CMake >= 3.16.

```sh
cmake -B build -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
cmake --build build
```

vcpkg installs Crow (and its Asio dependency) from `vcpkg.json` during configure.

## Run

```sh
./build/crow_server
```

## Smoke test

```sh
curl -d 'hello' localhost:8080/echo            # -> hello
curl -d 'line 1' localhost:8080/log            # append
curl localhost:8080/log                        # -> line 1
curl -O localhost:8080/smallfile               # 1 KiB
curl -O localhost:8080/bigfile                 # 1 MiB
```
