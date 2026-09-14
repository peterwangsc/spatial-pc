"""Opt-in real Windows input-helper idle test. Never writes any input records."""
import argparse
import asyncio
import hashlib
import json
from pathlib import Path
import subprocess
import time


async def run(binary,seconds):
    digest=hashlib.sha256(binary.read_bytes()).hexdigest()
    child=await asyncio.create_subprocess_exec(str(binary),'--width','2','--height','2',
        '--enable-text','--until-owner-exits',stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        ready=json.loads(await asyncio.wait_for(child.stdout.readline(),5))
        assert ready==dict(ready=True,width=2,height=2)
        started=time.monotonic()
        print(json.dumps(dict(stage='idle-start',nativeSHA256=digest,recordsSent=0)),flush=True)
        while time.monotonic()-started<seconds:
            await asyncio.sleep(min(10,seconds-(time.monotonic()-started)))
            assert child.returncode is None,'Native helper ended while idle'
        elapsed=time.monotonic()-started
        child.stdin.close() # EOF only. No Start, HID, text or pointer records.
        assert await asyncio.wait_for(child.wait(),3)==0
        print(json.dumps(dict(stage='pass',idleSeconds=round(elapsed,3),nativeSHA256=digest,
                              recordsSent=0,eofExit=0)),flush=True)
    finally:
        if child.returncode is None:
            child.stdin.close()
            try:await asyncio.wait_for(child.wait(),3)
            except TimeoutError:child.kill();await asyncio.wait_for(child.wait(),2)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--seconds',type=int,default=660)
    args=parser.parse_args()
    if not 601<=args.seconds<=900:parser.error('Use a bounded 601–900 second observation')
    asyncio.run(run(args.binary.resolve(),args.seconds))
