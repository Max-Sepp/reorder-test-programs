use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;

// Compile-time default assets directory: the project-root "assets" folder,
// resolved relative to this crate (rust/axum/../../assets). Overridden at
// runtime by the ASSETS_DIR environment variable.
const DEFAULT_ASSETS_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets");

// Resolve the assets directory: ASSETS_DIR env var wins, otherwise the
// compile-time default. (Helpers are #[allow(dead_code)] because endpoints can
// be excluded at compile time -- see the `echo`/`log`/... features -- leaving
// some of them unreferenced.)
#[allow(dead_code)]
fn assets_dir() -> String {
    env::var("ASSETS_DIR").unwrap_or_else(|_| DEFAULT_ASSETS_DIR.to_string())
}

#[allow(dead_code)]
fn log_path() -> PathBuf {
    PathBuf::from(assets_dir()).join("server.axum.log")
}

// Resolve the listen port: PORT env var wins, otherwise this server's default.
// Each implementation uses a distinct default so several can run at once.
fn port() -> u16 {
    env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8083)
}

// Serializes access to the log file across worker threads.
#[allow(dead_code)]
static LOG_MUTEX: Mutex<()> = Mutex::new(());

// Builds a response serving a file from the assets directory, or a 404 if it is
// missing.
#[allow(dead_code)]
fn serve_asset(filename: &str) -> Response {
    match fs::read(PathBuf::from(assets_dir()).join(filename)) {
        Ok(body) => (
            [(header::CONTENT_TYPE, "application/octet-stream")],
            body,
        )
            .into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "asset not found").into_response(),
    }
}

// POST /echo : echo the request body back to the client.
#[cfg(feature = "echo")]
async fn echo(body: axum::body::Bytes) -> Response {
    (
        [(header::CONTENT_TYPE, "application/octet-stream")],
        body,
    )
        .into_response()
}

// GET /log : return the full contents of the log file.
#[cfg(feature = "log")]
async fn get_log() -> Response {
    let _guard = LOG_MUTEX.lock().unwrap();
    let body = fs::read(log_path()).unwrap_or_default(); // empty if absent
    (
        [(header::CONTENT_TYPE, "application/octet-stream")],
        body,
    )
        .into_response()
}

// POST /log : append the request body to the log file.
#[cfg(feature = "log")]
async fn post_log(body: axum::body::Bytes) -> Response {
    use std::io::Write;
    let _guard = LOG_MUTEX.lock().unwrap();
    let opened = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path());
    if let Ok(mut f) = opened {
        if f.write_all(&body).is_ok() {
            return StatusCode::NO_CONTENT.into_response();
        }
    }
    (StatusCode::INTERNAL_SERVER_ERROR, "cannot open log").into_response()
}

// GET /smallfile : the kilobyte file.
#[cfg(feature = "smallfile")]
async fn smallfile() -> Response {
    serve_asset("smallfile")
}

// GET /bigfile : the megabyte file.
#[cfg(feature = "bigfile")]
async fn bigfile() -> Response {
    serve_asset("bigfile")
}

#[tokio::main]
async fn main() {
    #[allow(unused_mut)]
    let mut app = Router::new();

    #[cfg(feature = "echo")]
    {
        app = app.route("/echo", post(echo));
    }

    #[cfg(feature = "log")]
    {
        app = app.route("/log", get(get_log).post(post_log));
    }

    #[cfg(feature = "smallfile")]
    {
        app = app.route("/smallfile", get(smallfile));
    }

    #[cfg(feature = "bigfile")]
    {
        app = app.route("/bigfile", get(bigfile));
    }

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port()));
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
