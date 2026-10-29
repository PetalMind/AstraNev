#!/usr/bin/env python3
"""Optional self-hosted unverified road notices. Python standard library only.
Run behind an HTTPS reverse proxy; the iOS client never accepts plain HTTP.
No account/device identifiers, cookies or free-form user text are collected.
"""
import datetime as dt
import contextlib
import http.server
import json
import math
import os
import sqlite3
import threading
import time
import urllib.parse
import uuid

KINDS = {"police", "accident", "hazard", "jam", "roadworks"}
LOCK = threading.Lock()
RATE = {}
DB_PATH = os.environ.get("ROAD_REPORTS_DB", "road-reports.sqlite3")


@contextlib.contextmanager
def database():
    connection = sqlite3.connect(DB_PATH, timeout=5)
    connection.execute("CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, payload TEXT NOT NULL, expires INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL)")
    connection.execute("DELETE FROM reports WHERE expires <= ?", (int(time.time()),))
    try:
        yield connection
        connection.commit()
    finally:
        connection.close()


def timestamp(raw):
    if not isinstance(raw, str):
        raise ValueError("time")
    value = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if value.tzinfo is None:
        raise ValueError("timezone")
    return value.timestamp()


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "RoadReports/1"

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *_args):
        # In particular, do not log bbox, GPS coordinates or request bodies.
        pass

    def answer(self, status, payload, retry=None):
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if retry:
            self.send_header("Retry-After", str(retry))
        self.end_headers()
        self.wfile.write(data)

    def rate_allowed(self, maximum):
        # In-memory only; trust the socket peer, never a caller's forwarded header.
        key = (self.client_address[0], self.command)
        now = time.monotonic()
        with LOCK:
            for item in list(RATE):
                RATE[item] = [t for t in RATE[item] if now - t < 60]
                if not RATE[item]:
                    del RATE[item]
            visits = RATE.setdefault(key, [])
            if len(visits) >= maximum or len(RATE) > 10000:
                return False
            visits.append(now)
        return True

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path != "/reports":
            return self.answer(404, {"error": "Nie znaleziono zasobu."})
        if not self.rate_allowed(60):
            return self.answer(429, {"error": "Odczekaj przed kolejnym odczytem."}, retry=60)
        try:
            values = urllib.parse.parse_qs(parsed.query)["bbox"]
            if len(values) != 1:
                raise ValueError("bbox")
            west, south, east, north = [float(v) for v in values[0].split(",")]
            if not all(math.isfinite(v) for v in [west, south, east, north]):
                raise ValueError("finite")
            if not (13 <= west <= east <= 25 and 48 <= south <= north <= 56 and east - west <= 3 and north - south <= 2):
                raise ValueError("coverage")
            with database() as connection:
                rows = connection.execute("SELECT payload FROM reports WHERE lon BETWEEN ? AND ? AND lat BETWEEN ? AND ? ORDER BY expires DESC LIMIT 200", (west, east, south, north)).fetchall()
            self.answer(200, {"reports": [json.loads(row[0]) for row in rows]})
        except (ValueError, KeyError):
            self.answer(400, {"error": "Nieprawidłowy obszar zapytania."})
        except sqlite3.Error:
            self.answer(503, {"error": "Zgłoszenia chwilowo niedostępne."}, retry=60)

    def do_POST(self):
        if urllib.parse.urlsplit(self.path).path != "/reports":
            return self.answer(404, {"error": "Nie znaleziono zasobu."})
        if not self.rate_allowed(4):
            return self.answer(429, {"error": "Odczekaj przed kolejnym zgłoszeniem."}, retry=60)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not (1 <= length <= 2048) or self.headers.get_content_type() != "application/json":
                raise ValueError("body")
            payload = json.loads(self.rfile.read(length))
            if set(payload) != {"id", "kind", "coordinate", "createdAt", "expiresAt"} or payload["kind"] not in KINDS:
                raise ValueError("schema")
            report_id = str(uuid.UUID(payload["id"]))
            if uuid.UUID(report_id).version != 4:
                raise ValueError("id")
            lat, lon = float(payload["coordinate"]["latitude"]), float(payload["coordinate"]["longitude"])
            if not (math.isfinite(lat) and math.isfinite(lon) and 48 <= lat <= 56 and 13 <= lon <= 25):
                raise ValueError("point")
            now = int(time.time())
            created, expires = timestamp(payload["createdAt"]), timestamp(payload["expiresAt"])
            if abs(created - now) > 120 or not (0 < expires - now <= 1805) or not (0 < expires - created <= 1800):
                raise ValueError("expiry")
            # This service does not confirm reports and never extends their lifetime.
            safe = {"id": report_id, "kind": payload["kind"],
                    "coordinate": {"latitude": round(lat, 3), "longitude": round(lon, 3)},
                    "createdAt": iso(created), "expiresAt": iso(min(expires, now + 1800))}
            with database() as connection:
                if connection.execute("SELECT COUNT(*) FROM reports").fetchone()[0] >= 10000:
                    return self.answer(503, {"error": "Limit aktywnych zgłoszeń."}, retry=60)
                # Idempotency: repeated POST of the same ID cannot renew or move it.
                connection.execute("INSERT OR IGNORE INTO reports VALUES (?, ?, ?, ?, ?)",
                                   (report_id, json.dumps(safe, ensure_ascii=False), int(expires), safe["coordinate"]["latitude"], safe["coordinate"]["longitude"]))
            self.answer(201, {"id": report_id, "status": "unverified"})
        except (ValueError, TypeError, KeyError, OverflowError):
            self.answer(400, {"error": "Nieprawidłowe lub nieaktualne zgłoszenie."})
        except sqlite3.Error:
            self.answer(503, {"error": "Nie udało się zapisać zgłoszenia."}, retry=60)


class ReportServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    workers = threading.BoundedSemaphore(32)

    def process_request(self, request, client_address):
        if not self.workers.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.workers.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.workers.release()

    def handle_error(self, request, client_address):
        # No peer address or URL in diagnostic logs.
        pass


def main():
    host = os.environ.get("ROAD_REPORTS_BIND", "127.0.0.1")
    # Default is loopback; HTTPS/TLS, public rate limiting and moderation are an
    # operator responsibility, not a silently provisioned paid dependency.
    port = int(os.environ.get("ROAD_REPORTS_PORT", "8787"))
    server = ReportServer((host, port), Handler)
    server.timeout = 10
    server.serve_forever()


if __name__ == "__main__":
    main()
