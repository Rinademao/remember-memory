# check-memory.ps1 — health check for the remember memory system (v2).
# Read-only. Verifies hash headers, duplicate archives, near-empty stubs,
# index<->disk sync, and _state.json watermark sanity.
# Exit code: 0 = healthy, 1 = issues found.
. "$PSScriptRoot\remember-common.ps1"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$issues = @()
$warnings = @()

$files = @(Get-ChildItem $Script:ChatlogRoot -Recurse -File -Filter *.md |
           Where-Object { $_.Directory.Name -match '^\d{8}$' -and $_.Name -ne '_pending.md' -and $_.Name -ne 'CHATLOG_INDEX.md' })

# 1. Every archive must carry a content-hash header (dedup depends on it)
$noHeader = @()
foreach ($f in $files) {
    $h = Get-ArchiveHash (Get-Content $f.FullName -TotalCount 1 -Encoding UTF8)
    if (-not $h) { $noHeader += $f.FullName }
}
if ($noHeader.Count) { $issues += "有 $($noHeader.Count) 个存档缺少哈希头: $($noHeader -join ', ')" }

# 2. Duplicate archives (same content hash)
$byHash = $files | Group-Object { Get-ArchiveHash (Get-Content $_.FullName -TotalCount 1 -Encoding UTF8) }
foreach ($g in $byHash) {
    if ($g.Name -and $g.Count -gt 1) { $issues += "重复存档（哈希 $($g.Name.Substring(0, 8))…）共 $($g.Count) 份: " + (($g.Group | ForEach-Object { $_.Name }) -join ', ') }
}

# 3. Near-empty stub archives (token waste when injected)
$stubs = @($files | Where-Object { $_.Length -lt 300 })
if ($stubs.Count) { $warnings += "空档/接近空档 $($stubs.Count) 个（<300B）: " + (($stubs | ForEach-Object { "$($_.Directory.Name)/$($_.Name)" }) -join ', ') }

# 4. Index <-> disk sync
$diskSet = @{}
$files | ForEach-Object { $diskSet["$($_.Directory.Name)/$($_.Name)"] = $true }
$idxSet = @{}
$indexFile = Join-Path $Script:ChatlogRoot 'CHATLOG_INDEX.md'
if (Test-Path $indexFile) {
    $cur = $null
    foreach ($line in @(Get-Content $indexFile -Encoding UTF8)) {
        if ($line -match '^## (\d{8})') { $cur = $Matches[1] }
        elseif ($line -match '^-\s+\S+\s+\|\s+([\w_]+\.md)') { $idxSet["$cur/$($Matches[1])"] = $true }
    }
}
$missingOnDisk = @($idxSet.Keys | Where-Object { -not $diskSet[$_] })
$missingInIndex = @($diskSet.Keys | Where-Object { -not $idxSet[$_] })
if ($missingOnDisk.Count) { $issues += "索引里有但磁盘上没了（$($missingOnDisk.Count)）: $($missingOnDisk -join ', ')" }
if ($missingInIndex.Count) { $issues += "磁盘上有但索引没列出（$($missingInIndex.Count)）: $($missingInIndex -join ', ')" }
$last5line = @(Get-Content $indexFile -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '^last5:' } | Select-Object -First 1)
if ($last5line) {
    foreach ($p in (($last5line -replace '^last5:\s*', '') -split ', ' | Where-Object { $_ })) {
        if (-not (Test-Path (Join-Path $Script:ChatlogRoot $p))) { $issues += "last5 指向不存在的存档: $p" }
    }
}

# 5. _state.json sanity
$state = Get-State
if ($state.pendingTranscript) { $warnings += "存在未归档草稿（属主: $($state.pendingTranscript)）——新会话开始时会自动归档" }
foreach ($key in @($state.archived.Keys)) {
    $tp = [string]$key
    $wm = [string]$state.archived[$key]
    if (-not (Test-Path $tp)) { $issues += "水位线指向的 transcript 不存在: $tp" }
    else {
        $found = $false
        foreach ($line in @(Get-Content $tp -Encoding UTF8 -Tail 2000)) {
            if ($line -match [regex]::Escape($wm)) { $found = $true; break }
        }
        if (-not $found) { $warnings += "水位线 uuid $wm 在 transcript 尾部找不到（$tp）——可能已轮转，通常无害" }
    }
}

Write-Output "【不忘健康检查】存档 $($files.Count) 份 / 索引 $($idxSet.Count) 条"
if ($warnings.Count) { $warnings | ForEach-Object { Write-Output "⚠ $($_)" } }
if ($issues.Count) {
    $issues | ForEach-Object { Write-Output "✗ $($_)" }
    exit 1
}
Write-Output "✓ 全部正常"
exit 0
