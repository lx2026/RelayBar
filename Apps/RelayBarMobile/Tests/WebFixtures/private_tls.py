"""Provide the temporary TLS identities and a passive loopback RTC listener for WebViewCheck."""
import base64
import hashlib
import http.server
import os
from pathlib import Path
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import threading


class Service(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/socket":
            key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            self.send_response_only(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
            self.end_headers()
            self.wfile.write(b"\x81\x02ok")
            self.wfile.flush()
            self.close_connection = True
            self.connection.settimeout(4)
            try:
                self.connection.recv(64)
            except TimeoutError:
                pass
            return
        if self.path == "/asset.js":
            mime = "application/javascript"
            body = b"window.assetLoaded=true"
        else:
            mime = "text/html"
            body = b"""<title>Waiting</title><script src="/asset.js"></script><script>
            const s=new WebSocket('wss://'+location.host+'/socket');
            s.onmessage=e=>{if(window.assetLoaded && e.data==='ok') document.title='Connected'};
            s.onerror=()=>document.title='Socket failed';
            </script>"""
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def context(directory, index):
    key, cert = (directory / (name + str(index)) for name in ("key", "cert"))
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048",
                    "-keyout", str(key), "-out", str(cert), "-days", "1", "-nodes",
                    "-subj", "/CN=Temporary service"], check=True,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    return ctx


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp, http.server.ThreadingHTTPServer(("127.0.0.1", 0), Service) as server:
        directory = Path(tmp)
        rotate = directory / "rotate"
        first, second = (context(directory, index) for index in range(2))

        def select_certificate(sock, name, initial):
            sock.context = second if rotate.exists() else first

        first.set_servername_callback(select_certificate)
        server.socket = first.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        with socket.create_server(("127.0.0.1", 0)) as rtc:
            result = subprocess.run(sys.argv[1:], env=dict(os.environ, RELAY_TLS_PORT=str(server.server_port),
                                                           RELAY_TLS_ROTATE=str(rotate),
                                                           RELAY_RTC_PORT=str(rtc.getsockname()[1])))
            if select.select([rtc], [], [], 0)[0]:
                sys.exit("FAIL preview contacted loopback RTC listener")
            print("PASS loopback RTC listener received no connections")
        server.shutdown()
        sys.exit(result.returncode)
