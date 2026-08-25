# install.ps1 —— 把 remember 记忆系统安装进一个 Claude Code 项目。
#
# 用法：
#   .\install.ps1 -ProjectDir D:\path\to\project -PersonaName "Assistant"
#   .\install.ps1 -ProjectDir D:\path\to\project -PersonaName "Assistant" -ApplySettings
#
# -ApplySettings 会把 SessionStart/Stop/SessionEnd 钩子合并进项目的
# .claude\settings.local.json（先备份）。不加时只复制文件并打印需要
# 手动粘贴的配置片段。

param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$PersonaName = 'Assistant',
    [string]$Marker = '【不忘】',
    [switch]$ApplySettings,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$tplRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hooksSrc = Join-Path $tplRoot 'hooks'
$skillSrc = Join-Path $tplRoot 'SKILL.md'

if (-not (Test-Path $ProjectDir)) { throw "找不到项目目录: $ProjectDir" }
$ProjectDir = (Resolve-Path $ProjectDir).Path

$scriptsDir = Join-Path $ProjectDir '.claude\scripts'
$skillDir   = Join-Path $ProjectDir '.claude\skills\remember'
$memoryDir  = Join-Path $ProjectDir '.claude\memory\chatlog'
New-Item -ItemType Directory -Force -Path $scriptsDir, $skillDir, $memoryDir | Out-Null

Write-Host "正在安装 remember 到 $ProjectDir"

# 1. Hook scripts
foreach ($f in (Get-ChildItem $hooksSrc -Filter *.ps1)) {
    $dest = Join-Path $scriptsDir $f.Name
    if ((Test-Path $dest) -and -not $Force) {
        Write-Host "  跳过已存在: $($f.Name)（加 -Force 覆盖）"
    } else {
        Copy-Item $f.FullName $dest -Force
        Write-Host "  已复制钩子: $($f.Name)"
    }
}

# 2. Skill definition
$skillDest = Join-Path $skillDir 'SKILL.md'
if ((Test-Path $skillDest) -and -not $Force) {
    Write-Host "  跳过已存在 skill: SKILL.md（加 -Force 覆盖）"
} else {
    Copy-Item $skillSrc $skillDest -Force
    Write-Host "  已复制 skill: SKILL.md"
}

# 3. Config file
$cfgFile = Join-Path $scriptsDir 'remember.config.json'
if ((Test-Path $cfgFile) -and -not $Force) {
    Write-Host "  保留现有配置: remember.config.json"
} else {
    $cfg = @{ personaName = $PersonaName; marker = $Marker; chatlogRoot = $null } | ConvertTo-Json
    [System.IO.File]::WriteAllText($cfgFile, $cfg, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  已写入配置: remember.config.json"
}

# 4. Hook settings snippet
$hooksJson = @{
    SessionStart = @(
        @{ hooks = @(
            @{ type = 'command'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptsDir\archive-pending.ps1`""; timeout = 60 },
            @{ type = 'command'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptsDir\load-last-chat.ps1`""; timeout = 60 }
        ) }
    )
    Stop = @(
        @{ hooks = @(
            @{ type = 'command'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptsDir\auto-save.ps1`""; timeout = 30 }
        ) }
    )
    SessionEnd = @(
        @{ hooks = @(
            @{ type = 'command'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptsDir\archive-pending.ps1`""; timeout = 60 }
        ) }
    )
}

$settingsFile = Join-Path $ProjectDir '.claude\settings.local.json'
if ($ApplySettings) {
    if (Test-Path $settingsFile) {
        $backup = "$settingsFile.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item $settingsFile $backup
        Write-Host "  已备份设置到: $backup"
    }
    $existing = @{}
    if (Test-Path $settingsFile) {
        try { $existing = @(Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    $merged = @{}
    if ($existing -and $existing[0].PSObject.Properties) {
        $existing[0].PSObject.Properties | ForEach-Object { $merged[$_.Name] = $_.Value }
    }
    $merged['hooks'] = $hooksJson
    $merged | ConvertTo-Json -Depth 8 | Set-Content $settingsFile -Encoding UTF8
    Write-Host "  已写入设置: $settingsFile"
} else {
    Write-Host ""
    Write-Host "把以下内容加到 $settingsFile（或加 -ApplySettings 重跑）："
    Write-Host ""
    $merged = @{}
    $merged['hooks'] = $hooksJson
    Write-Host ($merged | ConvertTo-Json -Depth 8)
}

Write-Host ""
Write-Host "完成。请在 $ProjectDir 重启 Claude Code 生效。"
Write-Host "随时可运行 .claude\scripts\check-memory.ps1 体检。"
