"""SPI1 validation and bounded queue. Input fields must never be logged."""
import asyncio
import struct
import time
from collections import deque
from dataclasses import dataclass

RECORD = struct.Struct('!4sBBHIiii')
CAPABILITY = dict(version=1, enabled=True, wire='SPI1', recordBytes=24,
                  maxEventsPerSecond=240, heartbeatMS=500, leaseMS=2000)


@dataclass(frozen=True, repr=False)
class Event:
    kind: int
    flags: int
    sequence: int
    a: int
    b: int
    c: int

    def wire(self):
        return RECORD.pack(b'SPI1', self.kind, self.flags, 0, self.sequence, self.a, self.b, self.c)


def supported_usage(value):
    return 0x04 <= value <= 0x45 or 0x49 <= value <= 0x65 or 0xE0 <= value <= 0xE7


def decode(record):
    if len(record) != RECORD.size:
        raise ValueError('Invalid input record size')
    magic, kind, flags, reserved, sequence, a, b, c = RECORD.unpack(record)
    if magic != b'SPI1' or reserved or not sequence or not 1 <= kind <= 7:
        raise ValueError('Invalid input record header')
    allowed_flags = 1 if kind == 2 else 3 if kind == 4 else 0
    if flags & ~allowed_flags:
        raise ValueError('Invalid input flags')
    if kind in (1, 2):
        if not (0 <= a <= 65535 and 0 <= b <= 65535) or (c != 0 if kind == 1 else c not in (1, 2, 3)):
            raise ValueError('Invalid pointer event')
    elif kind == 3:
        if abs(a) > 1200 or abs(b) > 1200 or c:
            raise ValueError('Invalid wheel event')
    elif kind == 4:
        if not supported_usage(a) or b or c or flags == 2:
            raise ValueError('Invalid keyboard event')
    elif a or b or c:
        raise ValueError('Invalid control event')
    return Event(kind, flags, sequence, a, b, c)


class Gate:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.sequence = 0
        self.accepted = 0
        self.active = False
        self.last = self.refill = clock()
        self.tokens = 120.0

    def accept(self, event):
        now = self.clock()
        self.tokens = min(120.0, self.tokens + (now-self.refill)*240)
        self.refill = now
        if self.tokens < 1:
            raise ValueError('Input rate exceeded')
        self.tokens -= 1
        if (not self.sequence and event.sequence != 1) or event.sequence <= self.sequence:
            raise ValueError('Invalid input sequence')
        self.sequence = event.sequence
        if self.active and now-self.last >= 2:
            raise TimeoutError('Input lease expired')
        if event.kind == 5:
            self.active = True
        elif event.kind == 6:
            self.active = False
        elif event.kind != 7 and not self.active:
            raise ValueError('Input control is inactive')
        self.last = now
        self.accepted += 1

    def expired(self):
        return self.active and self.clock()-self.last >= 2


class EventQueue:
    def __init__(self):
        self.events = deque()
        self.changed = asyncio.Event()

    def put(self, event):
        # Explicit control-stop cancels undelivered actions before releasing held
        # state. Otherwise only adjacent movement is replaceable; barriers stay.
        if event.kind == 6:
            self.events.clear()
        if event.kind == 1 and self.events and self.events[-1].kind == 1:
            self.events[-1] = event
        else:
            if len(self.events) >= 128:
                raise ValueError('Input queue exceeded')
            self.events.append(event)
        self.changed.set()

    async def get(self):
        while not self.events:
            self.changed.clear()
            await self.changed.wait()
        return self.events.popleft()
