#!/usr/bin/env python3
"""Build dlair.rom for the Pocket from a MAME Dragon's Lair ROM set.

    python3 tools/make_rom.py dlair.zip            -> dlair.rom
    python3 tools/make_rom.py path/to/dlair/ -o /Volumes/POCKET/Assets/dragonslair/common/dlair.rom

Accepts a MAME zip or a folder of the individual ROM files. CRCs are checked
against MAME's dlair.cpp so a wrong or bad dump is caught before it reaches
the Pocket. Supported sets: dlair (Rev F2, default) and dlaird (Rev D).
"""
import argparse
import os
import sys
import zipfile
import zlib

# set name -> list of (filename, crc32), loaded in order from 0x0000, 8 KB each
SETS = {
    "dlair":  [("dl_f2_u1.bin", 0xf5ea3b9d), ("dl_f2_u2.bin", 0xdcc1dff2),
               ("dl_f2_u3.bin", 0xab514e5b), ("dl_f2_u4.bin", 0xf5ec23d2)],
    "dlaird": [("dl_d_u1.bin", 0x0b5ab120), ("dl_d_u2.bin", 0x93ebfffb),
               ("dl_d_u3.bin", 0x22e6591f), ("dl_d_u4.bin", 0x5f7212cb),
               ("dl_d_u5.bin", 0x2b469c89)],
}
# Other LD-V1000 revisions (dlairf, dlaire): add names + CRCs from MAME's dlair.cpp.

ROM_SIZE = 0x2000


def read_files(source):
    """Return {lowercase filename: bytes} from a zip or a directory."""
    files = {}
    if os.path.isdir(source):
        for name in os.listdir(source):
            path = os.path.join(source, name)
            if os.path.isfile(path):
                with open(path, "rb") as f:
                    files[name.lower()] = f.read()
    else:
        with zipfile.ZipFile(source) as z:
            for info in z.infolist():
                files[os.path.basename(info.filename).lower()] = z.read(info)
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="MAME zip or folder")
    ap.add_argument("-s", "--set", default="dlair", choices=sorted(SETS), help="ROM set (default dlair = Rev F2)")
    ap.add_argument("-o", "--output", default="dlair.rom", help="output file (default dlair.rom)")
    ap.add_argument("--no-crc", action="store_true", help="skip CRC checks")
    args = ap.parse_args()

    files = read_files(args.source)
    out = bytearray()
    ok = True
    for name, crc in SETS[args.set]:
        data = files.get(name.lower())
        if data is None:
            print(f"missing: {name}")
            ok = False
            continue
        if len(data) != ROM_SIZE:
            print(f"wrong size: {name} is {len(data)} bytes, expected {ROM_SIZE}")
            ok = False
        got = zlib.crc32(data) & 0xFFFFFFFF
        if got != crc and not args.no_crc:
            print(f"bad CRC: {name} is {got:08x}, expected {crc:08x}")
            ok = False
        out += data
    if not ok:
        sys.exit("dlair.rom not written")
    with open(args.output, "wb") as f:
        f.write(out)
    print(f"wrote {args.output} ({len(out)} bytes, set {args.set})")


if __name__ == "__main__":
    main()
