"""End-to-end lab: app -> SOCKS -> virtual phone -> virtual Internet server."""

from __future__ import annotations

import asyncio
import struct
import unittest

from opentetrd.desktop import SocksProxy
from opentetrd.phone_relay import handle as phone_handle
from opentetrd.protocol import ProtocolError, encode_request


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
        self.internet = await asyncio.start_server(virtual_internet, "127.0.0.1", 0)
        self.target_port = self.internet.sockets[0].getsockname()[1]
        self.phone = await asyncio.start_server(phone_handle, "127.0.0.1", 0)
        phone_port = self.phone.sockets[0].getsockname()[1]
        proxy = SocksProxy("127.0.0.1", phone_port)
        self.desktop = await asyncio.start_server(proxy.handle, "127.0.0.1", 0)
        self.socks_port = self.desktop.sockets[0].getsockname()[1]

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

    def test_protocol_rejects_bad_port(self) -> None:
        with self.assertRaises(ProtocolError):
            encode_request("example.com", 0)


if __name__ == "__main__":
    unittest.main()
