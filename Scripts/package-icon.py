#!/usr/bin/env python3
"""Assemble PNG icon representations into a standard ICNS container."""
from pathlib import Path
import struct
import sys

source, target = map(Path, sys.argv[1:])
representations = [
    (b'icp4', 'icon_16x16.png'), (b'icp5', 'icon_32x32.png'),
    (b'icp6', 'icon_32x32@2x.png'), (b'ic07', 'icon_128x128.png'),
    (b'ic08', 'icon_256x256.png'), (b'ic09', 'icon_512x512.png'),
    (b'ic10', 'icon_512x512@2x.png'),
]
chunks = []
for kind, filename in representations:
    data = (source / filename).read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError(f'Invalid PNG representation: {filename}')
    chunks.append(kind + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
target.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
