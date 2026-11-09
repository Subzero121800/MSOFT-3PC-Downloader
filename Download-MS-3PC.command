#!/bin/bash
# =============================================================================
# Download-MS-3PC.command   —   macOS double-click downloader
#
# Mirrors Microsoft's third-party open source archive: the site behind the
# "...or you may send a check or money order for US $5.00..." notice in
# Microsoft EULAs.   https://opensource.microsoft.com/3pc/
#
# This is the GPL / LGPL / MPL source Microsoft must publish for the open
# source components bundled in its products. The site serves it for free, so
# no $5 check is needed. This is NOT Microsoft's own product source.
#
# RUN IT:  double-click in Finder. If macOS blocks it the first time,
#          right-click -> Open, or run:
#             xattr -d com.apple.quarantine "Download-MS-3PC.command"
# NEEDS:   bash + curl + awk only. All ship with macOS. No Python, no Homebrew.
# =============================================================================

# ------------------------------- CONFIG --------------------------------------
# Edit, save, then double-click.

# Where files go. Point at your PRO15E mount, e.g. "/Volumes/PRO15E/ms-3pc".
DEST="${DEST:-$HOME/Desktop/MS-3PC-Mirror}"

# Microsoft Edge ships a FULL Chromium source dump per build per platform
# (~23,000 archives, tens of TB). Choose:
#   major = one archive per Edge major version   (default, sane)
#   none  = skip Edge entirely
#   all   = every Edge build (tens of terabytes)
EDGE="${EDGE:-major}"

# Limit to products (comma-separated substrings), or empty for ALL 330.
# Example: PRODUCTS="SQL Server,Azure Sphere"
PRODUCTS="${PRODUCTS:-}"

# Simultaneous downloads.
WORKERS="${WORKERS:-6}"
# -----------------------------------------------------------------------------

set -uo pipefail
API="https://opensource.microsoft.com/3pc/downloads"
UA="ms-3pc-mirror/1.0 (written-offer compliance mirror)"

mkdir -p "$DEST" || { echo "Cannot create $DEST"; echo "Press Return."; read -r _; exit 1; }
CATALOG="$DEST/catalog.tsv"
WORK="$DEST/worklist.tsv"
STATE="$DEST/state.txt"
LOG="$DEST/mirror.log"
touch "$STATE"
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
command -v curl >/dev/null || { echo "curl not found."; read -r _; exit 1; }

# JSON -> TSV (name, url, product, release, platform, dependency). Tested against
# the 3pc API's flat item objects, including null platform values.
PARSE='
function unesc(s){ gsub(/\\\//,"/",s); gsub(/\\"/,"\"",s); gsub(/\\\\/,"\\",s); return s }
BEGIN{ RS="\\{"; FS="\"" }
{
  delete v
  for(i=2;i<=NF;i++){
    if(i==2 || $(i-1) ~ /[,{[]$/){ k=$i; if($(i+1)==":"){ v[k]=$(i+2) } else { v[k]="" } }
  }
  if(v["name"]!=""){ printf "%s\t%s\t%s\t%s\t%s\t%s\n",
    unesc(v["name"]),unesc(v["url"]),unesc(v["product"]),unesc(v["release"]),unesc(v["platform"]),unesc(v["dependency"]) }
}'

api_get(){ local u="$1" i; for i in 1 2 3 4; do curl -fsS --max-time 120 -A "$UA" "$u" && return 0; sleep $((i*2)); done; return 1; }

# -------- Phase 1: catalog (names + metadata). Pagination zero-based, size=100.
if [ ! -s "$CATALOG" ]; then
  log "Building catalog (~30s)..."
  : > "$CATALOG.tmp"; page=0; total=""
  while :; do
    body="$(api_get "$API?size=100&page=$page")" || { log "catalog fetch failed at page $page"; break; }
    [ -z "$total" ] && total="$(printf '%s' "$body" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')"
    n="$(printf '%s' "$body" | awk "$PARSE" | cut -f1,3,4,5 | tee -a "$CATALOG.tmp" | wc -l | tr -d ' ')"
    [ $((page % 50)) -eq 0 ] && log "  page $page (~$((page*100)) / ${total:-?})"
    [ "${n:-0}" -lt 100 ] && break
    page=$((page+1))
  done
  mv -f "$CATALOG.tmp" "$CATALOG"
  log "Catalog: $(wc -l < "$CATALOG" | tr -d ' ') entries."
else
  log "Using existing catalog ($(wc -l < "$CATALOG" | tr -d ' ') entries). Delete it to rebuild."
fi

# -------- Build worklist: apply Edge trim + product filter. Cols: name product release platform
awk -v edge="$EDGE" -v prods="$PRODUCTS" '
  BEGIN{ FS=OFS="\t"; np=split(prods,P,",") }
  {
    name=$1; product=$2; release=$3; platform=$4
    if (prods!=""){ keep=0; for(i=1;i<=np;i++){ p=P[i]; gsub(/^ +| +$/,"",p); if(p!="" && index(tolower(product),tolower(p))) keep=1 } if(!keep) next }
    if (product ~ /^Microsoft Edge$/){
      if (edge=="none") next
      if (edge=="major"){
        maj=release; sub(/\..*/,"",maj)
        score=(index(tolower(platform),"windows")?2:0)+(index(tolower(platform),"x64")?1:0)
        if(!(maj in best) || score>bs[maj]){ best[maj]=$0; bs[maj]=score }
        next
      }
    }
    print
  }
  END{ for(k in best) print best[k] }
' "$CATALOG" > "$WORK"
log "Selected $(wc -l < "$WORK" | tr -d ' ') files (EDGE=$EDGE, PRODUCTS='${PRODUCTS:-ALL}'). Already done: $(wc -l < "$STATE" | tr -d ' ')."

# -------- Phase 2: per product, fetch fresh SAS URLs, download in parallel.
export DEST UA STATE LOG
dl_one(){
  local line="$1" name url rel out tmp
  name="${line%%$'\t'*}"; rest="${line#*$'\t'}"; url="${rest%%$'\t'*}"; rel="${rest#*$'\t'}"
  out="$DEST/by-product/$rel"; tmp="$out.part"
  mkdir -p "$(dirname "$out")"
  if [ -s "$out" ]; then printf '%s\n' "$name" >> "$STATE"; return; fi
  if curl -fL --retry 3 --retry-delay 2 --max-time 1800 -A "$UA" -C - -o "$tmp" "$url" 2>>"$LOG"; then
    mv -f "$tmp" "$out"; printf '%s\n' "$name" >> "$STATE"
  else
    printf '%s FAIL %s\n' "$(date '+%F %T')" "$name" >> "$LOG"; rm -f "$tmp"
  fi
}
export -f dl_one

cut -f2 "$WORK" | sort -u | while IFS= read -r product; do
  [ -z "$product" ] && continue
  log "Product: $product"
  umap="$DEST/.urls.tmp"; : > "$umap"; page=0
  while :; do
    body="$(curl -fsS --max-time 120 -A "$UA" -G "$API" --data-urlencode "size=100" --data-urlencode "q=$product" --data-urlencode "page=$page")" || break
    cnt="$(printf '%s' "$body" | awk "$PARSE" | cut -f1,2 | tee -a "$umap" | wc -l | tr -d ' ')"
    [ "${cnt:-0}" -lt 100 ] && break
    page=$((page+1))
  done
  # tasks: name<TAB>url<TAB>relpath(=sanitized name), skipping done; NUL-separated for xargs
  awk -F'\t' -v prod="$product" '
    FILENAME==ST { done[$0]=1; next }
    FILENAME==UM { url[$1]=$2; next }
    $2==prod {
      name=$1; if(name in done) next
      u=url[name]; if(u=="") next
      rel=name; gsub(/[<>:"|?*\\]/,"_",rel)
      printf "%s\t%s\t%s\n", name, u, rel
    }
  ' ST="$STATE" UM="$umap" "$STATE" "$umap" "$WORK" \
  | tr '\n' '\0' \
  | xargs -0 -P "$WORKERS" -I{} bash -c 'dl_one "$@"' _ {}
  rm -f "$umap"
done

fails="$(grep -c ' FAIL ' "$LOG" 2>/dev/null || echo 0)"
log "Done. Files in: $DEST/by-product    Failures logged: $fails"
echo; echo "Finished. Press Return to close."; read -r _
