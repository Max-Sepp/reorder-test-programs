use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use actix_web::{web, App, HttpResponse, HttpServer};

// Compile-time default assets directory: the project-root "assets" folder,
// resolved relative to this crate (rust/actix-web/../../assets). Overridden at
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
    PathBuf::from(assets_dir()).join("server.actix.log")
}

// Resolve the listen port: PORT env var wins, otherwise this server's default.
// Each implementation uses a distinct default so several can run at once.
fn port() -> u16 {
    env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8084)
}

// Serializes access to the log file across worker threads.
#[allow(dead_code)]
static LOG_MUTEX: Mutex<()> = Mutex::new(());

// Builds a response serving a file from the assets directory, or a 404 if it is
// missing.
#[allow(dead_code)]
fn serve_asset(filename: &str) -> HttpResponse {
    match fs::read(PathBuf::from(assets_dir()).join(filename)) {
        Ok(body) => HttpResponse::Ok()
            .content_type("application/octet-stream")
            .body(body),
        Err(_) => HttpResponse::NotFound()
            .content_type("text/plain")
            .body("asset not found"),
    }
}

// POST /echo : echo the request body back to the client.
#[cfg(feature = "echo")]
async fn echo(body: web::Bytes) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("application/octet-stream")
        .body(body)
}

// GET /log : return the full contents of the log file.
#[cfg(feature = "log")]
async fn get_log() -> HttpResponse {
    let _guard = LOG_MUTEX.lock().unwrap();
    let body = fs::read(log_path()).unwrap_or_default(); // empty if absent
    HttpResponse::Ok()
        .content_type("application/octet-stream")
        .body(body)
}

// POST /log : append the request body to the log file.
#[cfg(feature = "log")]
async fn post_log(body: web::Bytes) -> HttpResponse {
    use std::io::Write;
    let _guard = LOG_MUTEX.lock().unwrap();
    let opened = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path());
    if let Ok(mut f) = opened {
        if f.write_all(&body).is_ok() {
            return HttpResponse::NoContent().finish();
        }
    }
    HttpResponse::InternalServerError()
        .content_type("text/plain")
        .body("cannot open log")
}

// GET /smallfile : the kilobyte file.
#[cfg(feature = "smallfile")]
async fn smallfile() -> HttpResponse {
    serve_asset("smallfile")
}

// GET /bigfile : the megabyte file.
#[cfg(feature = "bigfile")]
async fn bigfile() -> HttpResponse {
    serve_asset("bigfile")
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    HttpServer::new(|| {
        #[allow(unused_mut)]
        let mut app = App::new();

        #[cfg(feature = "echo")]
        {
            app = app.route("/echo", web::post().to(echo));
        }

        #[cfg(feature = "log")]
        {
            app = app
                .route("/log", web::get().to(get_log))
                .route("/log", web::post().to(post_log));
        }

        #[cfg(feature = "smallfile")]
        {
            app = app.route("/smallfile", web::get().to(smallfile));
        }

        #[cfg(feature = "bigfile")]
        {
            app = app.route("/bigfile", web::get().to(bigfile));
        }

        app
    })
    .bind(("0.0.0.0", port()))?
    .run()
    .await
}
