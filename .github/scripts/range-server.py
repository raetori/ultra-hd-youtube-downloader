# Test server for the CI file-download check: serves files from a folder with byte-range support,
# slowed down a little so a download can be paused part way. Listens on 127.0.0.1 only.
import http.server, mimetypes, os, re, sys, time

ROOT = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8766


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(ROOT, os.path.basename(self.path.split("?")[0]))
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200
        match = re.match(r"bytes=(\d+)-(\d*)$", self.headers.get("Range", ""))
        if match:
            start = int(match.group(1))
            end = min(int(match.group(2)) if match.group(2) else size - 1, size - 1)
            if start > end:
                self.send_error(416)
                return
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", mimetypes.guess_type(path)[0] or "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
                    time.sleep(0.01)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
