"""Loopback-only SOCKS5 proxy that sends connections through the phone relay."""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import logging
import signal
import socket
import struct

from .protocol import STATUS_OK, bridge, encode_request

LOG = logging.getLogger("opentetrd.desktop")
SOCKS_FAILURE = b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00"
SOCKS_SUCCESS = b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00"
HANDSHAKE_TIMEOUT = 30.0


def _set_nodelay(writer: asyncio.StreamWriter) -> None:
    """Proxied traffic is mostly small interactive writes; Nagle only adds latency."""
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass


async def read_socks_destination(reader: asyncio.StreamReader) -> tuple[str, int]:
    version, command, reserved, atyp = await reader.readexactly(4)
    if version != 5 or command != 1 or reserved != 0:
        raise ValueError("only SOCKS5 CONNECT is supported")
    if atyp == 1:
        host = str(ipaddress.IPv4Address(await reader.readexactly(4)))
    elif atyp == 4:
        host = str(ipaddress.IPv6Address(await reader.readexactly(16)))
    elif atyp == 3:
        length = (await reader.readexactly(1))[0]
        if not length:
            raise ValueError("empty SOCKS host")
        host = (await reader.readexactly(length)).decode("ascii")
    else:
        raise ValueError("unsupported SOCKS address type")
    port = struct.unpack("!H", await reader.readexactly(2))[0]
    return host, port


class SocksProxy:
    def __init__(self, relay_host: str, relay_port: int):
        self.relay_host = relay_host
        self.relay_port = relay_port

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        relay_writer: asyncio.StreamWriter | None = None
        replied = False
        try:
            _set_nodelay(writer)
            # A client that connects and then goes silent must not pin this task forever.
            async with asyncio.timeout(HANDSHAKE_TIMEOUT):
                version, methods_count = await reader.readexactly(2)
                methods = await reader.readexactly(methods_count)
                if version != 5 or 0 not in methods:
                    writer.write(b"\x05\xff")
                    await writer.drain()
                    return
                writer.write(b"\x05\x00")
                await writer.drain()
                host, port = await read_socks_destination(reader)
                relay_reader, relay_writer = await asyncio.open_connection(
                    self.relay_host, self.relay_port
                )
                _set_nodelay(relay_writer)
                relay_writer.write(encode_request(host, port))
                await relay_writer.drain()
                status = (await relay_reader.readexactly(1))[0]
            if status != STATUS_OK:
                raise ConnectionError(f"phone relay rejected destination ({status})")
            writer.write(SOCKS_SUCCESS)
            await writer.drain()
            replied = True
            LOG.info("tunneling %s:%d for %s", host, port, peer)
            await bridge(reader, writer, relay_reader, relay_writer)
            relay_writer = None
        except (asyncio.IncompleteReadError, OSError, ValueError, TimeoutError) as exc:
            LOG.warning("connection %s failed: %s", peer, exc)
            # Once the success reply is out the socket carries tunnelled bytes; a
            # failure reply written here would be injected into the payload stream.
            if not replied and not writer.is_closing():
                try:
                    writer.write(SOCKS_FAILURE)
                    await writer.drain()
                except OSError:
                    pass
        finally:
            if relay_writer is not None:
                relay_writer.close()
                await relay_writer.wait_closed()
            if not writer.is_closing():
                writer.close()
                await writer.wait_closed()


async def run(args: argparse.Namespace) -> None:
    if args.listen_host not in {"127.0.0.1", "::1", "localhost"} and not args.allow_lan:
        raise SystemExit("refusing a non-loopback SOCKS listener without --allow-lan")
    proxy = SocksProxy(args.relay_host, args.relay_port)
    server = await asyncio.start_server(proxy.handle, args.listen_host, args.listen_port)
    addresses = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    LOG.info("SOCKS5 listening on %s; phone relay %s:%d", addresses, args.relay_host, args.relay_port)
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
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=1088)
    parser.add_argument("--relay-host", default="127.0.0.1")
    parser.add_argument("--relay-port", type=int, default=8787)
    parser.add_argument("--allow-lan", action="store_true", help="allow exposing SOCKS beyond this Mac")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
