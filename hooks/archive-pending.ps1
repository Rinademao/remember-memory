# archive-pending.ps1 — SessionStart / SessionEnd hook. (v2)
# Implements "Archive — Session End" (remember skill §4.2):
#   watermark-filtered backfill -> assemble body -> HASH-DEDUP (never write a
#   twin) -> write YYYYMMDD/HHmmss_auto.md -> advance watermark -> delete
#   _pending.md -> rebuild CHATLOG_INDEX.md completely from disk
. "$PSScriptRoot\remember-common.ps1"

# ---- 1. Nothing to archive without a live buffer ----
if (-not (Test-Path $Script:PendingFile)) { exit 0 }

# ---- 2. The pending's OWNER transcript drives backfill + watermark.
# Never resolve against the current session: after a crash the buffer may belong
# to an earlier transcript, and re-reading it from here would re-archive it.
$state = Get-State
$ownerTranscript = $null
if ($state.pendingTranscript) { $ownerTranscript = [string]$state.pendingTranscript }
$watermark = Get-Watermark -State $state -TranscriptPath $ownerTranscript

# ---- 3. Backfill: append any messages the per-turn hook missed (only against
# the owner transcript, and only beyond the watermark) ----
if ($ownerTranscript -and (Test-Path $ownerTranscript)) {
    $new = Get-NewMessages -TranscriptPath $ownerTranscript -PendingPath $Script:PendingFile -SkipUpToUuid $watermark
    if ($new.Count -gt 0) { Append-Messages $new }
}

# ---- 4. Skip if _pending.md holds no [msg:] blocks (no empty archives) ----
$pendingLines = @(Get-Content $Script:PendingFile -Encoding UTF8)
$hasMsg = $pendingLines | Where-Object { $_ -match '^\[msg:' } | Select-Object -First 1
if (-not $hasMsg) {
    Remove-Item $Script:PendingFile -Force
    if ($state.pendingTranscript) { $state.pendingTranscript = $null; Save-State $state }
    exit 0
}

# ---- 5. Parse blocks + assemble the clean readable body ----
$blocks = @()
$current = $null
foreach ($line in $pendingLines) {
    if ($line -match '^\[msg:([0-9a-fA-F\-]+)\]') {
        $current = [PSCustomObject]@{ id = $Matches[1]; name = ''; lines = @() }
        $blocks += $current
    }
    elseif ($line -match '^\*\*(User|Assistant [^*]+)\*\*') {
        if ($current) { $current.name = $Matches[1] }
    }
    elseif ($current) {
        if ($line -match '^# Auto-save|^> Generated|^---$') { continue }
        $current.lines += $line
    }
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Session Archive -- $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Conversation')
[void]$sb.AppendLine('')
foreach ($b in $blocks) {
    if (-not $b.name) { continue }
    [void]$sb.AppendLine("**$($b.name)**:")
    foreach ($l in $b.lines) { [void]$sb.AppendLine($l) }
    [void]$sb.AppendLine('')
}
$body = $sb.ToString()
# Hash the CONVERSATION content only — the header line carries a minute
# timestamp that changes every run and would otherwise break content dedup
# (two archives of the same chat would never hash equal).
$hashIdx = $body.IndexOf('## Conversation')
$hashable = if ($hashIdx -ge 0) { $body.Substring($hashIdx) } else { $body }
$bodyHash = Get-BodyHash $hashable

# ---- 6. Write-time dedup (kills the twin class): an archive with this exact
# conversation content already exists -> don't write a second copy, just advance
# the watermark and clean the buffer. New-format archives are matched by their
# header hash (cheap, one line); legacy archives without a header are hashed by
# body so they participate too — no format is invisible to the dedup. ----
$dupFile = Get-ChildItem $Script:ChatlogRoot -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '^\d{8}$' } |
           ForEach-Object { Get-ChildItem $_.FullName -Filter *.md -ErrorAction SilentlyContinue } |
           Where-Object {
               $h = Get-ArchiveHash (Get-Content $_.FullName -TotalCount 1 -Encoding UTF8)
               $h -and $h -eq $bodyHash
           } |
           Select-Object -First 1

# ---- 7. Write the archive (first line = content hash, then the clean body),
# unless the identical conversation is already archived ----
$wroteArchive = $false
if (-not $dupFile) {
    $now = Get-Date
    $dateDir = $now.ToString('yyyyMMdd')
    $timeStamp = $now.ToString('HHmmss')
    $destDir = Join-Path $Script:ChatlogRoot $dateDir
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $destFile = Join-Path $destDir "$($timeStamp)_auto.md"
    # Two archives can land in the same second (SessionEnd followed immediately
    # by SessionStart). Never overwrite: bump to <HHmmss>_<n>_auto.md.
    $i = 2
    while (Test-Path $destFile) {
        $destFile = Join-Path $destDir "$($timeStamp)_$($i)_auto.md"
        $i++
    }
    $final = "<!-- h:$bodyHash -->`n$body"
    [System.IO.File]::WriteAllText($destFile, $final, (New-Object System.Text.UTF8Encoding($false)))
    $wroteArchive = $true
}

# ---- 8. Either way: advance the watermark, clear the buffer ----
if ($blocks.Count -gt 0) {
    $lastId = $blocks[$blocks.Count - 1].id
    if ($ownerTranscript) { $state.archived[$ownerTranscript] = $lastId }
}
$state.pendingTranscript = $null
Remove-Item $Script:PendingFile -Force
Save-State $state

# ---- 9. Rebuild the index only when a new archive was written (a dup already
# has its index entry from when it was first archived) ----
if ($wroteArchive) { Rebuild-Index }

exit 0
