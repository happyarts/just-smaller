#!/usr/bin/env python3
"""A second reader of Google's XMP in JPEGs, independent of the engine's
GoogleXMP (other language, expat instead of libxml2): the container
directory (Semantic, Mime, Length, Padding per item) and the motion photo
mark. One JSON object per file on stdout:

    {"file": ..., "unreadable": bool, "directories": [[[semantic, mime, length, padding], ...]],
     "depth": [is the directory Dynamic Depth's], "motion": bool,
     "microVideoOffset": an older motion photo's video offset or null,
     "after": bytes after the first image, "lists": one directory lists more than the photo}

usage: google-xmp.py <jpeg>...
"""
import json, re, sys
import xml.etree.ElementTree as ET

RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
CONTAINER = ["http://ns.google.com/photos/1.0/container/", "http://ns.google.com/photos/dd/1.0/container/"]
ITEM = ["http://ns.google.com/photos/1.0/container/item/", "http://ns.google.com/photos/dd/1.0/item/"]
CAMERA = "http://ns.google.com/photos/1.0/camera/"
XMP = b"http://ns.adobe.com/xap/1.0/\0"
EXTENDED = b"http://ns.adobe.com/xmp/extension/\0"


def image_end(b, i):
    """Where the JPEG that starts at i ends (after its EOI), walking its
    segments and entropy-coded data marker by marker; None without one."""
    if b[i:i + 2] != b"\xff\xd8": return None
    i += 2
    while i + 2 <= len(b):
        if b[i] != 0xFF: i += 1; continue
        m = b[i + 1]
        if m == 0xD9: return i + 2
        if m == 0xFF: i += 1; continue  # a fill byte
        if m == 0x00 or 0xD0 <= m <= 0xD7: i += 2; continue  # stuffing, restart marker
        i += 2 + int.from_bytes(b[i + 2:i + 4], "big")
    return None


def segments(b):
    """The first image's APPn segments up to its first scan, and where that image ends."""
    out, i = [], 2
    while i + 4 <= len(b) and b[i] == 0xFF:
        m = b[i + 1]
        if m == 0xFF: i += 1; continue
        if m == 0xDA: break
        n = int.from_bytes(b[i + 2:i + 4], "big")
        out.append((m, b[i + 4:i + 2 + n]))
        i += 2 + n
    return out, image_end(b, 0)


def name(tag):
    ns, _, local = tag[1:].partition("}") if tag.startswith("{") else ("", "", tag)
    return ns, local


def document(p):
    end = p.rfind(b"<?xpacket end=")
    if end >= 0 and p.find(b"?>", end) >= 0: return p[:p.find(b"?>", end) + 2]
    return p.rstrip(b"\0")


def read(packet):
    root = ET.fromstring(document(packet))
    directories, depth, motion, offset = [], [], False, None
    for el in root.iter():
        for key, value in list(el.attrib.items()) + [(el.tag, el.text or "")]:
            ns, local = name(key)
            if ns == CAMERA and local in ("MotionPhoto", "MicroVideo") and value.strip() == "1": motion = True
            if ns == CAMERA and local == "MicroVideoOffset":
                if not re.fullmatch(r"\+?[0-9]+", value.strip()): raise ValueError("offset")
                offset = int(value.strip())
        ns, local = name(el.tag)
        if ns in CONTAINER and local == "Directory":
            items = []
            for lst in el:  # rdf:Seq or rdf:Bag
                for entry in lst:  # rdf:li, or a Container:Item straight in the list
                    item = [None, None, 0, 0]
                    for sub in entry.iter():
                        props = list(sub.attrib.items())
                        if len(sub) == 0: props.append((sub.tag, sub.text or ""))
                        for key, value in props:
                            kns, klocal = name(key)
                            if kns not in ITEM: continue
                            value = value.strip()
                            if klocal in ("Length", "Padding"):
                                if not re.fullmatch(r"\+?[0-9]+", value): raise ValueError("length")
                                item[2 if klocal == "Length" else 3] = int(value)
                            elif klocal == "Semantic": item[0] = value
                            elif klocal == "Mime": item[1] = value
                    items.append(item)
            if not items: raise ValueError("empty directory")
            directories.append(items)
            depth.append(ns == CONTAINER[1])
    return directories, depth, motion, offset


def wanted(p):
    return any(ns.encode() in p for ns in CONTAINER + [CAMERA])


def opinion(path):
    """What this reader says about one file (the JSON object above)."""
    b = open(path, "rb").read()
    segs, end = segments(b)
    main = [p[len(XMP):] for m, p in segs if m == 0xE1 and p.startswith(XMP)]
    chunks = [p[len(EXTENDED):] for m, p in segs if m == 0xE1 and p.startswith(EXTENDED)]
    result = {"file": path, "unreadable": False, "directories": [], "depth": [], "motion": False, "microVideoOffset": None,
              "after": len(b) - end if end else None}
    try:
        packets = [p for p in main if wanted(p)]
        if any(wanted(c) for c in chunks):
            # The part whose GUID the main packet names (as an attribute or an element).
            mine = [c for c in chunks if main and len(c) >= 40 and c[:32] in main[0]]
            if not mine: raise ValueError("extended")
            total = int.from_bytes(mine[0][32:36], "big")
            whole = bytearray(total)
            for c in mine: whole[int.from_bytes(c[36:40], "big"):int.from_bytes(c[36:40], "big") + len(c) - 40] = c[40:]
            if sum(len(c) - 40 for c in mine) != total: raise ValueError("extended")
            packets.append(bytes(whole))
        for p in packets:
            d, depth, motion, offset = read(p)
            result["directories"] += d
            result["depth"] += depth
            result["motion"] = result["motion"] or motion
            if offset is not None:
                if result["microVideoOffset"] not in (None, offset): raise ValueError("offsets differ")
                result["microVideoOffset"] = offset
    except (ET.ParseError, ValueError):
        result = {**result, "unreadable": True, "directories": [], "depth": [], "motion": False, "microVideoOffset": None}
    result["lists"] = sum(len(d) > 1 for d in result["directories"]) == 1
    return result


def placed(path):
    """Where the items after the photo lie, as (mime, start, end): Google's
    container counts them from the end of the file, Dynamic Depth lays them
    one after another right after the photo. None when the container lists
    nothing more, or a JPEG item doesn't run exactly from its SOI to its EOI
    there."""
    b, result = open(path, "rb").read(), opinion(path)
    listing = [(d, depth) for d, depth in zip(result["directories"], result["depth"]) if len(d) > 1]
    if result["unreadable"] or len(listing) != 1 or result["after"] is None: return None
    (directory, from_photo), = listing
    photo_end, primary, items = len(b) - result["after"], directory[0], directory[1:]
    arrangement = []
    if from_photo:
        start = photo_end + primary[3]
        for it in items:
            arrangement.append((it[1], start, start + it[2])); start += it[2] + it[3]
    else:
        end = len(b)
        for it in reversed(items):
            end -= it[3] + it[2]; arrangement.insert(0, (it[1], end, end + it[2]))
    if all(photo_end <= s and e <= len(b) for _, s, e in arrangement) and \
       all(image_end(b, s) == e for m, s, e in arrangement if m == "image/jpeg"):
        return arrangement
    return None


if __name__ == "__main__":
    for path in sys.argv[1:]:
        print(json.dumps(opinion(path)))
