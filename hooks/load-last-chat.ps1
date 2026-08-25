# load-last-chat.ps1 — SessionStart hook: inject the latest 5 UNIQUE chatlog
# archives into context. (v2)
# Implements "Read — Session Start" (remember skill §4.3):
#   last5 from CHATLOG_INDEX (fallback: glob + mtime) -> dedup by content hash
#   -> truncate >20KB (front 15KB + back 5KB) -> print with the configured marker
. "$PSScriptRoot\remember-common.ps1"

$indexFile = Join-Path $Script:ChatlogRoot 'CHATLOG_INDEX.md'
$files = @()
$seen = @{}

# 1. Prefer CHATLOG_INDEX.md last5
if (Test-Path $indexFile) {
    $last5line = (Get-Content $indexFile -Encoding UTF8 | Where-Object { $_ -match '^last5:' } | Select-Object -First 1)
    if ($last5line) {
        foreach ($p in (($last5line -replace '^last5:\s*', '') -split ', ' | Where-Object { $_ })) {
            $full = Join-Path $Script:ChatlogRoot $p
            if (Test-Path $full) {
                $files += Get-Item $full
                $seen[$full] = $true
            }
        }
    }
}

# 2. Fallback / top-up: newest readable archives by mtime
if ($files.Count -lt 5) {
    $all = Get-ChildItem $Script:ChatlogRoot -Recurse -Filter *.md -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -ne '_pending.md' -and $_.Name -ne 'CHATLOG_INDEX.md' } |
           Sort-Object LastWriteTimeUtc -Descending
    foreach ($f in $all) {
        if ($files.Count -ge 5) { break }
        if (-not $seen[$f.FullName]) {
            $files += $f
            $seen[$f.FullName] = $true
        }
    }
}

if ($files.Count -eq 0) { exit 0 }

# 3. Read each candidate ONCE; derive a dedup hash (header hash for new-format
# archives, body-hash fallback so legacy twins collapse too); keep the content
# for output so no file is read twice.
$seenHash = @{}
$chosen = @()
foreach ($f in $files) {
    $content = Get-Content $f.FullName -Raw -Encoding UTF8
    # Skip near-empty stub archives — they only burn tokens in the injected context
    if ($content.Length -lt 300) { continue }
    $h = Get-ArchiveHash $content
    if ($h -and $seenHash[$h]) { continue }
    if ($h) { $seenHash[$h] = $true }
    $chosen += [PSCustomObject]@{ File = $f; Content = $content }
}
if ($chosen.Count -eq 0) { exit 0 }

# 4. Assemble output from the cached content, truncating oversized archives
$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine("$($Script:Config.marker)已载入最近 $($chosen.Count) 份记忆存档：")
foreach ($c in $chosen) {
    [void]$out.AppendLine('')
    [void]$out.AppendLine("════ $($c.File.FullName) ════")
    $content = $c.Content
    # character-based truncation to avoid splitting UTF-8 multibyte chars mid-sequence
    if ($content.Length -le 20000) {
        [void]$out.Append($content)
    } else {
        $front = $content.Substring(0, 15000)
        $back = $content.Substring($content.Length - 5000)
        [void]$out.AppendLine($front)
        [void]$out.AppendLine('')
        [void]$out.AppendLine('[中间已省略]')
        [void]$out.AppendLine('')
        [void]$out.Append($back)
    }
    [void]$out.AppendLine('')
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Output $out.ToString()
exit 0
