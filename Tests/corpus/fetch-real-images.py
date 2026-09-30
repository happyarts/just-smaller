#!/usr/bin/env python3
"""Downloads freely licensed real-world images for the test corpus.

Generated images catch edge cases; these give realistic compression ratios.
Sources:
  - Kodak Lossless True Color Image Suite: the 24 reference photos of image
    compression research, lossless PNG.
  - Wikimedia Commons (free licences): featured photos, and PNG / SVG / GIF /
    WebP files found through varied search terms, so they come from many
    different cameras, editors and encoders.
  - JPEGs that hold several images: iPhone photos with an HDR gain map
    (libultrahdr's test data, CC BY 4.0), Pixel 6 Pro Ultra HDR photos
    (MishaalRahmanGH/Ultra_HDR_Samples, CC BY 4.0), Skia's gain map test
    files (BSD), stereo MPOs from a Fujifilm camera and others (Pillow's
    test data, MIT-CMU).
  - Files that must stay as they are ("unchanged-"): multi-picture indexes
    that don't fit the file, a gain map listed only in XMP (Skia, Pillow).
  - PhotoPrism's sample collection (dl.photoprism.app/samples, CC BY-NC-SA
    4.0): photos from many cameras and phones, motion photos, portraits,
    panoramas, damaged JPEGs. Non-commercial: used here only for testing
    this open-source engine, never distributed.

Everything is cached in CACHE; re-running only fetches what's missing.
The images are for local testing only and never go into the repository.

usage: fetch-real-images.py CACHE
"""
import json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

CACHE = sys.argv[1]
UA = "just-smaller-test-corpus/1.0 (https://github.com/happyarts/just-smaller; local compression tests)"
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
GH = "https://raw.githubusercontent.com"
jobs += [("multi-jpeg", f"{n}.jpg", f"{GH}/google/libultrahdr/main/tests/data/{n}.jpg")
         for n in ("apple_gainmap_new", "apple_gainmap_old")]
jobs += [("multi-jpeg", f"pixel-ultrahdr-{n}.jpg", f"{GH}/MishaalRahmanGH/Ultra_HDR_Samples/main/Originals/Ultra_HDR_Samples_Originals_{n}.jpg")
         for n in ("01", "05")]
jobs += [("multi-jpeg", f"skia-{n}.jpg", f"{GH}/google/skia/main/resources/images/{n}.jpg")
         for n in ("gainmap_iso21496_1", "gainmap_iso21496_1_adobe_gcontainer")]
jobs += [("multi-jpeg", f"pillow-{n}", f"{GH}/python-pillow/Pillow/main/Tests/images/{n}")
         for n in ("fujifilm.mpo", "frozenpond.mpo", "sugarshack.mpo")]
jobs += [("unchanged", f"unchanged-skia-{n}.jpg", f"{GH}/google/skia/main/resources/images/{n}.jpg")
         for n in ("gainmap_gcontainer_only",)]
jobs += [("unchanged", f"unchanged-pillow-{n}", f"{GH}/python-pillow/Pillow/main/Tests/images/{n}")
         for n in ("ultrahdr.jpg", "sugarshack_bad_mpo_header.jpg", "sugarshack_ifd_offset.mpo", "sugarshack_no_data.mpo",
                   "frame_size.mpo")]
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

def photoprism(path=""):
    """Every image PhotoPrism's collection holds in a format we optimize."""
    base = "https://dl.photoprism.app/samples/"
    html = get(base + path, binary=True).decode("utf8", "replace")
    for name in re.findall(r'href="\./([^"]+)"', html):
        if name.endswith("/"):
            yield from photoprism(path + name)
        elif re.search(r"\.(jpe?g|mpo|heic|heif|png|gif|webp)$", name, re.I):
            yield (path + name).replace("%20", " ").replace("/", "_"), base + path + name

jobs += [("photoprism", n, u) for top in ("Formats/", "Brands/") for n, u in photoprism(top)]

def commons_multi_images(category, limit):
    """Phone photos on Commons that hold more than one image (HDR gain map,
    depth, motion photo): the first 128 KB of each file are read — gently,
    one request every two seconds — and those with a multi-picture index or
    a motion photo's marks are fetched whole."""
    params = {"action": "query", "format": "json", "generator": "categorymembers", "gcmtitle": category,
              "gcmtype": "file", "gcmlimit": limit, "prop": "imageinfo", "iiprop": "url|size|mime"}
    pages = get(API + "?" + urllib.parse.urlencode(params)).get("query", {}).get("pages", {})
    for p in sorted(pages.values(), key=lambda p: p["title"]):
        ii = (p.get("imageinfo") or [{}])[0]
        name = "commons-" + p["title"].removeprefix("File:")
        if ii.get("mime") != "image/jpeg" or ii.get("size", 0) > 20_000_000:
            continue
        if os.path.exists(os.path.join(CACHE, "multi-jpeg", "".join(c if c.isalnum() or c in "._-" else "_" for c in name)[-90:])):
            yield name, ii["url"]; continue
        req = urllib.request.Request(ii["url"], headers={"User-Agent": UA, "Range": "bytes=0-131071"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                head = r.read()
        except urllib.error.HTTPError as e:
            print(f"    commons: {e.code}, stopping the scan", flush=True)
            return
        time.sleep(2)
        if any(m in head for m in (b"MPF\0", b"MotionPhoto", b"MicroVideo", b"HDRGainMap", b"hdrgm")):
            yield name, ii["url"]

for cat in ("Taken with Apple iPhone 15 Pro", "Taken with Apple iPhone 14 Pro", "Taken with Apple iPhone 13 Pro",
            "Taken with Google Pixel 7", "Taken with Google Pixel 8 Pro", "Taken with Samsung Galaxy S23 Ultra"):
    jobs += [("multi-jpeg", n, u) for n, u in commons_multi_images("Category:" + cat, 60)]

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
