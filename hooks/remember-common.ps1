# remember-common.ps1 — shared helpers for the remember memory system hooks. (v2)
# v2 core invariant: every transcript message is archived at most once.
#   - _state.json keeps a per-transcript watermark (last archived msg uuid).
#   - Get-NewMessages filters out everything <= watermark, so a rebuilt
#     _pending.md can never re-feed already-archived messages.
#   - Archive-time content-hash dedup is the belt-and-suspenders backstop.
# dot-source from auto-save.ps1 / archive-pending.ps1 / load-last-chat.ps1

$ErrorActionPreference = 'Stop'

# --- Configuration -------------------------------------------------------
# remember.config.json sits next to this script. Fields:
#   personaName   assistant label written into archives (default "Assistant")
#   marker        prefix printed by load-last-chat so the model recognizes the
#                 injected memory block (default "不忘")
#   chatlogRoot   absolute path override for the chatlog directory; when unset,
#                 it is derived from this script's location
# Environment variables REMEMBER_PERSONA / REMEMBER_MARKER /
# REMEMBER_CHATLOG_ROOT override the config file.
$Script:Config = @{ personaName = 'Assistant'; marker = '【不忘】'; chatlogRoot = $null }

function Get-Config {
    $cfg = @{ personaName = 'Assistant'; marker = '【不忘】'; chatlogRoot = $null }
    $cfgPath = Join-Path $PSScriptRoot 'remember.config.json'
    if (Test-Path $cfgPath) {
        try {
            $j = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.personaName) { $cfg.personaName = [string]$j.personaName }
            if ($j.marker) { $cfg.marker = [string]$j.marker }
            if ($j.chatlogRoot) { $cfg.chatlogRoot = [string]$j.chatlogRoot }
        } catch {}
    }
    if ($env:REMEMBER_PERSONA) { $cfg.personaName = $env:REMEMBER_PERSONA }
    if ($env:REMEMBER_MARKER) { $cfg.marker = $env:REMEMBER_MARKER }
    if ($env:REMEMBER_CHATLOG_ROOT) { $cfg.chatlogRoot = $env:REMEMBER_CHATLOG_ROOT }
    return $cfg
}
$Script:Config = Get-Config

# --- Parse hook stdin once (transcript_path / session_id / cwd). ---
# Only present when run as a Claude Code hook; empty on manual runs.
# Bounded read: a real hook closes stdin after writing the JSON, so this
# returns instantly. A manual run through a shell that holds stdin open must
# NOT block forever — wait 3s then proceed without hook data.
$Script:HookData = $null
if ([Console]::IsInputRedirected) {
    $stdin = $null
    try {
        $task = [System.Threading.Tasks.Task]::Run([Func[string]]{ [Console]::In.ReadToEnd() })
        if ($task.Wait(3000)) { $stdin = $task.Result }
    } catch {
        # Windows PowerShell 5.1 cannot read Console.In from a thread-pool
        # thread (the Task faults immediately). Fall back to a direct read:
        # Claude Code closes stdin after writing the hook JSON, so this returns
        # without blocking in real hook runs.
        try { $stdin = [Console]::In.ReadToEnd() } catch {}
    }
    if ($stdin) {
        try { $Script:HookData = $stdin | ConvertFrom-Json } catch {}
    }
}

# Chatlog root: config override wins; otherwise derived from this script's
# location - the default layout expects hooks at <project>\.claude\scripts\
# and memory at <project>\.claude\memory\chatlog.
if ($Script:Config.chatlogRoot) {
    $Script:ChatlogRoot = $Script:Config.chatlogRoot
} else {
    $Script:ChatlogRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.claude\memory\chatlog'
}
$Script:PendingFile = Join-Path $Script:ChatlogRoot '_pending.md'
$Script:StateFile   = Join-Path $Script:ChatlogRoot '_state.json'

# Claude Code stores transcripts under <CLAUDE_CONFIG_DIR>\projects\<project>\
function Get-ProjectsRoot {
    if ($env:CLAUDE_CONFIG_DIR -and (Test-Path (Join-Path $env:CLAUDE_CONFIG_DIR 'projects'))) {
        return (Join-Path $env:CLAUDE_CONFIG_DIR 'projects')
    }
    return (Join-Path $HOME '.claude\projects')
}

# Map the hook's working directory to a Claude Code project dir name (D:\Fuyu -> D--Fuyu).
function Get-ProjectScope {
    $cwd = $null
    if ($Script:HookData -and $Script:HookData.cwd) { $cwd = $Script:HookData.cwd }
    if (-not $cwd) { $cwd = $env:PWD }
    if (-not $cwd) { try { $cwd = (Get-Location).Path } catch {} }
    if (-not $cwd) { return $null }
    return (($cwd -replace ':', '') -replace '[\\/]+', '--')
}

# Locate the newest session transcript (.jsonl) INSIDE THE CURRENT PROJECT ONLY.
# Never scan the whole projects root: a global "newest file" grabs another project's session.
function Get-TranscriptFile {
    $projects = Get-ProjectsRoot
    if (-not (Test-Path $projects)) { return $null }
    $scope = Get-ProjectScope
    if ($scope) {
        $projDir = Join-Path $projects $scope
        if (Test-Path $projDir) {
            # Subagent transcripts live under subagents\ and must never be picked
            # as "the session" — the owner transcript is the one Claude Code
            # passes via hook stdin (or the newest non-subagent file).
            $candidates = Get-ChildItem $projDir -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
                          Where-Object { $_.FullName -notmatch '\\subagents\\' }
            if ($candidates) {
                return ($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
            }
        }
    }
    return $null
}

# Extract plain text out of a Claude transcript message.content (string | array of blocks)
function Extract-Text {
    param($content)
    if ($null -eq $content) { return '' }
    if ($content -is [string]) { return $content }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $content) {
        if ($c.type -eq 'text' -and $c.text) { [void]$sb.Append($c.text) }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# _state.json — per-transcript watermark
# ---------------------------------------------------------------------------

function Get-State {
    if (Test-Path $Script:StateFile) {
        try {
            $s = Get-Content $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $arch = @{}
            if ($s.archived) {
                $s.archived.PSObject.Properties | ForEach-Object { $arch[$_.Name] = $_.Value }
            }
            return [PSCustomObject]@{ pendingTranscript = $s.pendingTranscript; archived = $arch }
        } catch {}
    }
    return [PSCustomObject]@{ pendingTranscript = $null; archived = @{} }
}

function Save-State {
    param($State)
    New-Item -ItemType Directory -Path $Script:ChatlogRoot -Force | Out-Null
    $json = $State | ConvertTo-Json -Depth 6 -Compress
    [System.IO.File]::WriteAllText($Script:StateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Read the archived watermark (last archived msg uuid) for a transcript out of
# state. Single place both hooks consult so the keying can't drift apart.
function Get-Watermark {
    param($State, [string]$TranscriptPath)
    if ($TranscriptPath -and $State.archived -and $State.archived[$TranscriptPath]) {
        return [string]$State.archived[$TranscriptPath]
    }
    return $null
}

# ---------------------------------------------------------------------------
# Content hashing (archive dedup + load dedup)
# ---------------------------------------------------------------------------

function Get-BodyHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

# Read the first-line content hash out of an archive's raw content (null if legacy).
function Get-ArchiveHash {
    param([string]$Content)
    if ($Content -match '(?m)^<!--\s*h:([0-9a-f]{40})\s*-->') { return $Matches[1] }
    return $null
}

# ---------------------------------------------------------------------------
# Get-NewMessages — collect transcript messages not yet in _pending.md,
# skipping everything <= the watermark (last archived uuid for this transcript).
# ---------------------------------------------------------------------------

function Get-NewMessages {
    param(
        [string]$TranscriptPath,
        [string]$PendingPath,
        [string]$SkipUpToUuid = $null
    )
    $existing = @{}
    if (Test-Path $PendingPath) {
        Get-Content $PendingPath -Encoding UTF8 | ForEach-Object {
            if ($_ -match '^\[msg:([0-9a-fA-F\-]+)\]') { $existing[$Matches[1]] = $true }
        }
    }
    $new = @()
    if (-not (Test-Path $TranscriptPath)) { return ,$new }

    if ([string]::IsNullOrEmpty($SkipUpToUuid)) {
        $lines = Get-Content $TranscriptPath -Encoding UTF8 -Tail 2000
    } else {
        # A tail is enough to locate the watermark in steady state. If the
        # watermark uuid isn't in the tail (transcript rotated/regenerated),
        # startIdx stays 0 and every tail message is newer than the watermark
        # anyway — so collecting the tail is still safe. Bounds the per-turn
        # Stop-hook cost instead of re-reading the whole growing transcript.
        $lines = Get-Content $TranscriptPath -Encoding UTF8 -Tail 4000
    }

    $records = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records += ($line | ConvertFrom-Json) } catch {}
    }

    # If the watermark uuid isn't found (transcript rotated/regenerated), startIdx
    # stays 0 -> collect all; the archive-time content-hash dedup is the backstop.
    $startIdx = 0
    if (-not [string]::IsNullOrEmpty($SkipUpToUuid)) {
        for ($i = 0; $i -lt $records.Count; $i++) {
            if ($records[$i].uuid -and $records[$i].uuid.ToString() -eq $SkipUpToUuid) {
                $startIdx = $i + 1
                break
            }
        }
    }

    for ($i = $startIdx; $i -lt $records.Count; $i++) {
        $rec = $records[$i]
        if (-not $rec.uuid) { continue }
        $id = $rec.uuid.ToString()
        if ($existing[$id]) { continue }
        $msg = $rec.message
        if (-not $msg -or -not $msg.role) { continue }
        if ($msg.role -ne 'user' -and $msg.role -ne 'assistant') { continue }

        # --- system/command noise filter: skip ONLY the injection markers and
        #     skill docs themselves (<command-...>, <local-command-...>, isMeta).
        #     The assistant's real narration DURING a command is still journaled
        #     — the memory must keep the whole conversation, not drop phases.
        if ($msg.role -eq 'user') {
            $text = Extract-Text $msg.content
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $isSlashCmd = $text -match '^\s*/\w+(\s|$)'
            $isSkillInj  = $text -like '*Base directory for this skill:*'
            $isCmdMsg    = ($text -match '^\s*<command-(message|name)>') -or ($text -match '^\s*<local-command-')
            $isMeta      = $rec.isMeta -eq $true
            if ($isSlashCmd -or $isSkillInj -or $isCmdMsg -or $isMeta) { continue }
        } else {
            $text = Extract-Text $msg.content
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $ts = $rec.timestamp
        if (-not $ts) {
            $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        } else {
            # transcript timestamps are UTC (ISO 8601 with Z) — convert to local time
            try {
                $dt = [datetime]::Parse([string]$ts, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                $ts = $dt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            } catch {
                $ts = ([string]$ts).Substring(0, 19).Replace('T', ' ')
            }
        }
        $new += [PSCustomObject]@{
            uuid      = $id
            role      = $msg.role
            timestamp = $ts
            text      = $text
        }
        $existing[$id] = $true
    }
    # Wrap so an EMPTY result still returns a real (Count=0) array.
    return ,$new
}

# ---------------------------------------------------------------------------
# _pending.md append helpers
# ---------------------------------------------------------------------------

# Format a message as a _pending.md [msg:UUID] block (multi-line text preserved)
function Format-MsgBlock {
    param($msg)
    if ($msg.role -eq 'user') { $name = 'User' }
    else { $name = "Assistant $($Script:Config.personaName)" }
    return "[msg:$($msg.uuid)]`n**$name** ($($msg.timestamp)):`n$($msg.text)"
}

# Append transcript messages to _pending.md (creates header for a new file).
function Append-Messages {
    param($Messages)
    New-Item -ItemType Directory -Path $Script:ChatlogRoot -Force | Out-Null
    $sb = New-Object System.Text.StringBuilder
    if (-not (Test-Path $Script:PendingFile)) {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        [void]$sb.AppendLine("# Auto-save -- $today")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('> Generated by auto-save. Cleared after formal archive.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---')
        [void]$sb.AppendLine('')
    }
    foreach ($m in $Messages) {
        [void]$sb.AppendLine((Format-MsgBlock $m))
        [void]$sb.AppendLine('')
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Script:PendingFile, $sb.ToString(), $utf8)
}

# ---------------------------------------------------------------------------
# Resolve the transcript path from hook stdin JSON. Falls back to the current
# project's newest .jsonl — never a global "newest" (that crosses projects).
# ---------------------------------------------------------------------------

function Resolve-TranscriptPath {
    $hookData = $Script:HookData
    $result = $null
    if ($hookData -and $hookData.transcript_path -and (Test-Path $hookData.transcript_path)) {
        $result = $hookData.transcript_path
    }
    if (-not $result -and $hookData -and $hookData.session_id) {
        $projects = Get-ProjectsRoot
        $roots = @($projects)
        $scope = Get-ProjectScope
        if ($scope) {
            $scoped = Join-Path $projects $scope
            if (Test-Path $scoped) { $roots = @($scoped) }
        }
        foreach ($root in $roots) {
            $hit = Get-ChildItem $root -Recurse -Filter "$($hookData.session_id).jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $result = $hit.FullName; break }
        }
    }
    if (-not $result) {
        $tf = Get-TranscriptFile
        if ($tf) { $result = $tf.FullName }
    }
    # Canonicalize to forward slashes so the watermark key in _state.json never
    # flips between hook JSON (forward) and .FullName (backslash) spellings of
    # the same file across sessions — a flip would silently re-archive.
    if ($result) { $result = $result.Replace('\', '/') }
    return $result
}

# ---------------------------------------------------------------------------
# Index — rebuilt completely from disk (never maintained incrementally).
# ---------------------------------------------------------------------------

function Get-Summary {
    param([string]$Path)
    try {
        $found = $false
        foreach ($ln in (Get-Content $Path -Encoding UTF8 -TotalCount 200)) {
            if ($ln -match '^\*\*User\*\*:') { $found = $true; continue }
            if ($found) {
                $t = ($ln -replace '\s+', ' ').Trim()
                if ($t) {
                    if ($t.Length -gt 15) { return $t.Substring(0, 15) }
                    return $t
                }
            }
        }
    } catch {}
    return ''
}

function Rebuild-Index {
    $indexFile = Join-Path $Script:ChatlogRoot 'CHATLOG_INDEX.md'
    $all = @(Get-ChildItem $Script:ChatlogRoot -Recurse -Filter *.md -ErrorAction SilentlyContinue |
             Where-Object { $_.Directory.Name -match '^\d{8}$' -and $_.Name -ne '_pending.md' -and $_.Name -ne 'CHATLOG_INDEX.md' } |
             Sort-Object FullName -Descending)

    $out = New-Object System.Text.StringBuilder
    [void]$out.AppendLine('# CHATLOG_INDEX')
    [void]$out.AppendLine('')

    $last5 = @()
    foreach ($f in $all) {
        if ($last5.Count -lt 5) { $last5 += "$($f.Directory.Name)/$($f.Name)" }
    }
    [void]$out.AppendLine("last5: $($last5 -join ', ')")
    [void]$out.AppendLine('')

    $grouped = $all | Group-Object { $_.Directory.Name } | Sort-Object Name -Descending
    foreach ($g in $grouped) {
        [void]$out.AppendLine("## $($g.Name)")
        [void]$out.AppendLine('')
        foreach ($f in ($g.Group | Sort-Object Name -Descending)) {
            $hh = $f.BaseName.Substring(0, 2); $mm = $f.BaseName.Substring(2, 2)
            [void]$out.AppendLine("- $hh`:$mm | $($f.Name) | $(Get-Summary $f.FullName)")
        }
        [void]$out.AppendLine('')
    }

    New-Item -ItemType Directory -Path $Script:ChatlogRoot -Force | Out-Null
    [System.IO.File]::WriteAllText($indexFile, $out.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}
