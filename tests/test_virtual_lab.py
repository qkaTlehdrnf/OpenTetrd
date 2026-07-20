"""End-to-end lab: app -> SOCKS -> virtual phone -> virtual Internet server."""

from __future__ import annotations

import asyncio
import logging
import struct
import unittest

from opentetrd import desktop
from opentetrd.desktop import SocksProxy
from opentetrd.phone_relay import handle as phone_handle
from opentetrd.protocol import MAGIC, ProtocolError, encode_request, read_request


async def virtual_internet(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    request = await reader.readuntil(b"\r\n\r\n")
    first_line = request.split(b"\r\n", 1)[0]
    body = b"virtual-phone-path:" + first_line
    writer.write(
        b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
        + str(len(body)).encode()
        + b"\r\n\r\n"
        + body
    )
    await writer.drain()
    writer.close()
    await writer.wait_closed()


class VirtualLabTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        # Several tests exercise rejection paths that log warnings by design.
        logging.disable(logging.CRITICAL)
        self.addCleanup(logging.disable, logging.NOTSET)
        self.internet = await asyncio.start_server(virtual_internet, "127.0.0.1", 0)
        self.target_port = self.internet.sockets[0].getsockname()[1]
        self.phone = await asyncio.start_server(phone_handle, "127.0.0.1", 0)
        self.phone_port = self.phone.sockets[0].getsockname()[1]
        proxy = SocksProxy("127.0.0.1", self.phone_port)
        self.desktop = await asyncio.start_server(proxy.handle, "127.0.0.1", 0)
        self.socks_port = self.desktop.sockets[0].getsockname()[1]
        # A port that was bound and released, so connecting to it is refused rather than filtered.
        spare = await asyncio.start_server(lambda r, w: None, "127.0.0.1", 0)
        self.closed_port = spare.sockets[0].getsockname()[1]
        spare.close()
        await spare.wait_closed()

    async def asyncTearDown(self) -> None:
        for server in (self.desktop, self.phone, self.internet):
            server.close()
            await server.wait_closed()

    async def test_full_tunnel(self) -> None:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.socks_port)
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        self.assertEqual(await reader.readexactly(2), b"\x05\x00")
        writer.write(
            b"\x05\x01\x00\x01"
            + b"\x7f\x00\x00\x01"
            + struct.pack("!H", self.target_port)
        )
        await writer.drain()
        reply = await reader.readexactly(10)
        self.assertEqual(reply[1], 0)
        writer.write(b"GET /proof HTTP/1.1\r\nHost: lab\r\nConnection: close\r\n\r\n")
        await writer.drain()
        response = await reader.read()
        self.assertIn(b"200 OK", response)
        self.assertIn(b"virtual-phone-path:GET /proof HTTP/1.1", response)
        writer.close()
        await writer.wait_closed()

    async def test_rejects_unsupported_socks_auth(self) -> None:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.socks_port)
        writer.write(b"\x05\x01\x02")
        await writer.drain()
        self.assertEqual(await reader.readexactly(2), b"\x05\xff")
        writer.close()
        await writer.wait_closed()

    async def _connect(self, request: bytes) -> tuple[asyncio.StreamReader, asyncio.StreamWriter, bytes]:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.socks_port)
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        self.assertEqual(await reader.readexactly(2), b"\x05\x00")
        writer.write(request)
        await writer.drain()
        return reader, writer, await reader.readexactly(10)

    async def test_tunnels_domain_names(self) -> None:
        """ATYP 3 travels desktop -> OTR1 -> relay; only the IPv4 form was covered before."""
        host = b"localhost"
        reader, writer, reply = await self._connect(
            b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", self.target_port)
        )
        self.assertEqual(reply[1], 0)
        writer.write(b"GET /by-name HTTP/1.1\r\nHost: lab\r\nConnection: close\r\n\r\n")
        await writer.drain()
        self.assertIn(b"virtual-phone-path:GET /by-name", await reader.read())
        writer.close()
        await writer.wait_closed()

    async def test_reports_failure_when_destination_refuses(self) -> None:
        """A rejected destination must produce exactly one SOCKS failure reply."""
        reader, writer, reply = await self._connect(
            b"\x05\x01\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", self.closed_port)
        )
        self.assertNotEqual(reply[1], 0)
        # Nothing may follow the failure reply; a second reply would corrupt the stream.
        self.assertEqual(await reader.read(), b"")
        writer.close()
        await writer.wait_closed()

    async def test_times_out_a_silent_client(self) -> None:
        """A client that connects and never speaks must not pin a task forever."""
        original = desktop.HANDSHAKE_TIMEOUT
        desktop.HANDSHAKE_TIMEOUT = 0.2
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", self.socks_port)
            self.assertEqual(await asyncio.wait_for(reader.read(), 5), desktop.SOCKS_FAILURE)
            writer.close()
            await writer.wait_closed()
        finally:
            desktop.HANDSHAKE_TIMEOUT = original

    async def test_relay_rejects_a_bad_magic_header(self) -> None:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.phone_port)
        writer.write(b"BAD!" + struct.pack("!BHH", 3, 80, 4) + b"host")
        await writer.drain()
        self.assertEqual(await reader.readexactly(1), b"\x01")
        writer.close()
        await writer.wait_closed()

    async def test_request_round_trips_every_address_type(self) -> None:
        for host in ("203.0.113.7", "2001:db8::1", "example.com"):
            with self.subTest(host=host):
                reader = asyncio.StreamReader()
                reader.feed_data(encode_request(host, 8443))
                reader.feed_eof()
                self.assertEqual(await read_request(reader), (host, 8443))

    def test_protocol_rejects_bad_port(self) -> None:
        with self.assertRaises(ProtocolError):
            encode_request("example.com", 0)

    def test_protocol_rejects_an_oversized_host(self) -> None:
        with self.assertRaises(ProtocolError):
            encode_request("a" * 64 + ".example.com", 443)

    def test_encoded_request_starts_with_the_magic(self) -> None:
        self.assertTrue(encode_request("example.com", 443).startswith(MAGIC))


if __name__ == "__main__":
    unittest.main()
