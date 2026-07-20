"""Phone-side relay. Runs directly in Termux with Python 3."""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import socket

from .protocol import (
    STATUS_BAD_REQUEST,
    STATUS_CONNECT_FAILED,
    STATUS_OK,
    ProtocolError,
    bridge,
    read_request,
)

LOG = logging.getLogger("opentetrd.phone")
REQUEST_TIMEOUT = 30.0


def _set_nodelay(writer: asyncio.StreamWriter) -> None:
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    remote_writer: asyncio.StreamWriter | None = None
    _set_nodelay(writer)
    try:
        # Bound the header read so a silent peer cannot pin this task forever.
        host, port = await asyncio.wait_for(read_request(reader), timeout=REQUEST_TIMEOUT)
    except (ProtocolError, asyncio.IncompleteReadError, TimeoutError) as exc:
        LOG.warning("bad relay request: %s", exc)
        writer.write(bytes([STATUS_BAD_REQUEST]))
        await writer.drain()
    else:
        try:
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(host, port), timeout=15
            )
        except (OSError, asyncio.TimeoutError) as exc:
            LOG.warning("cannot connect to %s:%d: %s", host, port, exc)
            writer.write(bytes([STATUS_CONNECT_FAILED]))
            await writer.drain()
        else:
            _set_nodelay(remote_writer)
            writer.write(bytes([STATUS_OK]))
            await writer.drain()
            LOG.info("relaying %s:%d", host, port)
            await bridge(reader, writer, remote_reader, remote_writer)
            return
    if remote_writer is not None:
        remote_writer.close()
        await remote_writer.wait_closed()
    writer.close()
    await writer.wait_closed()


async def run(host: str, port: int) -> None:
    if host not in {"127.0.0.1", "::1", "localhost"}:
        raise SystemExit("phone relay must listen on loopback; use adb forward for USB access")
    server = await asyncio.start_server(handle, host, port)
    LOG.info("phone relay listening on %s:%d", host, port)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    async with server:
        await stop.wait()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    asyncio.run(run(args.host, args.port))


if __name__ == "__main__":
    main()
