#!/usr/bin/env python3
"""Run current regressions; second-pass-results.json is historical audit evidence."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--xray',type=Path)
args=parser.parse_args()
environment=dict(os.environ)
if args.xray: environment['XRAY_TEST_BINARY']=str(args.xray.resolve())
raise SystemExit(subprocess.call([sys.executable,'-m','unittest','discover','-s','tests','-v'],
                                cwd=Path(__file__).resolve().parents[1],env=environment))
