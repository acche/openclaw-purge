[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Aggressive,
    [switch]$NoCli,
    [switch]$AllowNpx,
    [string[]]$RepoPath = @()
)

$ErrorActionPreference = "Stop"
$script:Changes = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Write-Step {
    param([string]$Message)
    Write-Host "[step] $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[info] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[warn] $Message" -ForegroundColor Yellow
    $script:Warnings.Add($Message) | Out-Null
}

function Add-Change {
    param([string]$Message)
    $script:Changes.Add($Message) | Out-Null
}

function Invoke-Destructive {
    param(
        [scriptblock]$Action,
        [string]$Description
    )

    if ($DryRun) {
        Write-Host "[dry-run] $Description"
        return
    }

    & $Action
}

function Remove-Target {
    param(
        [string]$Path,
        [string]$Label = $Path
    )

    if (Test-Path -LiteralPath $Path) {
        try {
            Invoke-Destructive -Description "Remove-Item -LiteralPath `"$Path`" -Recurse -Force" -Action {
                Remove-Item -LiteralPath $Path -Recurse -Force
            }
            Write-Ok "removed $Label"
            Add-Change $Label
        } catch {
            Write-Warn "failed to remove $Label"
        }
    }
}

function Confirm-Run {
    if ($Yes -or $DryRun) {
        return
    }

    $answer = Read-Host "This will remove local OpenClaw data from this machine. Continue? [y/N]"
    if ($answer -notmatch '^(?i:y|yes)$') {
        Write-Info "aborted"
        exit 0
    }
}

function Try-CliUninstall {
    if ($NoCli) {
        return
    }

    $cmd = Get-Command openclaw -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Info "openclaw CLI not found; using manual cleanup only"
        if ($AllowNpx -and (Get-Command npx -ErrorAction SilentlyContinue)) {
            Write-Step "running npx fallback uninstaller"
            if ($DryRun) {
                Write-Host "[dry-run] npx -y openclaw uninstall --all --yes --non-interactive"
                Add-Change "npx -y openclaw uninstall --all --yes --non-interactive"
                return
            }

            try {
                & npx -y openclaw uninstall --all --yes --non-interactive
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "npx fallback uninstall finished"
                    Add-Change "npx -y openclaw uninstall --all --yes --non-interactive"
                } else {
                    Write-Warn "npx fallback uninstall failed; continuing with manual cleanup"
                }
            } catch {
                Write-Warn "npx fallback uninstall failed; continuing with manual cleanup"
            }
        }
        return
    }

    Write-Step "running built-in OpenClaw uninstall"
    if ($DryRun) {
        Write-Host "[dry-run] openclaw uninstall --all --yes --non-interactive"
        Add-Change "openclaw uninstall --all --yes --non-interactive"
        return
    }

    try {
        & openclaw uninstall --all --yes --non-interactive
        Write-Ok "built-in uninstall finished"
        Add-Change "openclaw uninstall --all --yes --non-interactive"
    } catch {
        Write-Warn "built-in uninstall failed; continuing with manual cleanup"
    }
}

function Try-PackageUninstall {
    if ($NoCli) {
        return
    }

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        & npm ls -g --depth=0 openclaw *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Step "removing global npm package"
            Invoke-Destructive -Description "npm rm -g openclaw" -Action { & npm rm -g openclaw }
            Write-Ok "removed global npm package"
            Add-Change "npm rm -g openclaw"
        }
    }

    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        & pnpm list -g --depth 0 openclaw *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Step "removing global pnpm package"
            Invoke-Destructive -Description "pnpm remove -g openclaw" -Action { & pnpm remove -g openclaw }
            Write-Ok "removed global pnpm package"
            Add-Change "pnpm remove -g openclaw"
        }
    }

    if (Get-Command bun -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Write-Host "[dry-run] bun remove -g openclaw"
            Add-Change "bun remove -g openclaw"
        } else {
            try {
                & bun remove -g openclaw *> $null
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "removed global bun package"
                    Add-Change "bun remove -g openclaw"
                }
            } catch {
            }
        }
    }
}

function Remove-ScheduledTasks {
    Write-Step "cleaning scheduled tasks"

    try {
        $tasks = Get-ScheduledTask | Where-Object { $_.TaskName -like 'OpenClaw Gateway*' }
    } catch {
        Write-Warn "could not enumerate scheduled tasks; continuing"
        return
    }

    foreach ($task in $tasks) {
        $taskName = $task.TaskName
        $taskPath = $task.TaskPath
        Invoke-Destructive -Description "Unregister-ScheduledTask -TaskName `"$taskName`" -TaskPath `"$taskPath`" -Confirm:`$false" -Action {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
        }
        Write-Ok "removed scheduled task $taskPath$taskName"
        Add-Change "scheduled task $taskPath$taskName"
    }
}

function Aggressive-Scan {
    Write-Step "aggressive scan in known Windows app-data roots"

    $roots = @($env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)openclaw' -or $_.Name -match '^(?i:ai\.openclaw|com\.openclaw)' } |
            ForEach-Object {
                Remove-Target -Path $_.FullName
            }
    }
}

function Remove-RepoPaths {
    if ($RepoPath.Count -eq 0) {
        return
    }

    Write-Step "removing explicit source checkout paths"
    foreach ($rawPath in $RepoPath) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }

        try {
            $resolved = (Resolve-Path -LiteralPath $rawPath -ErrorAction Stop).ProviderPath
        } catch {
            Write-Warn "repo path not found: $rawPath"
            continue
        }

        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            Write-Warn "repo path is not a directory: $resolved"
            continue
        }

        $trimmed = $resolved.TrimEnd('\', '/')
        $homeDir = $HOME.TrimEnd('\', '/')
        if ($trimmed -eq '' -or $trimmed -eq '\' -or $trimmed -eq '/' -or $trimmed.Equals($homeDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warn "refusing to remove unsafe repo path: $resolved"
            continue
        }

        Remove-Target -Path $resolved -Label "$resolved (source checkout)"
    }
}

function Print-Summary {
    Write-Host ""
    Write-Info "summary"
    Write-Host "  mode: $(if ($DryRun) { 'dry-run' } else { 'live' })"
    Write-Host "  changed targets: $($script:Changes.Count)"
    foreach ($item in $script:Changes) {
        Write-Host "    - $item"
    }
    if ($script:Warnings.Count -gt 0) {
        Write-Host "  warnings: $($script:Warnings.Count)"
    }
    Write-Host ""
    Write-Info "if OpenClaw used a remote gateway, run this script on that gateway host too"
}

$StateDir = if ($env:OPENCLAW_STATE_DIR) { $env:OPENCLAW_STATE_DIR } else { Join-Path $HOME '.openclaw' }

Write-Info "OpenClaw Purge 0.2.0"
Confirm-Run
Try-CliUninstall
Remove-ScheduledTasks
Remove-RepoPaths

if ($env:OPENCLAW_CONFIG_PATH) {
    $configPath = $env:OPENCLAW_CONFIG_PATH
    $statePrefix = $StateDir.TrimEnd('\', '/')
    $isStatePath =
        $configPath.Equals($statePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $configPath.StartsWith("$statePrefix\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $configPath.StartsWith("$statePrefix/", [System.StringComparison]::OrdinalIgnoreCase)

    if (-not $isStatePath) {
        Remove-Target -Path $configPath -Label "$configPath (OPENCLAW_CONFIG_PATH)"
    }
}

Remove-Target -Path (Join-Path $StateDir 'gateway.cmd')
Remove-Target -Path (Join-Path $StateDir 'workspace')
Remove-Target -Path $StateDir

Get-ChildItem -Path $HOME -Directory -Filter '.openclaw-*' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Target -Path (Join-Path $_.FullName 'gateway.cmd')
    Remove-Target -Path (Join-Path $_.FullName 'workspace')
    Remove-Target -Path $_.FullName
}

Remove-Target -Path (Join-Path $env:APPDATA 'OpenClaw')
Remove-Target -Path (Join-Path $env:LOCALAPPDATA 'OpenClaw')
Remove-Target -Path (Join-Path $env:LOCALAPPDATA 'Programs\OpenClaw')

Get-ChildItem -Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') -Filter 'OpenClaw*' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Target -Path $_.FullName
}

Try-PackageUninstall

if ($Aggressive) {
    Aggressive-Scan
}

Print-Summary
