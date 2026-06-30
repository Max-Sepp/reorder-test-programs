# Reorder test programs

A set of small, equivalent web servers written against a common interface,
used as benchmark targets for optimising program **startup time** with
[LLVM BOLT](https://github.com/llvm/llvm-project/tree/main/bolt) (function/block
reordering). Built for a Summer 2026 UROP at MIT.

The goal is to have several real-world-ish servers that all expose the *same*
endpoints, so startup-time optimisations can be measured and compared across
different frameworks and languages.

## Interface

Every server implements the same HTTP interface and listens on **port 8080**.

| Method & route   | Description                                            |
|------------------|--------------------------------------------------------|
| `POST /echo`     | Echoes the request body back to the client.            |
| `GET /log`       | Returns the full contents of the log file.             |
| `POST /log`      | Appends the request body to the log file.              |
| `GET /smallfile` | Returns the kilobyte file (`assets/smallfile`, 1 KiB). |
| `GET /bigfile`   | Returns the megabyte file (`assets/bigfile`, 1 MiB).   |

## Layout

```
.
├── assets/              Shared static files served by every implementation
│   ├── smallfile          1 KiB file for GET /smallfile
│   ├── bigfile            1 MiB file for GET /bigfile
│   └── server.log         Log file (created at runtime, git-ignored)
└── cpp/                 C++ implementations
    ├── crow/              Crow framework — implemented
    ├── cpp-httplib/       cpp-httplib — planned
    └── drogon/            Drogon framework — planned
```

Each implementation reads from and writes to the shared `assets/` directory, so
all servers serve identical payloads and share the same log file location.

## Implementations

| Implementation | Language | Build system    | Status      |
|----------------|----------|-----------------|-------------|
| `cpp/crow`     | C++17    | CMake + vcpkg   | ✅ Done     |
| `cpp/cpp-httplib` | C++   | CMake + vcpkg   | 🚧 Planned  |
| `cpp/drogon`   | C++      | CMake + vcpkg   | 🚧 Planned  |

See each implementation's own `README.md` for build and run instructions
(e.g. [`cpp/crow/README.md`](cpp/crow/README.md)).

## Quick start (Crow)

Requires [vcpkg](https://github.com/microsoft/vcpkg) and CMake >= 3.16.

```sh
cd cpp/crow
cmake -B build -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
cmake --build build
./build/crow_server
```

Then, from another shell:

```sh
curl -d 'hello' localhost:8080/echo      # -> hello
curl -d 'a line' localhost:8080/log      # append to the log
curl localhost:8080/log                  # read it back
curl -O localhost:8080/smallfile         # 1 KiB
curl -O localhost:8080/bigfile           # 1 MiB
```

## Notes

- Servers locate the static files via the project-root `assets/` directory by
  default; the Crow server lets you override this with the `ASSETS_DIR`
  environment variable.
- `assets/smallfile` and `assets/bigfile` are fixed-size fixtures (exactly 1 KiB
  and 1 MiB). Regenerate them with `head -c 1024 /dev/urandom > assets/smallfile`
  and `head -c 1048576 /dev/urandom > assets/bigfile` if needed.
