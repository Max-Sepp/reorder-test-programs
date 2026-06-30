#include <drogon/drogon.h>

#include <csignal>
#include <cstdlib>
#include <fstream>
#include <functional>
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
    return assets_dir() + "/server.drogon.log";
}

// Resolve the listen port: PORT env var wins, otherwise this server's default.
// Each implementation uses a distinct default so several can run at once.
int port() {
    if (const char* env = std::getenv("PORT")) {
        if (int p = std::atoi(env)) {
            return p;
        }
    }
    return 8082;
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

drogon::HttpResponsePtr make_response(std::string body,
                                      drogon::ContentType type) {
    auto resp = drogon::HttpResponse::newHttpResponse();
    resp->setBody(std::move(body));
    resp->setContentTypeCode(type);
    return resp;
}

// Builds a response serving a file from the assets directory, or a 404 if it
// is missing.
drogon::HttpResponsePtr serve_asset(const std::string& filename) {
    std::string body;
    if (!read_file(assets_dir() + "/" + filename, body)) {
        auto resp = make_response("asset not found", drogon::CT_TEXT_PLAIN);
        resp->setStatusCode(drogon::k404NotFound);
        return resp;
    }
    return make_response(std::move(body), drogon::CT_APPLICATION_OCTET_STREAM);
}

// Stop the event loop so main() returns cleanly (and the sanitiser leak check
// can run on exit).
void handle_signal(int) {
    drogon::app().quit();
}

}  // namespace

int main() {
    using namespace drogon;
    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    // POST /echo : echo the request body back to the client.
    app().registerHandler(
        "/echo",
        [](const HttpRequestPtr& req,
           std::function<void(const HttpResponsePtr&)>&& callback) {
            callback(make_response(std::string(req->body()),
                                   CT_APPLICATION_OCTET_STREAM));
        },
        {Post});

    // GET /log : return the full contents of the log file.
    // POST /log : append the request body to the log file.
    app().registerHandler(
        "/log",
        [](const HttpRequestPtr& req,
           std::function<void(const HttpResponsePtr&)>&& callback) {
            std::lock_guard<std::mutex> lock(g_log_mutex);
            if (req->method() == Get) {
                std::string body;
                read_file(log_path(), body);  // empty if absent
                callback(make_response(std::move(body),
                                       CT_APPLICATION_OCTET_STREAM));
                return;
            }
            std::ofstream out(log_path(), std::ios::app | std::ios::binary);
            if (!out) {
                auto resp = make_response("cannot open log", CT_TEXT_PLAIN);
                resp->setStatusCode(k500InternalServerError);
                callback(resp);
                return;
            }
            out << req->body();
            auto resp = HttpResponse::newHttpResponse();
            resp->setStatusCode(k204NoContent);
            callback(resp);
        },
        {Get, Post});

    // GET /smallfile : the kilobyte file.
    app().registerHandler(
        "/smallfile",
        [](const HttpRequestPtr&,
           std::function<void(const HttpResponsePtr&)>&& callback) {
            callback(serve_asset("smallfile"));
        },
        {Get});

    // GET /bigfile : the megabyte file.
    app().registerHandler(
        "/bigfile",
        [](const HttpRequestPtr&,
           std::function<void(const HttpResponsePtr&)>&& callback) {
            callback(serve_asset("bigfile"));
        },
        {Get});

    app().addListener("0.0.0.0", port()).run();
    return 0;
}
