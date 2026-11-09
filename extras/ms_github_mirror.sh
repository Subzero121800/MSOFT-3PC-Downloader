#!/usr/bin/env bash
# Mirror every public repository in Microsoft's GitHub organizations.
#
# Requires: gh (authenticated: `gh auth login`), git, jq.
# Unauthenticated GitHub API is 60 req/hr; the org listings alone need more. Log in first.
#
# Clone mode is `git clone --mirror` (bare, all refs, all history, no working tree).
# That is the smallest faithful copy. To get a checkout later:  git clone /tank/ms-github/microsoft/<repo>.git
#
# Usage:
#   ./ms_github_mirror.sh /tank/ms-github                       # default org set
#   ORGS="microsoft dotnet" ./ms_github_mirror.sh /tank/ms-github
#   SKIP_ARCHIVED=0 ./ms_github_mirror.sh /tank/ms-github       # include archived repos
#   SHALLOW=1 ./ms_github_mirror.sh /tank/ms-github             # depth-1 clones instead of --mirror (much smaller, no history)
#   JOBS=8 ./ms_github_mirror.sh /tank/ms-github
#
# Re-running is incremental: existing mirrors get `git remote update --prune`.
set -euo pipefail

DEST="${1:?dest dir required}"
ORGS="${ORGS:-microsoft dotnet PowerShell Azure microsoftgraph MicrosoftDocs OfficeDev Azure-Samples mspnp MicrosoftLearning}"
SKIP_ARCHIVED="${SKIP_ARCHIVED:-1}"
SHALLOW="${SHALLOW:-0}"
JOBS="${JOBS:-6}"

mkdir -p "$DEST"
LOG="$DEST/mirror.log"
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

command -v gh >/dev/null || { echo "gh not installed"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run: gh auth login"; exit 1; }

LIST="$DEST/repos.tsv"
: > "$LIST"
for org in $ORGS; do
  log "listing $org"
  gh repo list "$org" --limit 10000 --source \
     --json nameWithOwner,isArchived,diskUsage,defaultBranchRef,pushedAt \
     --jq '.[] | [.nameWithOwner, (.isArchived|tostring), (.diskUsage//0|tostring), .pushedAt] | @tsv' >> "$LIST" \
     || log "  WARN: listing $org failed (org may not exist or rate limit hit)"
done

TOTAL=$(wc -l < "$LIST")
EST_MB=$(awk -F'\t' '{s+=$3} END{printf "%d", s/1024}' "$LIST")
log "$TOTAL repos listed; GitHub-reported size ~${EST_MB} MB (working-tree estimate; --mirror is usually smaller, SHALLOW far smaller)"

if [ "$SKIP_ARCHIVED" = "1" ]; then
  awk -F'\t' '$2=="false"' "$LIST" > "$LIST.active"
  log "skipping archived: $(wc -l < "$LIST.active") active repos remain"
else
  cp "$LIST" "$LIST.active"
fi

clone_one(){
  local nwo="$1" dest="$2" shallow="$3" log="$4"
  local org="${nwo%%/*}" repo="${nwo##*/}"
  local dir="$dest/$org/$repo.git"
  if [ -d "$dir" ]; then
    if [ "$shallow" = "1" ]; then
      git -C "$dir" fetch --depth 1 -q 2>>"$log" || echo "$(date '+%F %T') FAIL update $nwo" >> "$log"
    else
      git -C "$dir" remote update --prune -q 2>>"$log" || echo "$(date '+%F %T') FAIL update $nwo" >> "$log"
    fi
    return
  fi
  mkdir -p "$dest/$org"
  if [ "$shallow" = "1" ]; then
    git clone -q --depth 1 --no-single-branch "https://github.com/$nwo.git" "$dir" 2>>"$log" \
      || echo "$(date '+%F %T') FAIL clone $nwo" >> "$log"
  else
    git clone -q --mirror "https://github.com/$nwo.git" "$dir" 2>>"$log" \
      || echo "$(date '+%F %T') FAIL clone $nwo" >> "$log"
  fi
}
export -f clone_one

cut -f1 "$LIST.active" | xargs -P "$JOBS" -I{} bash -c 'clone_one "$@"' _ {} "$DEST" "$SHALLOW" "$LOG"

log "done. failures (if any):"
grep -c FAIL "$LOG" || true
