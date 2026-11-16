#!/usr/bin/env python3

import argparse
import os
import signal
import socket
import sys
import threading


def serve(listener: socket.socket, token: bytes) -> None:
    while True:
        connection, _ = listener.accept()
        with connection:
            payload = connection.recv(64 * 1024)
            connection.sendall(token + b":" + payload)


def run_server(arguments: argparse.Namespace) -> None:
    listeners: list[socket.socket] = []
    tcp_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp_listener.bind(("127.0.0.1", arguments.tcp))
    tcp_listener.listen()
    listeners.append(tcp_listener)

    if os.path.lexists(arguments.unix):
        raise RuntimeError(f"refusing existing Unix path: {arguments.unix}")
    unix_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    unix_listener.bind(arguments.unix)
    unix_listener.listen()
    listeners.append(unix_listener)

    token = arguments.token.encode("utf-8")
    for listener in listeners:
        threading.Thread(
            target=serve,
            args=(listener, token),
            daemon=True,
        ).start()

    print(
        f"READY {os.getpid()} {tcp_listener.getsockname()[1]} {arguments.unix}",
        flush=True,
    )

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    stop.wait()

    for listener in listeners:
        listener.close()
    if os.path.lexists(arguments.unix):
        os.unlink(arguments.unix)


def run_client(arguments: argparse.Namespace) -> None:
    if arguments.kind == "tcp":
        connection = socket.create_connection(
            (arguments.host, arguments.port),
            timeout=10,
        )
    else:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(10)
        connection.connect(arguments.path)

    with connection:
        connection.sendall(arguments.payload.encode("utf-8"))
        received = connection.recv(64 * 1024).decode("utf-8")

    expected = f"{arguments.expected}:{arguments.payload}"
    if received != expected:
        raise RuntimeError(f"expected {expected!r}, received {received!r}")
    print(f"PASS {arguments.name}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    server = commands.add_parser("serve")
    server.add_argument("--tcp", type=int, default=0)
    server.add_argument("--unix", required=True)
    server.add_argument("--token", required=True)

    client = commands.add_parser("client")
    client.add_argument("--name", required=True)
    client.add_argument("--kind", choices=("tcp", "unix"), required=True)
    client.add_argument("--host", default="127.0.0.1")
    client.add_argument("--port", type=int)
    client.add_argument("--path")
    client.add_argument("--payload", required=True)
    client.add_argument("--expected", required=True)

    return result


def main() -> None:
    arguments = parser().parse_args()
    if arguments.command == "serve":
        run_server(arguments)
    else:
        if arguments.kind == "tcp" and arguments.port is None:
            raise RuntimeError("TCP client requires --port")
        if arguments.kind == "unix" and not arguments.path:
            raise RuntimeError("Unix client requires --path")
        run_client(arguments)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR {error}", file=sys.stderr)
        raise
