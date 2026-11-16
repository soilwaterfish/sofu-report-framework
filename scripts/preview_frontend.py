#!/usr/bin/env python3
"""Serve working frontend files with the latest exported data and map frames."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit
import argparse

ROOT = Path(__file__).resolve().parents[1]


class PreviewHandler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        relative = unquote(urlsplit(path).path).lstrip("/") or "index.html"
        base = ROOT / "output/latest" if relative.startswith(("data/", "assets/indices/")) else ROOT / "web"
        overlay = (ROOT / "output/facelift" / relative).resolve()
        overlay_root = (ROOT / "output/facelift").resolve()
        if relative.startswith("data/") and overlay.is_relative_to(overlay_root) and overlay.is_file():
            return str(overlay)
        target = (base / relative).resolve()
        if not target.is_relative_to(base.resolve()):
            return str(ROOT / "web/__not_found__")
        return str(target)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8081)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), PreviewHandler)
    print(f"SOFU frontend preview: http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()
