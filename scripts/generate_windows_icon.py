"""Package the shared artwork as a Windows multi-size ICO (build tooling only).

Requires Pillow; Windows application/installer builds use the committed ICO and
do not require this script or Pillow. No artwork or branding is changed.
"""
from pathlib import Path
import argparse
from PIL import Image

parser=argparse.ArgumentParser()
parser.add_argument('source',nargs='?',default='design/app-icon.png')
args=parser.parse_args()
destination=Path(__file__).resolve().parents[1]/'windows'/'ui'/'SpatialPC.ico'
with Image.open(args.source) as source:
    source.save(destination,format='ICO',sizes=[(size,size) for size in (16,24,32,48,64,128,256)])
