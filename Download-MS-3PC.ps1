<#
=============================================================================
 Download-MS-3PC.ps1   —   Windows downloader

 Mirrors Microsoft's third-party open source archive: the site behind the
 "...or you may send a check or money order for US $5.00..." notice in
 Microsoft EULAs.   https://opensource.microsoft.com/3pc/

 This is the GPL / LGPL / MPL source Microsoft must publish for the open
 source components bundled in its products. The site serves it for free, so
 no $5 check is needed. This is NOT Microsoft's own product source.

 RUN IT (pick one):
   - Right-click the file -> "Run with PowerShell", OR
   - In a terminal:
        powershell -ExecutionPolicy Bypass -File .\Download-MS-3PC.ps1
   - With options:
        powershell -ExecutionPolicy Bypass -File .\Download-MS-3PC.ps1 `
            -Dest "D:\ms-3pc" -Products "SQL Server","Azure Sphere" -Edge none

 NEEDS: Windows PowerShell 5.1 (built in) or PowerShell 7+. Nothing else.
        On PowerShell 7+ it downloads in parallel (-Workers). On 5.1 it runs
        sequentially but is otherwise identical.
=============================================================================
#>

param(
    # Where files go. Point at your PRO15E share, e.g. "\\PRO15E\data\ms-3pc".
    [string]   $Dest     = "$env:USERPROFILE\Desktop\MS-3PC-Mirror",

    # Microsoft Edge ships a FULL Chromium source dump per build per platform
    # (~23,000 archives, tens of TB). major = one per Edge major version
    # (default), none = skip Edge, all = every build (tens of TB).
    [ValidateSet('major','none','all')]
    [string]   $Edge     = 'major',

    # Limit to products (substring match), or leave empty for ALL 330.
    [string[]] $Products = @(),

    # Parallel downloads (PowerShell 7+ only; ignored on 5.1).
    [int]      $Workers  = 6
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Api = 'https://opensource.microsoft.com/3pc/downloads'
$Hdr = @{ 'User-Agent' = 'ms-3pc-mirror/1.0 (written-offer compliance mirror)' }

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$CatPath   = Join-Path $Dest 'catalog.json'
$StatePath = Join-Path $Dest 'state.txt'
$LogPath   = Join-Path $Dest 'mirror.log'
if (-not (Test-Path $StatePath)) { New-Item -ItemType File -Path $StatePath | Out-Null }
function Log($m) { $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; Write-Host $line; Add-Content $LogPath $line }

function Get-Page([string]$url) {
    for ($i = 1; $i -le 4; $i++) {
        try { return Invoke-RestMethod -Uri $url -Headers $Hdr -TimeoutSec 120 }
        catch { Start-Sleep -Seconds ($i * 2) }
    }
    throw "request failed: $url"
}

# ---- Phase 1: catalog (names + metadata). Pagination zero-based, size=100. ----
if (Test-Path $CatPath) {
    $catalog = Get-Content $CatPath -Raw | ConvertFrom-Json
    Log "Using existing catalog ($($catalog.Count) entries). Delete catalog.json to rebuild."
} else {
    Log "Building catalog (~30s)..."
    $catalog = New-Object System.Collections.Generic.List[object]
    $page = 0
    while ($true) {
        $r = Get-Page ("{0}?size=100&page={1}" -f $Api, $page)
        foreach ($it in $r.items) {
            $catalog.Add([pscustomobject]@{ name = $it.name; product = $it.product; release = $it.release; platform = $it.platform })
        }
        if ($page % 50 -eq 0) { Log ("  page {0} (~{1})" -f $page, ($page * 100)) }
        if ($r.items.Count -lt 100) { break }
        $page++
    }
    $catalog | ConvertTo-Json -Depth 4 | Set-Content $CatPath -Encoding UTF8
    Log "Catalog: $($catalog.Count) entries."
}

# ---- Build selection: Edge trim + product filter. ----
$sel      = New-Object System.Collections.Generic.List[object]
$edgeBest = @{}
foreach ($c in $catalog) {
    if ($Products.Count -gt 0) {
        $keep = $false
        foreach ($p in $Products) { if ($c.product.ToLower().Contains($p.ToLower())) { $keep = $true } }
        if (-not $keep) { continue }
    }
    if ($c.product -eq 'Microsoft Edge') {
        if ($Edge -eq 'none') { continue }
        if ($Edge -eq 'major') {
            $maj = ($c.release -split '\.')[0]
            $score = 0
            if ($c.platform -and $c.platform.ToLower().Contains('windows')) { $score += 2 }
            if ($c.platform -and $c.platform.ToLower().Contains('x64'))     { $score += 1 }
            if (-not $edgeBest.ContainsKey($maj) -or $score -gt $edgeBest[$maj].score) {
                $edgeBest[$maj] = @{ score = $score; item = $c }
            }
            continue
        }
    }
    $sel.Add($c)
}
foreach ($k in $edgeBest.Keys) { $sel.Add($edgeBest[$k].item) }

$done = New-Object System.Collections.Generic.HashSet[string]
Get-Content $StatePath | ForEach-Object { [void]$done.Add($_) }
Log "Selected $($sel.Count) files (Edge=$Edge, Products=$(if($Products){$Products -join ','}else{'ALL'})). Already done: $($done.Count)."

function To-RelPath([string]$name) { (($name -replace '[<>:"|?*]', '_') -replace '/', '\') }

# ---- Phase 2: per product, fetch fresh SAS URLs, then download. ----
$byProduct = $sel | Group-Object product
foreach ($g in $byProduct) {
    $product = $g.Name
    if (-not $product) { continue }
    Log "Product: $product"

    $urls = @{}
    $page = 0
    while ($true) {
        $r = Get-Page ("{0}?size=100&q={1}&page={2}" -f $Api, [uri]::EscapeDataString($product), $page)
        foreach ($it in $r.items) { $urls[$it.name] = $it.url }
        if ($r.items.Count -lt 100) { break }
        $page++
    }

    $tasks = foreach ($c in $g.Group) {
        if ($done.Contains($c.name)) { continue }
        if (-not $urls.ContainsKey($c.name)) { continue }
        [pscustomobject]@{ name = $c.name; url = $urls[$c.name] }
    }
    if (-not $tasks) { continue }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $Workers -gt 1) {
        $tasks | ForEach-Object -ThrottleLimit $Workers -Parallel {
            $t   = $_
            $out = Join-Path (Join-Path $using:Dest 'by-product') ((($t.name -replace '[<>:"|?*]','_') -replace '/','\'))
            $dir = Split-Path $out -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { return }
            $tmp = "$out.part"
            for ($i = 1; $i -le 3; $i++) {
                try { Invoke-WebRequest -Uri $t.url -OutFile $tmp -UseBasicParsing -TimeoutSec 1800; Move-Item -Force $tmp $out; break }
                catch { Start-Sleep -Seconds ($i * 2) }
            }
        }
        # record completed files (written after the parallel batch to avoid write races)
        foreach ($t in $tasks) {
            $out = Join-Path (Join-Path $Dest 'by-product') (To-RelPath $t.name)
            if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { Add-Content $StatePath $t.name }
            else { Add-Content $LogPath ("{0} FAIL {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t.name) }
        }
    }
    else {
        foreach ($t in $tasks) {
            $out = Join-Path (Join-Path $Dest 'by-product') (To-RelPath $t.name)
            $dir = Split-Path $out -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { Add-Content $StatePath $t.name; continue }
            $tmp = "$out.part"
            $ok = $false
            for ($i = 1; $i -le 3; $i++) {
                try { Invoke-WebRequest -Uri $t.url -OutFile $tmp -UseBasicParsing -TimeoutSec 1800; Move-Item -Force $tmp $out; $ok = $true; break }
                catch { Start-Sleep -Seconds ($i * 2) }
            }
            if ($ok) { Add-Content $StatePath $t.name }
            else { Add-Content $LogPath ("{0} FAIL {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t.name); if (Test-Path $tmp) { Remove-Item $tmp -Force } }
        }
    }
}

$fails = (Select-String -Path $LogPath -Pattern ' FAIL ' -ErrorAction SilentlyContinue).Count
Log "Done. Files in: $Dest\by-product   Failures logged: $fails"
