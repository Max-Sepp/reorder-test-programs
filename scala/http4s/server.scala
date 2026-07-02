//> using platform native
//> using scala 3.3.4
//> using dep "org.http4s::http4s-ember-server::0.23.34"
//> using dep "org.http4s::http4s-dsl::0.23.34"
//> using nativeGc "boehm"
//> using nativeMode "debug"
//> using nativeLinking "-Wl,--emit-relocs"

// Scala Native http4s server, mirroring the shared server contract used by the
// Rust/C++ implementations (README.md): the same five routes, PORT + ASSETS_DIR
// from the environment, and a per-server log file. Built native so the same
// BOLT startup-reordering experiment (tmp/ordering_by_function_order.md) can run
// on a GC'd, LLVM-compiled managed-language binary.

import java.nio.file.{Files, Path, Paths, StandardOpenOption}

import cats.effect.{IO, IOApp}
import cats.syntax.all.*
import com.comcast.ip4s.{Host, Port}
import fs2.Chunk
import org.http4s.{HttpApp, HttpRoutes, MediaType}
import org.http4s.dsl.io.*
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.headers.`Content-Type`

object Server extends IOApp.Simple:

  // ASSETS_DIR env wins, otherwise the project "assets" dir (relative to cwd,
  // which is the repo root when traced/measured).
  private def assetsDir: Path =
    Paths.get(sys.env.getOrElse("ASSETS_DIR", "assets"))

  private def logPath: Path = assetsDir.resolve("server.http4s.log")

  // PORT env wins, otherwise this server's default (distinct from the others so
  // several can run at once).
  private def port: Port =
    sys.env
      .get("PORT")
      .flatMap(p => p.toIntOption)
      .flatMap(Port.fromInt)
      .getOrElse(Port.fromInt(8086).get)

  private val octetStream = `Content-Type`(MediaType.application.`octet-stream`)

  // Read a file's bytes, or empty if it does not exist.
  private def readBytes(p: Path): IO[Array[Byte]] =
    IO.blocking(if Files.exists(p) then Files.readAllBytes(p) else Array.emptyByteArray)

  // Append bytes to the log file, creating it if absent.
  private def appendLog(bytes: Array[Byte]): IO[Unit] =
    IO.blocking {
      Files.write(
        logPath,
        bytes,
        StandardOpenOption.CREATE,
        StandardOpenOption.APPEND,
      )
      ()
    }

  // Serve an asset file as octet-stream, or 404 if missing.
  private def serveAsset(name: String): IO[org.http4s.Response[IO]] =
    val p = assetsDir.resolve(name)
    IO.blocking(Files.exists(p)).flatMap { exists =>
      if exists then readBytes(p).flatMap(b => Ok(b).map(_.withContentType(octetStream)))
      else NotFound("asset not found")
    }

  private val routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
    // POST /echo : echo the request body back.
    case req @ POST -> Root / "echo" =>
      req.as[Chunk[Byte]].flatMap(c => Ok(c.toArray).map(_.withContentType(octetStream)))

    // GET /log : return the full contents of the log file.
    case GET -> Root / "log" =>
      readBytes(logPath).flatMap(b => Ok(b).map(_.withContentType(octetStream)))

    // POST /log : append the request body to the log file.
    case req @ POST -> Root / "log" =>
      req.as[Chunk[Byte]].flatMap(c => appendLog(c.toArray)) *> NoContent()

    // GET /smallfile , GET /bigfile : serve the fixed-size asset files.
    case GET -> Root / "smallfile" => serveAsset("smallfile")
    case GET -> Root / "bigfile"   => serveAsset("bigfile")
  }

  private val app: HttpApp[IO] = routes.orNotFound

  val run: IO[Unit] =
    EmberServerBuilder
      .default[IO]
      .withHost(Host.fromString("0.0.0.0").get)
      .withPort(port)
      .withHttpApp(app)
      .build
      .useForever
