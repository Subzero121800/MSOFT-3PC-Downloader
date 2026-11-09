<div align="center">

# MSOFT-3PC-Downloader

### Mirror Microsoft's entire third-party open source archive. The one behind the "$5.00 check or money order" notice.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)](#quick-start)
[![No dependencies](https://img.shields.io/badge/dependencies-none-success)](#quick-start)
[![Archive](https://img.shields.io/badge/archives-41%2C102-informational)](#what-is-in-the-archive)
[![Products](https://img.shields.io/badge/products-330%2B-informational)](products.tsv)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-jcinc-FFDD00?logo=buymeacoffee&logoColor=black)](https://www.buymeacoffee.com/jcinc)

</div>

---

## The $5 notice

Every Microsoft EULA carries a paragraph like this:

> *This software incorporates material from third parties. Microsoft makes certain open source code available at http://3rdpartysource.microsoft.com, or you may send a check or money order for US $5.00, including the product name, the open source component name, and version number, to: Source Code Compliance Team, Microsoft Corporation...*

That is Microsoft's **written offer** under the GPL, LGPL, and MPL. Copyleft licenses require anyone who ships covered code in a product to make the source available. Microsoft satisfies that for the open source components bundled inside Windows, Edge, SQL Server, Azure tooling, Xbox, and hundreds of other products by publishing them at `3rdpartysource.microsoft.com`, which now redirects to `opensource.microsoft.com/3pc`.

The site is free. Nobody needs to mail a check. But it is a JavaScript single-page app with no bulk download, no index file, and download links that expire every 100 minutes.

**This repository fixes that.** Three downloaders, one per platform, zero dependencies, that pull the full catalog, keep URLs fresh, resume after interruption, and lay everything out on disk by product and release.

---

## What is in the archive

Verified against the live API on 2026-11-09.

| | |
|---|---|
| **Archive entries** | 41,102 |
| **Products** | 330+ (full list in [`products.tsv`](products.tsv)) |
| **Unique archive files** | ~5,600. The same tarball is often listed under many products. |
| **Microsoft Edge** | 23,063 entries: a complete Chromium source dump for every build on every platform |
| **Everything except Edge** | ~18,000 entries, roughly 3.5 TB |
| **Everything including all Edge builds** | roughly 30 TB |
| **Download link lifetime** | ~100 minutes (Azure Blob SAS tokens). The scripts refresh per product. |

What you will find inside: Linux kernels shipped in Azure Sphere, the full OpenSSL, zlib, libpng, ICU, and FFmpeg trees used by Edge, Python wheels vendored into SQL Server, Electron builds, OpenTelemetry collectors, u-boot, BusyBox, and the GPL sources behind Surface and Xbox firmware. It is one of the largest single collections of real-world shipped open source on the internet, and almost nobody knows it exists.

> **This is not Microsoft's own source code.** Windows, Office, and the SQL Server engine have never been released and are not here. This archive is the open source *inside* those products, published because the licenses require it.

---

## Quick start

Pick your platform. Each script is self-contained.

### macOS: `Download-MS-3PC.command`

Double-click it in Finder. Uses only `bash`, `curl`, and `awk`, all of which ship with macOS.

```bash
# first run: macOS may block an unsigned script
xattr -d com.apple.quarantine Download-MS-3PC.command

# or run from Terminal with options
DEST="/Volumes/NAS/ms-3pc" EDGE=none ./Download-MS-3PC.command
```

Edit the `CONFIG` block at the top of the file to change the destination, Edge mode, product filter, or worker count before double-clicking.

### Windows: `Download-MS-3PC.ps1`

Right-click the file and choose **Run with PowerShell**, or:

```powershell
powershell -ExecutionPolicy Bypass -File .\Download-MS-3PC.ps1

# with options
powershell -ExecutionPolicy Bypass -File .\Download-MS-3PC.ps1 `
    -Dest "\\NAS\data\ms-3pc" -Products "SQL Server","Azure Sphere" -Edge none
```

Works on Windows PowerShell 5.1 (built in) and PowerShell 7+. On 7+ it downloads in parallel.

### Linux, NAS, or anything with Python 3: `ms_3pc_mirror.py`

The heavy-duty version. Adds SHA-256 verification, HTTP range resume, and hard-link deduplication, so the ~5,600 archives that appear under multiple products take disk space once.

```bash
# size estimate only, nothing downloaded
python3 ms_3pc_mirror.py --dest /tank/ms-3pc --plan

# full mirror, Edge trimmed to one archive per major version
python3 ms_3pc_mirror.py --dest /tank/ms-3pc --workers 8

# run unattended
nohup python3 ms_3pc_mirror.py --dest /tank/ms-3pc --workers 8 > run.out 2>&1 &
```

---

## Options

All three downloaders share the same controls.

| Option | Values | Default | What it does |
|---|---|---|---|
| **Destination** | any path | Desktop folder | Where files land. Point it at your NAS. |
| **Edge** | `major` / `none` / `all` | `major` | `major` keeps one Chromium archive per Edge major version (~100 files). `none` skips Edge. `all` takes every build on every platform (tens of TB). |
| **Products** | substring list | all | Limit to products whose name contains any of the strings. |
| **Workers** | integer | 6 | Simultaneous downloads. |

---

## Output layout

```
<dest>/
├── by-product/
│   ├── Azure Sphere/
│   │   ├── 18.11/
│   │   │   ├── Core OS components.zip
│   │   │   ├── GPL Sources.zip
│   │   │   └── Linux kernel.zip
│   │   └── 24.03/ ...
│   ├── Microsoft Edge/
│   │   └── 120.0.2210.61/Windows x64/chromium.zip
│   ├── SQL Server/
│   │   └── SQL Server 2022/
│   │       ├── pyzmq-22.1.0.tgz
│   │       └── ...
│   └── ... 330 more products
├── catalog.tsv   (or catalog.json)   full index snapshot
├── state.txt                          finished entries, for resume
└── mirror.log
```

Stop the script any time. Rerun the same command and it picks up where it left off. Delete `catalog.*` to force a fresh index pull if Microsoft adds products.

---

## How it works

1. **Catalog.** Pages through `opensource.microsoft.com/3pc/downloads?size=100&page=N` (zero-based) and records every entry's name, product, release, and platform. About 412 requests, 30 seconds.
2. **Selection.** Applies the Edge trim and product filter.
3. **Per product.** Re-queries the API with `q=<product>` to get fresh signed URLs, since the ones from step 1 expire in 100 minutes, then downloads in parallel into `by-product/<name>`.
4. **Resume.** Every finished entry is appended to `state.txt`. Partial files use `.part` and are resumed or restarted.

No API keys. No login. No third-party packages.

---

## FAQ

**Is this legal?**
Yes. Microsoft publishes this archive specifically so the public can download it. That is the entire point of a written offer under the GPL. Each archive carries its own open source license (GPL, LGPL, MPL, BSD, MIT, and others), and those licenses govern what you do with the contents.

**Why not just use the website?**
It is a React app with a 25-item paginated list, no bulk download, and signed URLs that die in 100 minutes. Pulling 41,000 files by hand is not an option.

**Why is Edge trimmed by default?**
Each Edge entry is the full Chromium tree, roughly 1 to 2 GB compressed, and there are 23,000 of them. Every major version is kept so you still have the Chromium source for each Edge generation.

**How much disk do I need?**
About 3.5 TB for everything except Edge (median file is 0.6 MB; a few hundred multi-GB tarballs drive the total). Run `ms_3pc_mirror.py --plan` for a live estimate. With hard-link dedup the Python version uses less.

**Does it hammer Microsoft's servers?**
Files are served from Azure Blob Storage, which is built for this. Default concurrency is 6. Be reasonable.

**Can I just grab one product?**
Yes: `-Products "Azure Sphere"` (Windows), `PRODUCTS="Azure Sphere"` (macOS), `--product "Azure Sphere"` (Python).

---

## Extras

[`extras/ms_github_mirror.sh`](extras/ms_github_mirror.sh) mirrors every public repository under Microsoft's GitHub organizations (microsoft, dotnet, PowerShell, Azure, and others). That is Microsoft's *own* open source: MS-DOS, GW-BASIC, Windows Terminal, PowerToys, VS Code, .NET, TypeScript, WSL. Requires `gh` and `git`. See the header for usage.

---

## Support this project

If this saved you a week of clicking, or you just like infrastructure that respects the user:

<a href="https://www.buymeacoffee.com/jcinc" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="50"></a>

**[buymeacoffee.com/jcinc](https://www.buymeacoffee.com/jcinc)**

---

## License

The scripts in this repository are released under the [MIT License](LICENSE).

The archives they download are not covered by this license. Each one carries its own open source license from its original authors. Microsoft's distribution terms are at [opensource.microsoft.com/3pc](https://opensource.microsoft.com/3pc/).

---

<div align="center">
<sub>Built by <a href="https://github.com/Subzero121800">Joseph C. McGinty Jr.</a> at <a href="https://ariaos.dev">ResilientMind AI</a>. Infrastructure, not interface.</sub>
</div>
