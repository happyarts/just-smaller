#!/usr/bin/env python3
"""Keeps a corpus lean: files of the same kind test the same thing.

Removes exact duplicates anywhere, and within a folder keeps at most KEEP
JPEGs or PNGs of the same kind — the same encoder settings (frame type,
sampling, quantization tables), the same chunks or segments, and a size
within a factor of two. Folders made on purpose (rare codings, multi-image,
files that must stay unchanged) keep every kind; the edge cases are left
alone entirely (the same image under other names, on purpose). With
--dry-run it only lists what it would remove.

usage: dedup.py [--dry-run] FOLDER
"""
import collections, hashlib, os, struct, sys

KEEP = 3
EXEMPT = {"edge", "rare-jpeg", "multi-jpeg", "real-multi-jpeg", "unchanged", "real-unchanged"}

def jpeg_kind(b):
    tables, frame, segments, i = b"", None, set(), 2
    try:
        while i + 4 <= len(b):
            while b[i + 1] == 0xFF: i += 1
            m = b[i + 1]
            if m == 0x01 or 0xD0 <= m <= 0xD8: i += 2; continue
            length = struct.unpack(">H", b[i + 2:i + 4])[0]
            p = b[i + 4:i + 2 + length]
            if m == 0xDB: tables += p
            elif 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC): frame = (m, p[0], p[7:6 + 3 * p[5]:3])
            elif 0xE0 <= m <= 0xEF or m == 0xFE: segments.add((m, p[:4]))
            if m == 0xDA: break
            i += 2 + length
    except (IndexError, struct.error):
        return None
    return ("jpeg", frame, hashlib.md5(tables).digest(), frozenset(segments))

def png_kind(b):
    try:
        header, chunks, i = b[16:29], set(), 8
        while i + 8 <= len(b):
            length = struct.unpack(">I", b[i:i + 4])[0]
            chunks.add(b[i + 4:i + 8]); i += 12 + length
    except struct.error:
        return None
    return ("png", header[8:13], frozenset(chunks))

def kind(b):
    k = jpeg_kind(b) if b[:3] == b"\xff\xd8\xff" else png_kind(b) if b[:4] == b"\x89PNG" else None
    return k and k + (len(b).bit_length(),)

dry = "--dry-run" in sys.argv
root = [a for a in sys.argv[1:] if a != "--dry-run"][0]
seen, groups, remove = {}, collections.defaultdict(list), []
for d, dirs, files in sorted(os.walk(root)):
    dirs.sort()
    for f in sorted(files):
        if f.startswith("."): continue
        p = os.path.join(d, f)
        b = open(p, "rb").read()
        folder = os.path.relpath(d, root)
        if folder.split(os.sep)[0] == "edge": continue  # same image under other names, on purpose
        digest = hashlib.sha256(b).digest()
        if digest in seen:
            remove.append((p, "same as " + os.path.relpath(seen[digest], root))); continue
        seen[digest] = p
        k = kind(b)
        if folder.split(os.sep)[0] in EXEMPT or k is None: continue
        groups[(folder, k)].append(p)
for (folder, _), paths in groups.items():
    remove += [(p, f"{len(paths)} of a kind in {folder}") for p in paths[KEEP:]]
for p, why in sorted(remove):
    print(f"{'would remove' if dry else 'removed'} {os.path.relpath(p, root)}  ({why})")
    if not dry: os.remove(p)
