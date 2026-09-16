#!/usr/bin/env python3
"""Convert the existing approved voice tensors to the CosyVoice C++ GGUF format."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'ios/Runner/VoiceAssets/cosyvoice3-lj025-0076.json'
SOURCE_SHA256 = '58a6730ed47b9d09cdf8f59b44db4aa5f1733e39f1ad52bb6d0d7976449a1284'


def string(value):
    data = value.encode('utf-8')
    return struct.pack('<Q', len(data)) + data


def convert(source=SOURCE):
    raw = source.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('Voice preset checksum mismatch; do not silently replace the voice')
    profile = json.loads(raw)
    frames = profile['featureFrames']
    embedding, tokens, features = (profile[key] for key in ('speakerEmbedding', 'promptTokens', 'promptFeatures'))
    if len(embedding) != 192 or len(features) != frames * 80 or not all(map(math.isfinite, embedding + features)):
        raise ValueError('Invalid conditioning tensors')
    count = min(frames // 2, len(tokens))
    kept_frames = count * 2
    if count < 1:
        raise ValueError('Empty voice conditioning')
    # The Swift preset is channel-major; C++ expects time-major mel frames.
    mel = [features[channel * frames + frame] for frame in range(kept_frames) for channel in range(80)]
    text = profile['transcript'].encode('utf-8')
    tensors = [
        ('feat', [80, kept_frames], 0, struct.pack(f'<{len(mel)}f', *mel)),
        ('embedding', [192, 1], 0, struct.pack('<192f', *embedding)),
        ('tokens', [count], 26, struct.pack(f'<{count}i', *tokens[:count])),
        ('text', [len(text)], 24, text),
    ]
    header = b'GGUF' + struct.pack('<IQQ', 3, len(tensors), 1)
    header += string('general.alignment') + struct.pack('<II', 4, 32)
    data = bytearray()
    for name, dimensions, kind, payload in tensors:
        while len(data) % 32:
            data.append(0)
        header += string(name) + struct.pack('<I', len(dimensions))
        header += struct.pack(f'<{len(dimensions)}Q', *dimensions)
        header += struct.pack('<IQ', kind, len(data))
        data.extend(payload)
    header += bytes((-len(header)) % 32)
    return header + data


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/android-native/phrayo-lj025.gguf')
    args = parser.parse_args()
    payload = convert()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(payload)
    print(f'{args.output}: {len(payload)} bytes, sha256={hashlib.sha256(payload).hexdigest()}')
