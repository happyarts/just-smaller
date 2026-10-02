#!/usr/bin/env python3
"""A second reader of Google's XMP in JPEGs, independent of the engine's
GoogleXMP (other language, expat instead of libxml2): the container
directory (Semantic, Mime, Length, Padding per item) and the motion photo
mark. One JSON object per file on stdout:

    {"file": ..., "unreadable": bool, "directories": [[[semantic, mime, length, padding], ...]],
     "motion": bool, "after": bytes after the first image, "listed": sum of the items after the primary}

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
    # End of the first image: walk the entropy-coded data marker by marker.
    while i + 2 <= len(b):
        if b[i] != 0xFF: i += 1; continue
        m = b[i + 1]
        if m == 0xD9: return out, i + 2
        if m == 0x00 or m == 0xFF or 0xD0 <= m <= 0xD7: i += 2 if m != 0xFF else 1; continue
        i += 2 + int.from_bytes(b[i + 2:i + 4], "big")
    return out, None


def name(tag):
    ns, _, local = tag[1:].partition("}") if tag.startswith("{") else ("", "", tag)
    return ns, local


def document(p):
    end = p.rfind(b"<?xpacket end=")
    if end >= 0 and p.find(b"?>", end) >= 0: return p[:p.find(b"?>", end) + 2]
    return p.rstrip(b"\0")


def read(packet):
    root = ET.fromstring(document(packet))
    directories, motion = [], False
    for el in root.iter():
        for key, value in list(el.attrib.items()) + [(el.tag, el.text or "")]:
            ns, local = name(key)
            if ns == CAMERA and local in ("MotionPhoto", "MicroVideo") and value.strip() == "1": motion = True
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
    return directories, motion


def wanted(p):
    return any(ns.encode() in p for ns in CONTAINER + [CAMERA])


for path in sys.argv[1:]:
    b = open(path, "rb").read()
    segs, end = segments(b)
    main = [p[len(XMP):] for m, p in segs if m == 0xE1 and p.startswith(XMP)]
    chunks = [p[len(EXTENDED):] for m, p in segs if m == 0xE1 and p.startswith(EXTENDED)]
    result = {"file": path, "unreadable": False, "directories": [], "motion": False,
              "after": len(b) - end if end else None, "listed": None}
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
            d, motion = read(p)
            result["directories"] += d
            result["motion"] = result["motion"] or motion
    except (ET.ParseError, ValueError):
        result = {**result, "unreadable": True, "directories": [], "motion": False}
    lists = [d for d in result["directories"] if len(d) > 1]
    if lists: result["listed"] = sum(i[2] + i[3] for i in lists[0][1:])
    print(json.dumps(result))
