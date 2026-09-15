"""Strict, bounded v1 control records. This is not Apple's little-endian wire."""
import asyncio
import json
import re
import struct

ALPN = 'spatialpc-control/1'
PORT = 47994
MAX_RECORD = 8192


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate control field')
        result[key] = value
    return result


def _invalid_number(_value):
    raise ValueError('Invalid control number')


def decode(payload, expected_id):
    if not 1 <= len(payload) <= MAX_RECORD:
        raise ValueError('Invalid control length')
    value = json.loads(payload.decode('utf-8'), object_pairs_hook=_unique,
                       parse_float=_invalid_number, parse_constant=_invalid_number)
    def depth(item, level=1):
        if level > 6:
            raise ValueError('Control nesting limit')
        if isinstance(item, dict):
            for child in item.values(): depth(child, level+1)
        elif isinstance(item, list):
            for child in item: depth(child, level+1)
    depth(value)
    if not isinstance(value, dict) or set(value) != {'version', 'type', 'id', 'operation', 'parameters'}:
        raise ValueError('Invalid control request')
    if type(value['version']) is not int or value['version'] != 1 or value['type'] != 'request':
        raise ValueError('Invalid control version')
    if type(value['id']) is not int or value['id'] != expected_id or not 1 <= expected_id <= 4096:
        raise ValueError('Invalid control sequence')
    operation, parameters = value['operation'], value['parameters']
    if not isinstance(operation, str) or not re.fullmatch(r'[A-Za-z.]{1,48}', operation) or not isinstance(parameters, dict):
        raise ValueError('Invalid control operation')
    fields = {'capabilities': set(), 'heartbeat': set(), 'focus.requestPermission': set(),
              'focus.prepare': {'intent'}, 'focus.stop': {'sessionId', 'returnToDesktop'}}
    if operation in fields and set(parameters) != fields[operation]:
        raise ValueError('Invalid control parameters')
    if operation not in fields and parameters:
        raise ValueError('Unknown control parameters')
    if operation == 'focus.prepare' and parameters['intent'] not in ('setup', 'enter'):
        raise ValueError('Invalid Focus intent')
    if operation == 'focus.stop':
        session = parameters['sessionId']
        if (session is not None and (not isinstance(session, str) or not re.fullmatch('[0-9a-f]{32}', session))) or type(parameters['returnToDesktop']) is not bool:
            raise ValueError('Invalid Focus stop')
    return value


async def read(reader, expected_id):
    # An idle peer is bounded separately; once the first byte arrives the whole
    # record, including header, has five seconds. Slow partial headers count.
    first = await asyncio.wait_for(reader.readexactly(1), 3 if expected_id == 1 else 15)
    async with asyncio.timeout(5):
        size = struct.unpack('>I', first + await reader.readexactly(3))[0]
        if not 1 <= size <= MAX_RECORD:
            raise ValueError('Invalid control length')
        return decode(await reader.readexactly(size), expected_id)


def encode(record):
    payload = json.dumps(record, separators=(',', ':'), ensure_ascii=True, allow_nan=False).encode('ascii')
    if not 1 <= len(payload) <= MAX_RECORD:
        raise ValueError('Invalid control response length')
    return struct.pack('>I', len(payload)) + payload
