#!/usr/bin/env python3
"""Downloads freely licensed real-world images for the test corpus.

Generated images catch edge cases; these give realistic compression ratios.
Sources:
  - Kodak Lossless True Color Image Suite: the 24 reference photos of image
    compression research, lossless PNG.
  - Wikimedia Commons (free licences): featured photos, and PNG / SVG / GIF /
    WebP files found through varied search terms, so they come from many
    different cameras, editors and encoders.
  - libultrahdr's test data (CC BY 4.0): iPhone photos with an HDR gain map,
    JPEGs that hold two images.

Everything is cached in CACHE; re-running only fetches what's missing.
The images are for local testing only and never go into the repository.

usage: fetch-real-images.py CACHE
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

CACHE = sys.argv[1]
UA = "just-smaller-test-corpus/1.0 (local compression benchmark)"
API = "https://commons.wikimedia.org/w/api.php"

def get(url, binary=False):
    """Fetch with retries: Wikimedia answers bursts with 429 and a Retry-After."""
    delay = 5
    for attempt in range(6):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            time.sleep(0.5)  # stay well under the rate limits between any two requests
            return data if binary else json.loads(data)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == 5:
                raise
            wait = int(e.headers.get("Retry-After") or delay)
            print(f"    {e.code}, waiting {wait}s", flush=True)
            time.sleep(wait)
            delay = min(delay * 2, 120)

def save(folder, name, url):
    os.makedirs(os.path.join(CACHE, folder), exist_ok=True)
    safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)[-90:]
    path = os.path.join(CACHE, folder, safe)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return "cached"
    try:
        data = get(url, binary=True)
    except Exception as e:
        return f"failed ({e.__class__.__name__})"
    open(path, "wb").write(data)
    return "ok"

def commons_files(query, mime, limit, max_bytes, thumb_width=None):
    """Titles matching a search, with their download URL (thumbnail if asked)."""
    params = {"action": "query", "format": "json", "generator": "search", "gsrnamespace": 6,
              "gsrsearch": f"filemime:{mime} {query}".strip(), "gsrlimit": limit * 3,
              "prop": "imageinfo", "iiprop": "url|size|mime"}
    if thumb_width:
        params["iiurlwidth"] = thumb_width
    pages = get(API + "?" + urllib.parse.urlencode(params)).get("query", {}).get("pages", {})
    out = []
    for p in sorted(pages.values(), key=lambda p: p.get("index", 0)):
        ii = (p.get("imageinfo") or [{}])[0]
        if ii.get("mime") != mime:
            continue
        url = ii.get("thumburl") if thumb_width else ii.get("url")
        if not url or (not thumb_width and ii.get("size", 0) > max_bytes):
            continue
        out.append((p["title"].removeprefix("File:"), url))
        if len(out) >= limit:
            break
    return out

def featured_photos(limit, thumb_width, originals_max_bytes):
    """Featured pictures: high quality, many different cameras."""
    params = {"action": "query", "format": "json", "generator": "categorymembers",
              "gcmtitle": "Category:Featured pictures on Wikimedia Commons", "gcmtype": "file",
              "gcmlimit": 200, "prop": "imageinfo", "iiprop": "url|size|mime", "iiurlwidth": thumb_width}
    pages = get(API + "?" + urllib.parse.urlencode(params)).get("query", {}).get("pages", {})
    thumbs, originals = [], []
    for p in sorted(pages.values(), key=lambda p: p["title"]):
        ii = (p.get("imageinfo") or [{}])[0]
        if ii.get("mime") != "image/jpeg":
            continue
        name = p["title"].removeprefix("File:")
        if len(thumbs) < limit and ii.get("thumburl"):
            thumbs.append((name, ii["thumburl"]))
        # camera originals keep their EXIF and the camera's own encoder settings
        elif len(originals) < limit // 3 and ii.get("size", 0) < originals_max_bytes:
            originals.append(("orig-" + name, ii["url"]))
    return thumbs, originals

jobs = []
jobs += [("kodak", f"kodim{i:02d}.png", f"https://r0k.us/graphics/kodak/kodak/kodim{i:02d}.png") for i in range(1, 25)]
jobs += [("multi-jpeg", f"{n}.jpg", f"https://raw.githubusercontent.com/google/libultrahdr/main/tests/data/{n}.jpg")
         for n in ("apple_gainmap_new", "apple_gainmap_old")]
thumbs, originals = featured_photos(30, 1920, 8_000_000)
jobs += [("photo-jpeg", n, u) for n, u in thumbs + originals]
for q in ("screenshot", "diagram", "chart", "logo", "map", "photograph", "icon", "drawing"):
    jobs += [("png", n, u) for n, u in commons_files(q, "image/png", 5, 4_000_000)]
for q in ("map", "logo", "icon", "diagram", "coat of arms", "flag", "chart", "illustration"):
    jobs += [("svg", n, u) for n, u in commons_files(q, "image/svg+xml", 5, 800_000)]
for q in ("animation", "diagram", "loading", "cartoon"):
    jobs += [("gif", n, u) for n, u in commons_files(q, "image/gif", 5, 4_000_000)]
for q in ("", "photo", "screenshot"):
    jobs += [("webp", n, u) for n, u in commons_files(q, "image/webp", 5, 4_000_000)]

seen, stats = set(), {}
for folder, name, url in jobs:
    if (folder, name) in seen:
        continue
    seen.add((folder, name))
    r = save(folder, name, url)
    stats.setdefault(folder, {}).setdefault(r.split()[0], 0)
    stats[folder][r.split()[0]] += 1
for folder, s in stats.items():
    print(f"  {folder:<11} {s}")
