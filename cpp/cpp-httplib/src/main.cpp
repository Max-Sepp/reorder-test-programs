#include <httplib.h>

#include <csignal>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>

namespace {

// Resolve the assets directory: ASSETS_DIR env var wins, otherwise the
// compile-time default pointing at the project-root "assets" folder.
std::string assets_dir() {
    if (const char* env = std::getenv("ASSETS_DIR")) {
        return env;
    }
    return DEFAULT_ASSETS_DIR;
}

std::string log_path() {
    return assets_dir() + "/server.httplib.log";
}

// Resolve the listen port: PORT env var wins, otherwise this server's default.
// Each implementation uses a distinct default so several can run at once.
int port() {
    if (const char* env = std::getenv("PORT")) {
        if (int p = std::atoi(env)) {
            return p;
        }
    }
    return 8081;
}

// Serializes access to the log file across worker threads.
std::mutex g_log_mutex;

// Reads an entire file into a string. Returns false if it can't be opened.
bool read_file(const std::string& path, std::string& out) {
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
void serve_asset(const std::string& filename, httplib::Response& res) {
    std::string body;
    if (!read_file(assets_dir() + "/" + filename, body)) {
        res.status = 404;
        res.set_content("asset not found", "text/plain");
        return;
    }
    res.set_content(std::move(body), "application/octet-stream");
}

// Lets the signal handler stop the blocking listen() so main() can return
// cleanly (and the sanitiser leak check can run on exit).
httplib::Server* g_app = nullptr;

void handle_signal(int) {
    if (g_app) {
        g_app->stop();
    }
}

}  // namespace

int main() {
    httplib::Server app;
    g_app = &app;
    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    // POST /echo : echo the request body back to the client.
    app.Post("/echo", [](const httplib::Request& req, httplib::Response& res) {
        res.set_content(req.body, "application/octet-stream");
    });

    // GET /log : return the full contents of the log file.
    app.Get("/log", [](const httplib::Request&, httplib::Response& res) {
        std::lock_guard<std::mutex> lock(g_log_mutex);
        std::string body;
        read_file(log_path(), body);  // empty if absent
        res.set_content(std::move(body), "application/octet-stream");
    });

    // POST /log : append the request body to the log file.
    app.Post("/log", [](const httplib::Request& req, httplib::Response& res) {
        std::lock_guard<std::mutex> lock(g_log_mutex);
        std::ofstream out(log_path(), std::ios::app | std::ios::binary);
        if (!out) {
            res.status = 500;
            res.set_content("cannot open log", "text/plain");
            return;
        }
        out << req.body;
        res.status = 204;
    });

    // GET /smallfile : the kilobyte file.
    app.Get("/smallfile", [](const httplib::Request&, httplib::Response& res) {
        serve_asset("smallfile", res);
    });

    // GET /bigfile : the megabyte file.
    app.Get("/bigfile", [](const httplib::Request&, httplib::Response& res) {
        serve_asset("bigfile", res);
    });

    app.listen("0.0.0.0", port());
    return 0;
}
