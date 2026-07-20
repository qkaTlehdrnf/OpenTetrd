"""Small, deliberately bounded wire protocol shared by both endpoints."""

from __future__ import annotations

import asyncio
import ipaddress
import struct

MAGIC = b"OTR1"
MAX_HOST_BYTES = 253
REQUEST_HEADER = struct.Struct("!4sBHH")

ATYP_IPV4 = 1
ATYP_DOMAIN = 3
ATYP_IPV6 = 4

STATUS_OK = 0
STATUS_BAD_REQUEST = 1
STATUS_CONNECT_FAILED = 2


class ProtocolError(ValueError):
    pass


def encode_request(host: str, port: int) -> bytes:
    if not 1 <= port <= 65535:
        raise ProtocolError("port must be between 1 and 65535")
    try:
        ip = ipaddress.ip_address(host)
        atyp = ATYP_IPV4 if ip.version == 4 else ATYP_IPV6
        host_bytes = ip.packed
    except ValueError:
        atyp = ATYP_DOMAIN
        try:
            host_bytes = host.encode("idna")
        except UnicodeError as exc:
            raise ProtocolError("invalid host name") from exc
    if not host_bytes or len(host_bytes) > MAX_HOST_BYTES:
        raise ProtocolError("host name is empty or too long")
    return REQUEST_HEADER.pack(MAGIC, atyp, port, len(host_bytes)) + host_bytes


async def read_request(reader: asyncio.StreamReader) -> tuple[str, int]:
    raw = await reader.readexactly(REQUEST_HEADER.size)
    magic, atyp, port, host_len = REQUEST_HEADER.unpack(raw)
    if magic != MAGIC or not 1 <= host_len <= MAX_HOST_BYTES or port == 0:
        raise ProtocolError("invalid relay request header")
    host_bytes = await reader.readexactly(host_len)
    try:
        if atyp == ATYP_IPV4 and host_len == 4:
            host = str(ipaddress.IPv4Address(host_bytes))
        elif atyp == ATYP_IPV6 and host_len == 16:
            host = str(ipaddress.IPv6Address(host_bytes))
        elif atyp == ATYP_DOMAIN:
            host = host_bytes.decode("ascii")
        else:
            raise ProtocolError("invalid address type or length")
    except (UnicodeError, ipaddress.AddressValueError) as exc:
        raise ProtocolError("invalid relay destination") from exc
    return host, port


async def bridge(
    left_reader: asyncio.StreamReader,
    left_writer: asyncio.StreamWriter,
    right_reader: asyncio.StreamReader,
    right_writer: asyncio.StreamWriter,
) -> None:
    async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while data := await reader.read(65536):
                writer.write(data)
                await writer.drain()
            if writer.can_write_eof():
                writer.write_eof()
        except (ConnectionError, asyncio.CancelledError):
            pass

    tasks = [
        asyncio.create_task(pump(left_reader, right_writer)),
        asyncio.create_task(pump(right_reader, left_writer)),
    ]
    try:
        await asyncio.gather(*tasks)
    finally:
        for task in tasks:
            task.cancel()
        left_writer.close()
        right_writer.close()
        await asyncio.gather(
            left_writer.wait_closed(), right_writer.wait_closed(),
            return_exceptions=True,
        )
