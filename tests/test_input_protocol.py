import asyncio
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from input_protocol import Event, EventQueue, Gate, decode, text_negotiated


class InputProtocolTests(unittest.TestCase):
    def test_text_scalar_and_explicit_negotiation(self):
        for offer in (None, {}, {'textVersion':True}, {'textVersion':1.0}, {'textVersion':'1'}, {'textVersion':2}):
            self.assertFalse(text_negotiated(offer))
        self.assertTrue(text_negotiated({'textVersion':1}))
        for scalar in (0x20,0x7E,0xA0,0xD7FF,0xE000,0xFFFF,0x10000,0x1F642,0x10FFFF):
            wire=Event(8,0,1,scalar,0,0).wire()
            self.assertEqual(decode(wire,text_enabled=True).a,scalar)
            with self.assertRaises(ValueError):decode(wire)
        for scalar in (-1,0,0x1F,0x7F,0x9F,0xD800,0xDFFF,0x110000):
            with self.assertRaises(ValueError):decode(Event(8,0,1,scalar,0,0).wire(),text_enabled=True)
        for event in (Event(8,1,1,0x41,0,0),Event(8,0,1,0x41,1,0),Event(8,0,1,0x41,0,1)):
            with self.assertRaises(ValueError):decode(event.wire(),text_enabled=True)

    def test_text_is_ordered_bounded_and_requires_control(self):
        gate=Gate(lambda:0.0)
        with self.assertRaises(ValueError):gate.accept(Event(8,0,1,0x41,0,0))
        queue=EventQueue()
        for sequence in range(1,129):queue.put(Event(8,0,sequence,0x41,0,0))
        self.assertEqual(len(queue.events),128)
        with self.assertRaises(ValueError):queue.put(Event(8,0,129,0x41,0,0))
        queue.put(Event(6,0,130,0,0,0))
        self.assertEqual([e.kind for e in queue.events],[6])

    def test_gate_and_monotonic_sequence(self):
        now = [0.0]
        gate = Gate(lambda:now[0])
        with self.assertRaises(ValueError):
            gate.accept(Event(1, 0, 1, 0, 0, 0))
        gate.accept(Event(5, 0, 2, 0, 0, 0))
        gate.accept(Event(1, 0, 3, 65535, 0, 0))
        with self.assertRaises(ValueError):
            gate.accept(Event(1, 0, 3, 0, 0, 0))
        now[0] = 2.0
        self.assertTrue(gate.expired())
        with self.assertRaises(TimeoutError):
            gate.accept(Event(7, 0, 4, 0, 0, 0))

    def test_move_coalescing_preserves_click_barrier(self):
        queue = EventQueue()
        for event in [Event(1,0,1,10,10,0), Event(1,0,2,20,20,0), Event(2,1,3,20,20,1), Event(1,0,4,30,30,0)]:
            queue.put(event)
        self.assertEqual([e.sequence for e in queue.events], [2,3,4])
        queue.put(Event(6,0,5,0,0,0))
        self.assertEqual([e.kind for e in queue.events], [6])

    def test_ordered_queue_overflow_fails_closed(self):
        queue = EventQueue()
        for sequence in range(1,129):
            queue.put(Event(7,0,sequence,0,0,0))
        with self.assertRaises(ValueError):
            queue.put(Event(7,0,129,0,0,0))

    def test_token_bucket(self):
        gate = Gate(lambda:0.0)
        for sequence in range(1,121):
            gate.accept(Event(7,0,sequence,0,0,0))
        with self.assertRaises(ValueError):
            gate.accept(Event(7,0,121,0,0,0))

    def test_fixed_wire_and_malformed_fields(self):
        event = Event(3,0,1,-120,120,0)
        self.assertEqual(len(event.wire()),24)
        self.assertEqual(decode(event.wire()),event)
        malformed = [Event(1,0,1,-1,0,0), Event(2,1,1,0,0,4), Event(3,0,1,-2147483648,0,0),
                     Event(4,2,1,4,0,0), Event(4,1,1,0x46,0,0), Event(5,0,1,1,0,0)]
        for value in malformed:
            with self.assertRaises(ValueError):
                decode(value.wire())
        reserved = bytearray(event.wire()); reserved[6] = 1
        with self.assertRaises(ValueError):
            decode(reserved)

    def test_queue_wakes_waiter(self):
        async def scenario():
            queue = EventQueue()
            waiter = asyncio.create_task(queue.get())
            await asyncio.sleep(0)
            queue.put(Event(7,0,1,0,0,0))
            self.assertEqual((await waiter).sequence,1)
        asyncio.run(scenario())


if __name__ == '__main__':
    unittest.main()
