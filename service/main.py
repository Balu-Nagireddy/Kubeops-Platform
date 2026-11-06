#!/usr/bin/env python3
import json
import os
import signal
import socket
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

def get_config_val(key: str, default: str) -> str:
    # First priority: mounted config file (dynamically updated if ConfigMap is patched)
    file_path = os.path.join("/etc/config", key)
    if os.path.isfile(file_path):
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                val = f.read().strip()
                if val:
                    return val
        except Exception:
            pass
    # Second priority: environment variable
    return os.environ.get(key, default)

class DemoHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Format clean access logs to stdout
        sys.stdout.write(f"{self.address_string()} - [{self.log_date_time_string()}] {format % args}\n")
        sys.stdout.flush()

    def do_GET(self):
        if self.path == "/" or self.path == "":
            app_name = get_config_val("APP_NAME", "demo-app")
            version = get_config_val("VERSION", "1.0.0")
            pod_name = socket.gethostname()

            payload = {
                "app": app_name,
                "version": version,
                "pod": pod_name
            }
            body = json.dumps(payload, indent=2).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/healthz":
            body = b'{"status":"ok"}\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        else:
            body = b'{"error":"not found"}\n'
            self.send_response(404)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

def main():
    port_str = os.environ.get("PORT", "8080")
    try:
        port = int(port_str)
    except ValueError:
        port = 8080

    server_address = ("0.0.0.0", port)
    httpd = HTTPServer(server_address, DemoHandler)

    def handle_signal(sig, frame):
        sys.stdout.write(f"Received signal {sig}, shutting down gracefully...\n")
        sys.stdout.flush()
        httpd.server_close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    sys.stdout.write(f"Starting demo service on port {port}...\n")
    sys.stdout.flush()

    try:
        httpd.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        httpd.server_close()

if __name__ == "__main__":
    main()
