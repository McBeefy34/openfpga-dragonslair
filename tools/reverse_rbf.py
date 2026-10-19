#!/usr/bin/env python3
"""Bit-reverse every byte of a Quartus .rbf into the .rbf_r the Pocket loads.

    python3 tools/reverse_rbf.py src/fpga/output_files/ap_core.rbf bitstream.rbf_r
"""
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)

table = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))
with open(sys.argv[1], "rb") as f:
    data = f.read()
with open(sys.argv[2], "wb") as f:
    f.write(data.translate(table))
print(f"wrote {sys.argv[2]} ({len(data)} bytes)")
