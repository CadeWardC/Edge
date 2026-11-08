#!/usr/bin/env python3
"""Vanguard multiplayer relay. No dependencies (Python 3.8+).

    python3 relay.py [--port 8765]

Each device connects with a WebSocket to ws://<this computer>:<port>/<ROOM>. Every text message a client sends is
forwarded unchanged to the other clients in the same room. The game itself runs in lockstep on the devices; this
server never looks inside the messages, so it works for any number of rooms and any game version.

When a client drops, the others get {"leave":{"clientId":""}} so the game can tell its players.
To put it on the internet, run it on any small VPS (open the port) or behind a TLS proxy for wss://.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import struct

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
rooms = {}  # room -> set of writers


def frame(payload: bytes, opcode: int = 1) -> bytes:
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + payload


async def read_frame(reader):
    """Returns (opcode, payload) with fragments joined, or None when the socket closes."""
    message, first_op = b"", None
    while True:
        b1, b2 = await reader.readexactly(2)
        fin, op = b1 & 0x80, b1 & 0x0F
        masked, n = b2 & 0x80, b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", await reader.readexactly(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", await reader.readexactly(8))[0]
        if n > 1 << 22:
            return None
        mask = await reader.readexactly(4) if masked else b"\0\0\0\0"
        data = bytearray(await reader.readexactly(n))
        for i in range(n):
            data[i] ^= mask[i % 4]
        if op >= 8:  # control frames can arrive between fragments
            return op, bytes(data)
        if first_op is None:
            first_op = op
        message += data
        if fin:
            return first_op, message


async def handle(reader, writer):
    room = None
    try:
        request = await reader.readuntil(b"\r\n\r\n")
        lines = request.decode("latin-1").split("\r\n")
        path = lines[0].split(" ")[1] if len(lines[0].split(" ")) > 1 else "/"
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        key = headers.get("sec-websocket-key")
        if not key:
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nVanguard relay is running.\n")
            await writer.drain()
            return
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        await writer.drain()
        room = "".join(c for c in path.strip("/").upper() if c.isalnum())[:16] or "LOBBY"
        rooms.setdefault(room, set()).add(writer)
        print(f"+ {room}: {len(rooms[room])} connected")
        while True:
            got = await read_frame(reader)
            if got is None:
                break
            op, data = got
            if op == 8:
                break
            if op == 9:  # ping
                writer.write(frame(data, 10))
                continue
            if op in (1, 2):
                out = frame(data, op)
                for other in list(rooms.get(room, ())):
                    if other is not writer:
                        other.write(out)
                await asyncio.gather(*(o.drain() for o in rooms.get(room, ()) if o is not writer), return_exceptions=True)
    except (asyncio.IncompleteReadError, ConnectionError, asyncio.LimitOverrunError, ValueError):
        pass
    finally:
        if room and writer in rooms.get(room, ()):
            rooms[room].discard(writer)
            print(f"- {room}: {len(rooms[room])} connected")
            bye = frame(json.dumps({"leave": {"clientId": ""}}).encode())
            for other in rooms[room]:
                other.write(bye)
            if not rooms[room]:
                del rooms[room]
        writer.close()


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    server = await asyncio.start_server(handle, args.host, args.port)
    print(f"Vanguard relay listening on ws://{args.host}:{args.port}/<ROOM>")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
