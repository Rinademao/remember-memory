# auto-save.ps1 — Stop hook: append new transcript messages to _pending.md. (v2)
# Implements "Write — Append Per Turn" (remember skill §4.1):
#   resolve transcript -> crash-recover a stale buffer -> watermark filter
#   -> collect unseen messages -> 500ms flush-guard retry -> append
. "$PSScriptRoot\remember-common.ps1"

$transcriptPath = Resolve-TranscriptPath
if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { exit 0 }

$state = Get-State

# Crash recovery: _pending.md belongs to a different transcript -> archive it
# first (the owner transcript drives the watermark, so nothing re-archives).
if ((Test-Path $Script:PendingFile) -and $state.pendingTranscript -and $state.pendingTranscript -ne $transcriptPath) {
    & "$PSScriptRoot\archive-pending.ps1" | Out-Null
    $state = Get-State
}

# _pending.md size guard (§5.3): auto-archive before it grows past 512KB.
# The watermark guarantees the archived prefix is never re-collected.
if (Test-Path $Script:PendingFile) {
    $len = (Get-Item $Script:PendingFile).Length
    if ($len -gt 512000) {
        & "$PSScriptRoot\archive-pending.ps1" | Out-Null
        $state = Get-State
    }
}

# Everything <= the watermark is already archived — never re-feed it.
$watermark = Get-Watermark -State $state -TranscriptPath $transcriptPath

$new = Get-NewMessages -TranscriptPath $transcriptPath -PendingPath $Script:PendingFile -SkipUpToUuid $watermark
if ($new.Count -eq 0) {
    # flush guard: transcript may not have finished writing this turn
    Start-Sleep -Milliseconds 500
    $new = Get-NewMessages -TranscriptPath $transcriptPath -PendingPath $Script:PendingFile -SkipUpToUuid $watermark
}
if ($new.Count -eq 0) {
    # still record which transcript the (possibly empty) buffer belongs to,
    # so a later archive knows its owner even with nothing new this turn
    if ($state.pendingTranscript -ne $transcriptPath) {
        $state.pendingTranscript = $transcriptPath
        Save-State $state
    }
    exit 0
}

Append-Messages $new
if ($state.pendingTranscript -ne $transcriptPath) {
    $state.pendingTranscript = $transcriptPath
    Save-State $state
}
exit 0
