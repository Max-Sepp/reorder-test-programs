#include <crow.h>

#include <cstdlib>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>

namespace {

// Resolve the assets directory: ASSETS_DIR env var wins, otherwise the
// compile-time default pointing at the project-root "assets" folder.
// (Helpers are [[maybe_unused]] because endpoints can be excluded at compile
// time -- see ENDPOINT_* below -- leaving some of them unreferenced.)
[[maybe_unused]] std::string assets_dir() {
    if (const char* env = std::getenv("ASSETS_DIR")) {
        return env;
    }
    return DEFAULT_ASSETS_DIR;
}

[[maybe_unused]] std::string log_path() {
    return assets_dir() + "/server.crow.log";
}

// Resolve the listen port: PORT env var wins, otherwise this server's default.
// Each implementation uses a distinct default so several can run at once.
int port() {
    if (const char* env = std::getenv("PORT")) {
        if (int p = std::atoi(env)) {
            return p;
        }
    }
    return 8080;
}

// Serializes access to the log file across worker threads.
[[maybe_unused]] std::mutex g_log_mutex;

// Reads an entire file into a string. Returns false if it can't be opened.
[[maybe_unused]] bool read_file(const std::string& path, std::string& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

// Sends a file from the assets directory, or a 404 if it is missing.
[[maybe_unused]] crow::response serve_asset(const std::string& filename) {
    std::string body;
    if (!read_file(assets_dir() + "/" + filename, body)) {
        return crow::response(crow::status::NOT_FOUND, "asset not found");
    }
    crow::response res(body);
    res.set_header("Content-Type", "application/octet-stream");
    return res;
}

}  // namespace

int main() {
    crow::SimpleApp app;

#ifdef ENDPOINT_ECHO
    // POST /echo : echo the request body back to the client.
    CROW_ROUTE(app, "/echo")
        .methods(crow::HTTPMethod::POST)(
            [](const crow::request& req) { return crow::response(req.body); });
#endif

#ifdef ENDPOINT_LOG
    // GET /log : return the full contents of the log file.
    // POST /log : append the request body to the log file.
    CROW_ROUTE(app, "/log")
        .methods(crow::HTTPMethod::GET, crow::HTTPMethod::POST)(
            [](const crow::request& req) -> crow::response {
                std::lock_guard<std::mutex> lock(g_log_mutex);
                if (req.method == crow::HTTPMethod::GET) {
                    std::string body;
                    read_file(log_path(), body);  // empty if absent
                    return crow::response(body);
                } else if (req.method == crow::HTTPMethod::POST) {
                    std::ofstream out(log_path(), std::ios::app | std::ios::binary);
                    if (!out) {
                        return crow::response(crow::status::INTERNAL_SERVER_ERROR,
                                              "cannot open log");
                    }
                    out << req.body;
                    return crow::response(crow::status::NO_CONTENT);
                } else {
                    return crow::response(crow::status::METHOD_NOT_ALLOWED,
                                          "only GET and POST are allowed");
                }
                std::ofstream out(log_path(), std::ios::app | std::ios::binary);
                if (!out) {
                    return crow::response(crow::status::INTERNAL_SERVER_ERROR,
                                          "cannot open log");
                }
                out << req.body;
                return crow::response(crow::status::NO_CONTENT);
            });
#endif

#ifdef ENDPOINT_SMALLFILE
    // GET /smallfile : the kilobyte file.
    CROW_ROUTE(app, "/smallfile")(
        []() { return serve_asset("smallfile"); });
#endif

#ifdef ENDPOINT_BIGFILE
    // GET /bigfile : the megabyte file.
    CROW_ROUTE(app, "/bigfile")(
        []() { return serve_asset("bigfile"); });
#endif

    app.port(port()).multithreaded().run();
    return 0;
}
