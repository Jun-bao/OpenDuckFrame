#!/usr/bin/env python3
"""Reproduce the frozen ODF-VFI four-stage weights from pinned RIFE 4.25."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]


def derive(source: bytes, specification: dict) -> bytes:
    if hashlib.sha256(source).hexdigest() != specification['source_sha256']:
        raise ValueError('Source is not the pinned original RIFE 4.25 weights')
    magic, version, length = struct.unpack_from('<4sII', source)
    if magic != b'RMW1' or version != 1:
        raise ValueError('Expected original RMW1 container')
    header = json.loads(source[12:12 + length])
    header.update(model=specification['graph_id'], graph_id=specification['graph_id'], mask_update='accumulate')
    header['ifblock_channels'] = header['ifblock_channels'][:4]
    header['scale_list'] = header['scale_list'][:4]
    header['tensors'] = [t for t in header['tensors'] if not t['name'].startswith('block4.')]
    encoded = json.dumps(header, sort_keys=True).encode('utf-8')
    prefix = struct.pack('<4sII', b'RMW1', 2, len(encoded)) + encoded
    payload_start = (12 + length + 15) // 16 * 16
    payload_bytes = sum(t['size'] for t in header['tensors'])
    output = prefix + bytes((-len(prefix)) % 16) + source[payload_start:payload_start + payload_bytes]
    if hashlib.sha256(output).hexdigest() != specification['sha256']:
        raise ValueError('Derived weights differ from the evaluated frozen four-stage candidate')
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    specification = json.loads((ROOT / 'ThirdParty/rife-metal/production-model.json').read_text())
    output = derive(args.source.read_bytes(), specification)
    args.output.write_bytes(output)
    print(json.dumps({'model': specification['name'], 'graph_id': specification['graph_id'],
                      'sha256': specification['sha256'], 'bytes': len(output)}))


if __name__ == '__main__':
    main()
