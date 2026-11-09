#!/usr/bin/env python3
"""
Mirror Microsoft's third-party source archive (opensource.microsoft.com/3pc,
the site behind the "$5.00 check or money order" notice) to local disk.

Facts about the source (verified 2026-11-09):
  - Index API: https://opensource.microsoft.com/3pc/downloads?size=100&page=N   (max size 100, N starts at 0)
  - ~41,000 entries, 330 products, but only ~5,500 unique archive filenames.
  - Each entry carries an Azure Blob SAS URL valid ~100 minutes, so URLs are
    refreshed per batch instead of stored.
  - Microsoft Edge = 23,000 copies of the full Chromium source, one per
    build x platform. That alone is tens of TB. Default here: keep one
    archive per Edge major version. Use --edge all to take everything.

Layout on disk:
  <dest>/by-product/<Product>/<Release>/[<Platform>/]<file>
  <dest>/manifest.json        full index snapshot
  <dest>/state.json           what finished (sha256 + size), for resume

Identical filename + identical byte size across products is downloaded once
and hard-linked into every other location that references it.

Usage:
  python3 ms_3pc_mirror.py --dest /tank/ms-3pc                 # default: all, Edge trimmed
  python3 ms_3pc_mirror.py --dest /tank/ms-3pc --edge none     # skip Edge entirely
  python3 ms_3pc_mirror.py --dest /tank/ms-3pc --edge all      # tens of TB
  python3 ms_3pc_mirror.py --dest /tank/ms-3pc --product "SQL Server" --product "Azure Sphere"
  python3 ms_3pc_mirror.py --dest /tank/ms-3pc --plan          # size estimate only, no download
"""
import argparse, concurrent.futures as cf, hashlib, json, os, re, sys, time, urllib.parse, urllib.request
from collections import defaultdict

API = "https://opensource.microsoft.com/3pc/downloads"
UA = {"User-Agent": "ms-3pc-mirror/1.0 (+written-offer compliance mirror)"}


def http_json(url, tries=4):
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=90) as r:
                return json.load(r)
        except Exception as e:  # noqa
            err = e
            time.sleep(2 * (i + 1))
    raise err


def fetch_index(log):
    first = http_json(f"{API}?size=100&page=0")  # pagination is zero-based
    total = first["total"]
    pages = (total + 99) // 100
    items = list(first["items"])
    log(f"index: {total} entries over {pages} pages")

    def page(p):
        return http_json(f"{API}?size=100&page={p}")["items"]

    with cf.ThreadPoolExecutor(12) as ex:
        for n, res in enumerate(ex.map(page, range(1, pages)), 2):
            items.extend(res)
            if n % 50 == 0:
                log(f"  index page {n}/{pages}")
    for it in items:
        it["blob_path"] = it["url"].split("/download/", 1)[1].split("?", 1)[0]
        it["url_seen"] = time.time()
    return items


def local_rel(it):
    parts = [it["product"].strip(), it["release"].strip()]
    if it.get("platform"):
        parts.append(it["platform"].strip())
    parts.append(it["dependency"].strip())
    safe = [re.sub(r'[<>:"|?*\\/]+', "_", p).strip() or "_" for p in parts]
    return os.path.join("by-product", *safe)


def edge_filter(items, mode):
    if mode == "all":
        return items
    out, keep_edge = [], {}
    for it in items:
        if it["product"].strip() != "Microsoft Edge":
            out.append(it)
            continue
        if mode == "none":
            continue
        # "major": one archive per major version, prefer Windows x64 zip, newest build
        m = re.match(r"(\d+)\.", it["release"].strip())
        if not m:
            continue
        major = int(m.group(1))
        plat = (it.get("platform") or "").lower()
        score = (("windows" in plat) * 2 + ("x64" in plat), tuple(int(x) for x in re.findall(r"\d+", it["release"])))
        if major not in keep_edge or score > keep_edge[major][0]:
            keep_edge[major] = (score, it)
    out.extend(v[1] for v in keep_edge.values())
    return out


def refresh_urls(entries, log):
    """Re-query the index for a batch so SAS tokens are fresh. Keyed by name."""
    want = {e["name"]: e for e in entries}
    got = {}
    # q is a plain substring match on the entry path (no slashes allowed); query by product name.
    keys = sorted({e["product"].strip() for e in entries})

    def q(key):
        res = []
        page = 0
        while True:
            d = http_json(f"{API}?size=100&page={page}&q={urllib.parse.quote(key)}")
            res += d["items"]
            total = d.get("total")
            if not d["items"] or len(d["items"]) < 100 or (total and (page + 1) * 100 >= total) or page > 500:
                break
            page += 1
        return res

    with cf.ThreadPoolExecutor(8) as ex:
        for res in ex.map(q, keys):
            for x in res:
                if x["name"] in want:
                    got[x["name"]] = x["url"]
    missing = [n for n in want if n not in got]
    if missing:
        log(f"  warning: {len(missing)} entries not found on refresh (renamed/removed upstream)")
    return got


def head_size(url):
    try:
        r = urllib.request.Request(url, method="HEAD", headers=UA)
        with urllib.request.urlopen(r, timeout=60) as resp:
            return int(resp.headers.get("Content-Length", 0))
    except Exception:
        return None


def download(url, path, expected=None):
    tmp = path + ".part"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    have = os.path.getsize(tmp) if os.path.exists(tmp) else 0
    h = hashlib.sha256()
    if have:
        with open(tmp, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    req = urllib.request.Request(url, headers={**UA, **({"Range": f"bytes={have}-"} if have else {})})
    with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "ab") as out:
        if have and resp.status != 206:
            out.seek(0); out.truncate(); h = hashlib.sha256()
        for chunk in iter(lambda: resp.read(1 << 20), b""):
            out.write(chunk); h.update(chunk)
    size = os.path.getsize(tmp)
    if expected and size != expected:
        raise IOError(f"size mismatch {size} != {expected}")
    os.replace(tmp, path)
    return h.hexdigest(), size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", required=True)
    ap.add_argument("--edge", choices=["major", "none", "all"], default="major")
    ap.add_argument("--product", action="append", help="limit to product(s); repeatable, case-insensitive substring")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--plan", action="store_true", help="estimate only")
    ap.add_argument("--refresh-index", action="store_true", help="ignore cached manifest.json")
    a = ap.parse_args()

    os.makedirs(a.dest, exist_ok=True)
    logf = open(os.path.join(a.dest, "mirror.log"), "a")

    def log(msg):
        line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
        print(line, flush=True); logf.write(line + "\n"); logf.flush()

    man_path = os.path.join(a.dest, "manifest.json")
    if os.path.exists(man_path) and not a.refresh_index:
        items = json.load(open(man_path))
        log(f"using cached manifest ({len(items)} entries); --refresh-index to re-pull")
    else:
        items = fetch_index(log)
        json.dump(items, open(man_path, "w"))

    items = edge_filter(items, a.edge)
    if a.product:
        pats = [p.lower() for p in a.product]
        items = [i for i in items if any(p in i["product"].lower() for p in pats)]
    log(f"selected {len(items)} entries, {len({i['dependency'] for i in items})} unique filenames")

    state_path = os.path.join(a.dest, "state.json")
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}

    todo = [i for i in items if i["name"] not in state]
    log(f"{len(state)} done, {len(todo)} to go")

    if a.plan:
        import random
        sample = random.sample(todo, min(150, len(todo)))
        urls = refresh_urls(sample, log)
        sizes = [s for s in (head_size(urls[e["name"]]) for e in sample if e["name"] in urls) if s]
        if sizes:
            avg = sum(sizes) / len(sizes)
            uniq = len({i["dependency"] for i in todo})
            log(f"sample n={len(sizes)} avg {avg/1e6:.1f} MB, median {sorted(sizes)[len(sizes)//2]/1e6:.1f} MB")
            log(f"estimate for ~{uniq} unique downloads: {avg*uniq/1e9:.0f} GB (hard links add no space)")
        return

    def save_state():
        tmp = state_path + ".tmp"
        json.dump(state, open(tmp, "w")); os.replace(tmp, state_path)

    # blob index: (filename, size) -> relative path of a finished copy. Lets identical archives
    # referenced by many products be downloaded once and hard-linked everywhere else.
    blob_index = {}
    for name, rec in state.items():
        if rec.get("size") and "link_of" not in rec:
            blob_index.setdefault((name.rsplit("/", 1)[-1], rec["size"]), rec["path"])

    by_product = defaultdict(list)
    for it in todo:
        by_product[it["product"].strip()].append(it)

    for pi, (product, entries) in enumerate(sorted(by_product.items()), 1):
        log(f"[{pi}/{len(by_product)}] {product}: {len(entries)} entries, refreshing URLs")
        urls = refresh_urls(entries, log)
        entries = [e for e in entries if e["name"] in urls]

        def work(e):
            url = urls[e["name"]]
            size = head_size(url)
            rel = local_rel(e)
            path = os.path.join(a.dest, rel)
            key = (e["dependency"].strip(), size)
            try:
                if os.path.exists(path) and size and os.path.getsize(path) == size:
                    return e["name"], {"path": rel, "size": size, "sha256": None}
                if size and key in blob_index:
                    src = os.path.join(a.dest, blob_index[key])
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    try:
                        os.link(src, path)
                    except OSError:
                        import shutil; shutil.copy2(src, path)
                    return e["name"], {"path": rel, "size": size, "sha256": None, "link_of": blob_index[key]}
                digest, _ = download(url, path, size)
                if size:
                    blob_index.setdefault(key, rel)
                return e["name"], {"path": rel, "size": size, "sha256": digest}
            except Exception as ex:
                log(f"  FAIL {e['name']}: {ex}")
                return None

        n = 0
        with cf.ThreadPoolExecutor(a.workers) as ex:
            for res in ex.map(work, entries):
                if res:
                    state[res[0]] = res[1]
                n += 1
                if n % 50 == 0:
                    save_state(); log(f"  {n}/{len(entries)} ({len(state)} total done)")
        save_state()
    log(f"complete: {len(state)} entries mirrored")


if __name__ == "__main__":
    main()
