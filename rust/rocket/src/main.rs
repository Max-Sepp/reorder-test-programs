#[macro_use]
extern crate rocket;

use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use rocket::http::{ContentType, Status};
use rocket::Route;

// Compile-time default assets directory: the project-root "assets" folder,
// resolved relative to this crate (rust/rocket/../../assets). Overridden at
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
    PathBuf::from(assets_dir()).join("server.rocket.log")
}

// Resolve the listen port: PORT env var wins, otherwise this server's default.
// Each implementation uses a distinct default so several can run at once.
fn port() -> u16 {
    env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8085)
}

// Serializes access to the log file across worker threads.
#[allow(dead_code)]
static LOG_MUTEX: Mutex<()> = Mutex::new(());

// Builds a response serving a file from the assets directory, or a 404 if it is
// missing.
#[allow(dead_code)]
fn serve_asset(filename: &str) -> (Status, (ContentType, Vec<u8>)) {
    match fs::read(PathBuf::from(assets_dir()).join(filename)) {
        Ok(body) => (Status::Ok, (ContentType::Binary, body)),
        Err(_) => (
            Status::NotFound,
            (ContentType::Plain, b"asset not found".to_vec()),
        ),
    }
}

// POST /echo : echo the request body back to the client.
#[cfg(feature = "echo")]
#[post("/echo", data = "<body>")]
fn echo(body: Vec<u8>) -> (ContentType, Vec<u8>) {
    (ContentType::Binary, body)
}

// GET /log : return the full contents of the log file.
#[cfg(feature = "log")]
#[get("/log")]
fn get_log() -> (ContentType, Vec<u8>) {
    let _guard = LOG_MUTEX.lock().unwrap();
    let body = fs::read(log_path()).unwrap_or_default(); // empty if absent
    (ContentType::Binary, body)
}

// POST /log : append the request body to the log file.
#[cfg(feature = "log")]
#[post("/log", data = "<body>")]
fn post_log(body: Vec<u8>) -> Status {
    use std::io::Write;
    let _guard = LOG_MUTEX.lock().unwrap();
    let opened = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path());
    if let Ok(mut f) = opened {
        if f.write_all(&body).is_ok() {
            return Status::NoContent;
        }
    }
    Status::InternalServerError
}

// GET /smallfile : the kilobyte file.
#[cfg(feature = "smallfile")]
#[get("/smallfile")]
fn smallfile() -> (Status, (ContentType, Vec<u8>)) {
    serve_asset("smallfile")
}

// GET /bigfile : the megabyte file.
#[cfg(feature = "bigfile")]
#[get("/bigfile")]
fn bigfile() -> (Status, (ContentType, Vec<u8>)) {
    serve_asset("bigfile")
}

#[launch]
fn rocket() -> _ {
    let mut routes: Vec<Route> = Vec::new();

    #[cfg(feature = "echo")]
    routes.extend(routes![echo]);

    #[cfg(feature = "log")]
    routes.extend(routes![get_log, post_log]);

    #[cfg(feature = "smallfile")]
    routes.extend(routes![smallfile]);

    #[cfg(feature = "bigfile")]
    routes.extend(routes![bigfile]);

    // Bind 0.0.0.0:<port> (PORT env, else this server's default), overriding
    // Rocket's localhost:8000 default and its own ROCKET_* configuration.
    let figment = rocket::Config::figment()
        .merge(("address", "0.0.0.0"))
        .merge(("port", port()));

    rocket::custom(figment).mount("/", routes)
}
