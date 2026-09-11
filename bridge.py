"""Serve the 3D web viewer and stream raw controller packets to it over WebSocket.

    .venv/bin/python bridge.py          # connect to the controller, open http://localhost:8765
    .venv/bin/python remote.py --viewer # same stream while also driving mouse/keyboard

Every notification from the data characteristic is forwarded unchanged as a
binary WebSocket frame; the page decodes it with the same rules as gearvr.py.
"""
import asyncio
import mimetypes
import sys
import webbrowser
from http import HTTPStatus
from pathlib import Path

from websockets.asyncio.server import ServerConnection, broadcast, serve
from websockets.datastructures import Headers
from websockets.http11 import Request, Response

from gearvr import Controller

VIEWER_DIR = Path(__file__).parent / "viewer"
PORT = 8765


class ViewerServer:
    def __init__(self, port: int = PORT):
        self.port = port
        self.clients: set[ServerConnection] = set()
        self.status = b"S" + b"searching"

    def publish(self, data: bytes) -> None:
        broadcast(self.clients, data)

    def set_status(self, text: str) -> None:
        self.status = b"S" + text.encode()
        broadcast(self.clients, self.status)

    def _static(self, connection: ServerConnection, request: Request) -> Response | None:
        if request.path == "/ws":
            return None  # proceed with the WebSocket handshake
        rel = request.path.split("?")[0].lstrip("/") or "index.html"
        path = (VIEWER_DIR / rel).resolve()
        if VIEWER_DIR.resolve() not in path.parents or not path.is_file():
            return connection.respond(HTTPStatus.NOT_FOUND, "not found\n")
        ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        body = path.read_bytes()
        headers = Headers([("Content-Type", ctype), ("Content-Length", str(len(body))),
                           ("Cache-Control", "no-cache")])
        return Response(200, "OK", headers, body)

    async def _handler(self, ws: ServerConnection) -> None:
        self.clients.add(ws)
        try:
            await ws.send(self.status)
            await ws.wait_closed()
        finally:
            self.clients.discard(ws)

    async def start(self):
        server = await serve(self._handler, "localhost", self.port, process_request=self._static)
        print(f"viewer at http://localhost:{self.port}", flush=True)
        return server


async def main() -> None:
    viewer = ViewerServer()
    await viewer.start()
    if "--no-browser" not in sys.argv:
        webbrowser.open(f"http://localhost:{viewer.port}/?source=bridge")
    while True:
        disconnected = asyncio.Event()
        try:
            viewer.set_status("searching")
            print("looking for the controller (press a button to wake it)...", flush=True)
            async with Controller(on_raw=viewer.publish, on_disconnect=disconnected.set) as c:
                viewer.set_status("connecting")
                await c.start_vr_stream()
                viewer.set_status("streaming")
                print("streaming", flush=True)
                await disconnected.wait()
        except Exception as exc:
            print(f"connection problem: {exc}", flush=True)
        viewer.set_status("disconnected")
        await asyncio.sleep(2)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
