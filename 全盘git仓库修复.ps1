param(
    [string]$Drive,
    [int]$MaxDepth = 5,
    [switch]$SkipNetwork
)

$ErrorActionPreference = "SilentlyContinue"

function Write-Step  { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "  [ERR] $msg" -ForegroundColor Red }
function Write-Info  { param($msg) Write-Host "  $msg" -ForegroundColor Gray }
function Write-Del   { param($msg) Write-Host "  [DEL] $msg" -ForegroundColor Magenta }

function Confirm-Action {
    param([string]$Message, [bool]$DefaultYes = $true)
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $response = Read-Host "$Message $suffix"
    if ([string]::IsNullOrWhiteSpace($response)) { return $DefaultYes }
    return ($response -match "^[yY]")
}

function Confirm-Choice {
    param([string]$Message, [string[]]$Options)
    Write-Host $Message -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i+1)] $($Options[$i])"
    }
    $choice = Read-Host "Select (1-$($Options.Count))"
    $idx = [int]$choice - 1
    if ($idx -ge 0 -and $idx -lt $Options.Count) { return $idx }
    return 0
}

# Run git command with timeout (seconds). Returns output string or $null on timeout.
function Invoke-GitWithTimeout {
    param([string]$RepoPath, [string[]]$GitArgs, [int]$TimeoutSec = 20)
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "git"
        $psi.Arguments = "-C `"$RepoPath`" $($GitArgs -join ' ')"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        $finished = $proc.WaitForExit($TimeoutSec * 1000)
        if ($finished) {
            [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))
            return @{ Success = $true; Output = "$($stdout.Result)`n$($stderr.Result)"; ExitCode = $proc.ExitCode }
        } else {
            $proc.Kill()
            return @{ Success = $false; Output = ""; ExitCode = -1 }
        }
    } catch {
        return @{ Success = $false; Output = $_.Exception.Message; ExitCode = -1 }
    } finally {
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

# Delete a repo and attempt to re-clone it to the same path.
# $RepoPath: local path, $RemoteUrl: git remote URL (if known)
# Returns: "cloned" | "clone_failed" | "deleted" (no URL to clone)
function Remove-AndReclone {
    param([string]$RepoPath, [string]$RemoteUrl)
    Remove-Item -Recurse -Force $RepoPath -ErrorAction SilentlyContinue
    Write-Del $RepoPath
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        Write-Warn "  No remote URL — cannot re-clone"
        return "deleted"
    }
    # Connectivity check: short timeout to detect network issues
    Write-Info "  Testing connectivity to remote..."
    $probe = Invoke-GitWithTimeout -RepoPath "." -GitArgs @("ls-remote", "--heads", "`"$RemoteUrl`"") -TimeoutSec 15
    if (!$probe.Success) {
        Write-Err "  Network timeout — skipping clone"
        return "clone_failed"
    }
    if ($probe.ExitCode -ne 0) {
        $errLine = ($probe.Output -split "`n" | Where-Object { $_ -match "\S" } | Select-Object -Last 1)
        Write-Err "  Remote unreachable: $errLine"
        return "clone_failed"
    }
    # Network is good — clone without time limit (large repos may take a while)
    Write-Info "  Cloning: $RemoteUrl -> $RepoPath (no time limit)"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = "clone `"$RemoteUrl`" `"$RepoPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))
        if ($proc.ExitCode -eq 0) {
            Write-Ok "  Re-cloned successfully"
            return "cloned"
        } else {
            $errLine = ($stderr.Result -split "`n" | Where-Object { $_ -match "\S" } | Select-Object -Last 1)
            Write-Err "  Clone failed: $errLine"
            return "clone_failed"
        }
    } catch {
        Write-Err "  Clone error: $($_.Exception.Message)"
        return "clone_failed"
    }
}

# ============================================================
# Main
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Git Disk Repair Tool (Post OS Reinstall)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ([string]::IsNullOrWhiteSpace($Drive)) {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 } | Select-Object -ExpandProperty Name
    Write-Host "Available drives:" -ForegroundColor Yellow
    foreach ($d in $drives) { Write-Host "  [$d] $($d):\" }
    $Drive = Read-Host "`nDrive letter (e.g. W)"
}
$Drive = $Drive.TrimEnd(":", "\")
$root = "${Drive}:\"
if (!(Test-Path $root)) {
    Write-Err "Drive $root not found"
    exit 1
}
Write-Host "Target: $root  Depth: $MaxDepth" -ForegroundColor White

# ============================================================
# STEP 1: Global Git/SSH config + DNS fix
# ============================================================
Write-Step "STEP 1: Global Git/SSH config"

# --- safe.directory ---
$safeDir = git config --global --get-all safe.directory 2>$null
if ($safeDir -contains "*") {
    Write-Ok "safe.directory already has wildcard *"
} else {
    if (Confirm-Action "Add safe.directory=* to fix dubious ownership errors?") {
        git config --global --add safe.directory "*"
        Write-Ok "Added safe.directory=*"
    } else {
        Write-Warn "Skipped safe.directory"
    }
}

# --- SSH config ---
$sshDir = "$env:USERPROFILE\.ssh"
$sshConfigPath = "$sshDir\config"
if (!(Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

if (Test-Path $sshConfigPath) {
    Write-Info "Current SSH config:"
    Get-Content $sshConfigPath | ForEach-Object { Write-Info "  $_" }
}

if (Confirm-Action "Check and fix SSH config?") {
    $currentContent = ""
    if (Test-Path $sshConfigPath) {
        $currentContent = Get-Content $sshConfigPath -Raw
    }
    $needFix = $false

    if ($currentContent -match "UserKnownHostsFile\s+(NUL|/dev/null)") {
        Write-Warn "UserKnownHostsFile points to NUL - keys cannot persist"
        $needFix = $true
    }
    if ($currentContent -match "StrictHostKeyChecking\s+no\b") {
        if ($currentContent -notmatch "StrictHostKeyChecking\s+accept-new") {
            Write-Warn "StrictHostKeyChecking=no found, should be accept-new"
            $needFix = $true
        }
    }

    $isEmpty = [string]::IsNullOrWhiteSpace($currentContent)
    if ($needFix -or $isEmpty) {
        $hostsInput = Read-Host "  SSH hosts to auto-accept (comma separated, e.g. github.com,codeup.aliyun.com)"
        if (![string]::IsNullOrWhiteSpace($hostsInput)) {
            $sshHosts = $hostsInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
            $lines = @()
            foreach ($h in $sshHosts) {
                $lines += "Host $h"
                $lines += "    StrictHostKeyChecking accept-new"
                $lines += ""
            }
            Set-Content -Path $sshConfigPath -Value ($lines -join "`r`n") -Encoding UTF8
            Write-Ok "SSH config updated"
        }
    } else {
        Write-Ok "SSH config looks good"
    }
}

# --- core.sshCommand ---
$sshCmd = git config --global core.sshCommand 2>$null
if ($sshCmd -match "StrictHostKeyChecking") {
    Write-Warn "core.sshCommand has StrictHostKeyChecking override"
    if (Confirm-Action "Reset to default SSH command?") {
        git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
        Write-Ok "Restored core.sshCommand"
    }
} else {
    Write-Ok "core.sshCommand is fine"
}

# --- DNS hijack detection for HTTPS domains ---
Write-Host ""
Write-Info "Checking DNS resolution for common HTTPS git hosts..."
$httpsHosts = @("github.com", "gitlab.com", "bitbucket.org")
# 198.18.0.0/15 is reserved for benchmarking, often used by DNS-based proxies
$fakeRanges = @("198.18.", "198.19.", "127.0.0.", "0.0.0.0")
$dnsFixed = @()

foreach ($h in $httpsHosts) {
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($h) | Select-Object -First 1
        $ip = $resolved.IPAddressToString
        $isFake = $false
        foreach ($prefix in $fakeRanges) {
            if ($ip.StartsWith($prefix)) { $isFake = $true; break }
        }
        if ($isFake) {
            Write-Warn "$h resolves to $ip (fake/hijacked IP)"
            # Try to get real IP via public DNS
            $nslookup = nslookup $h 8.8.8.8 2>&1 | Out-String
            if ($nslookup -match "Address:\s+([\d\.]+)\s*$" -or $nslookup -match "Addresses:\s+([\d\.]+)") {
                $realIp = $Matches[1]
                # Verify it's not also fake
                $stillFake = $false
                foreach ($prefix in $fakeRanges) {
                    if ($realIp.StartsWith($prefix)) { $stillFake = $true; break }
                }
                if (!$stillFake -and $realIp -ne $ip) {
                    Write-Info "Real IP from Google DNS: $realIp"
                    if (Confirm-Action "Fix git DNS for $h ? (curloptResolve -> $realIp)") {
                        git config --global "http.https://${h}/.curloptResolve" "${h}:443:${realIp}"
                        Write-Ok "Set curloptResolve for $h -> $realIp"
                        $dnsFixed += $h
                    }
                } else {
                    Write-Err "Could not get real IP for $h from Google DNS"
                }
            } else {
                Write-Err "nslookup via 8.8.8.8 failed for $h"
            }
        } else {
            Write-Ok "$h -> $ip (looks real)"
        }
    } catch {
        Write-Warn "Cannot resolve $h - skipping"
    }
}
if ($dnsFixed.Count -gt 0) {
    Write-Ok "DNS fix applied for: $($dnsFixed -join ', ')"
    Write-Info "Note: if the real IP changes later, re-run this script or remove with:"
    Write-Info "  git config --global --unset http.https://<host>/.curloptResolve"
}

# ============================================================
# STEP 2: Scan repos
# ============================================================
Write-Step "STEP 2: Scanning ${Drive}:\ for Git repos (depth=$MaxDepth)"

$allGitDirs = Get-ChildItem -Path $root -Filter ".git" -Directory -Recurse -Depth $MaxDepth -Force -ErrorAction SilentlyContinue
$repos = [System.Collections.ArrayList]@()
foreach ($g in $allGitDirs) {
    $repoPath = $g.Parent.FullName
    if ($repoPath -match '\$RECYCLE\.BIN') { continue }
    $isChild = $false
    foreach ($existing in $repos) {
        if ($repoPath.StartsWith("$existing\")) { $isChild = $true; break }
    }
    if (!$isChild) { [void]$repos.Add($repoPath) }
}

Write-Host "  Found $($repos.Count) Git repos" -ForegroundColor White
if ($repos.Count -eq 0) {
    Write-Warn "No repos found"
    exit 0
}

if (Confirm-Action "Show repo list?" $false) {
    foreach ($r in $repos) { Write-Info $r }
}

# ============================================================
# STEP 3: Local repair
# ============================================================
Write-Step "STEP 3: Local repair (lock files + integrity check)"

$localOk = 0
$localLocks = 0
$damagedRepos = [System.Collections.ArrayList]@()

foreach ($repo in $repos) {
    $lockFiles = Get-ChildItem -Path "$repo\.git" -Filter "*.lock" -Recurse -Force -ErrorAction SilentlyContinue
    if ($lockFiles) {
        foreach ($lf in $lockFiles) {
            Remove-Item $lf.FullName -Force -ErrorAction SilentlyContinue
            $localLocks++
        }
    }
    $gitOut = git -C $repo status --short 2>&1 | Out-String
    if ($gitOut -match "fatal") {
        [void]$damagedRepos.Add($repo)
    } else {
        $localOk++
    }
}

Write-Host ""
Write-Host "  Results:" -ForegroundColor White
Write-Host "    OK: $localOk" -ForegroundColor Green
Write-Host "    Damaged: $($damagedRepos.Count)" -ForegroundColor $(if ($damagedRepos.Count -gt 0) { "Red" } else { "Green" })
Write-Host "    Locks removed: $localLocks" -ForegroundColor $(if ($localLocks -gt 0) { "Yellow" } else { "Green" })

if ($damagedRepos.Count -gt 0) {
    Write-Warn "Damaged repos:"
    foreach ($r in $damagedRepos) { Write-Err $r }

    $choice = Confirm-Choice "How to handle damaged repos?" @("Delete and re-clone", "Confirm each", "Skip")
    if ($choice -eq 0) {
        foreach ($r in $damagedRepos) {
            $url = git -C $r remote get-url origin 2>$null
            Remove-AndReclone -RepoPath $r -RemoteUrl $url
        }
    }
    elseif ($choice -eq 1) {
        foreach ($r in $damagedRepos) {
            $url = git -C $r remote get-url origin 2>$null
            $urlHint = if ($url) { " (remote: $url)" } else { " (no remote)" }
            if (Confirm-Action "Delete and re-clone ${r}${urlHint} ?" $false) {
                Remove-AndReclone -RepoPath $r -RemoteUrl $url
            } else {
                Write-Info "Kept: $r"
            }
        }
    }
    else {
        Write-Info "Skipped"
    }
    $repos = [System.Collections.ArrayList]@($repos | Where-Object { Test-Path $_ })
}

# ============================================================
# STEP 4: Network repair (uses direct process, NOT Start-Job)
# ============================================================
if ($SkipNetwork) {
    Write-Step "STEP 4: Skipped (-SkipNetwork)"
} else {
    Write-Step "STEP 4: Network repair (prune + remote verify)"

    if (!(Confirm-Action "Run network repair? (connects to remotes, may be slow)")) {
        Write-Info "Skipped"
    } else {
        $netTimeoutSec = 20
        Write-Info "Timeout per repo: ${netTimeoutSec}s"
        Write-Info "Auto-skips domain after 3 consecutive timeouts"
        Write-Info "Using direct process calls (inherits git config + DNS fixes)"

        # Pre-flight: quick connectivity test per unique domain
        $domainMap = @{}
        foreach ($repo in $repos) {
            $remote = git -C $repo remote get-url origin 2>$null
            $domain = ""
            if ($remote -match "@([^:]+):") { $domain = $Matches[1] }
            elseif ($remote -match "https?://([^/]+)/") { $domain = $Matches[1] }
            if ($domain -ne "" -and !$domainMap.ContainsKey($domain)) {
                $domainMap[$domain] = $repo
            }
        }

        Write-Info "Testing connectivity to $($domainMap.Count) unique domains..."
        $skipDomains = @{}
        foreach ($domain in $domainMap.Keys) {
            Write-Host "  $domain ... " -ForegroundColor Gray -NoNewline
            $testRepo = $domainMap[$domain]
            $result = Invoke-GitWithTimeout -RepoPath $testRepo -GitArgs @("ls-remote", "--heads", "origin") -TimeoutSec 10
            if ($result.Success -and $result.ExitCode -eq 0) {
                Write-Host "ok" -ForegroundColor Green
            } elseif (!$result.Success) {
                Write-Host "timeout - will skip" -ForegroundColor Yellow
                $skipDomains[$domain] = $true
            } else {
                # Non-zero exit but completed - might be auth issue, still try individual repos
                Write-Host "error (will try repos individually)" -ForegroundColor Yellow
            }
        }

        $netOk = 0
        $netPruned = 0
        $netDead = 0
        $netFailed = 0
        $netTimeoutCount = 0
        $netSkipped = 0
        $deadRepos = [System.Collections.ArrayList]@()
        $failedRepos = [System.Collections.ArrayList]@()
        $domainTimeouts = @{}

        for ($i = 0; $i -lt $repos.Count; $i++) {
            $repo = $repos[$i]
            $name = $repo.Replace($root, "")
            $idx = $i + 1

            # Extract domain
            $remote = git -C $repo remote get-url origin 2>$null
            $domain = ""
            if ($remote -match "@([^:]+):") { $domain = $Matches[1] }
            elseif ($remote -match "https?://([^/]+)/") { $domain = $Matches[1] }
            elseif ($name -match "^([^\\]+)\\") { $domain = $Matches[1] }

            # Skip if domain unreachable
            if ($domain -ne "" -and $skipDomains.ContainsKey($domain)) {
                Write-Host "  [$idx/$($repos.Count)] $name" -ForegroundColor DarkGray -NoNewline
                Write-Host " -> skipped ($domain unreachable)" -ForegroundColor DarkGray
                $netSkipped++
                continue
            }

            Write-Host "  [$idx/$($repos.Count)] $name" -ForegroundColor Gray -NoNewline

            # Helper: track consecutive timeouts per domain
            function Add-DomainTimeout {
                if ($domain -ne "") {
                    if (!$domainTimeouts.ContainsKey($domain)) { $domainTimeouts[$domain] = 0 }
                    $domainTimeouts[$domain]++
                    if ($domainTimeouts[$domain] -ge 3) {
                        $skipDomains[$domain] = $true
                        Write-Warn "${domain}: 3 consecutive timeouts, skipping remaining"
                    }
                }
            }

            # --- Prune ---
            $pruneResult = Invoke-GitWithTimeout -RepoPath $repo -GitArgs @("remote", "prune", "origin") -TimeoutSec $netTimeoutSec

            if (!$pruneResult.Success) {
                # Prune timed out
                Write-Host " -> timeout (prune)" -ForegroundColor Yellow
                $netTimeoutCount++
                Add-DomainTimeout
                continue
            }

            # Check if prune output indicates dead remote
            $pruneOut = $pruneResult.Output
            $isDead = $pruneOut -match "Repository (path )?not found|does not exist|Could not read from remote"
            if ($isDead) {
                Write-Host " -> DEAD" -ForegroundColor Red
                [void]$deadRepos.Add(@{ Path = $repo; Url = $remote })
                $netDead++
                continue
            }

            # Prune failed (non-zero exit) but not dead — record as failed
            if ($pruneResult.ExitCode -ne 0) {
                Write-Host " -> failed (prune)" -ForegroundColor Red
                [void]$failedRepos.Add(@{ Path = $repo; Url = $remote; Error = $pruneOut.Trim() })
                $netFailed++
                continue
            }

            # Prune succeeded — reset timeout counter
            if ($domain -ne "") { $domainTimeouts[$domain] = 0 }
            $wasPruned = $pruneOut -match "pruned"

            # --- Fetch dry-run ---
            $fetchResult = Invoke-GitWithTimeout -RepoPath $repo -GitArgs @("fetch", "--dry-run") -TimeoutSec $netTimeoutSec

            if (!$fetchResult.Success) {
                # Fetch timed out — still count prune result
                $suffix = if ($wasPruned) { "pruned, " } else { "" }
                Write-Host " -> ${suffix}timeout (fetch)" -ForegroundColor Yellow
                if ($wasPruned) { $netPruned++ }
                $netTimeoutCount++
                Add-DomainTimeout
                continue
            }

            $fetchOut = $fetchResult.Output
            $isDead = $fetchOut -match "Repository (path )?not found|does not exist|Could not read from remote"
            if ($isDead) {
                Write-Host " -> DEAD" -ForegroundColor Red
                [void]$deadRepos.Add(@{ Path = $repo; Url = $remote })
                $netDead++
                continue
            }

            # Fetch failed (non-zero exit) but not dead
            if ($fetchResult.ExitCode -ne 0) {
                $suffix = if ($wasPruned) { "pruned, " } else { "" }
                Write-Host " -> ${suffix}failed (fetch)" -ForegroundColor Red
                if ($wasPruned) { $netPruned++ }
                [void]$failedRepos.Add(@{ Path = $repo; Url = $remote; Error = $fetchOut.Trim() })
                $netFailed++
                continue
            }

            # Both succeeded
            if ($wasPruned) {
                Write-Host " -> pruned" -ForegroundColor Magenta
                $netPruned++
            } else {
                Write-Host " -> ok" -ForegroundColor Green
            }
            $netOk++
        }

        Write-Host ""
        Write-Host "  Results: OK=$netOk  Pruned=$netPruned  Failed=$netFailed  Timeout=$netTimeoutCount  Skipped=$netSkipped  Dead=$netDead" -ForegroundColor White

        # Merge dead + failed into one cleanup list (exclude timeout/network issues)
        $cleanupRepos = [System.Collections.ArrayList]@()
        foreach ($r in $deadRepos) {
            [void]$cleanupRepos.Add(@{ Path = $r.Path; Url = $r.Url; Reason = "dead remote" })
        }
        foreach ($f in $failedRepos) {
            $errLine = ($f.Error -split "`n" | Where-Object { $_ -match "\S" } | Select-Object -First 1)
            [void]$cleanupRepos.Add(@{ Path = $f.Path; Url = $f.Url; Reason = "failed: $errLine" })
        }

        if ($cleanupRepos.Count -gt 0) {
            Write-Warn "Repos that cannot be repaired ($($cleanupRepos.Count)):"
            foreach ($c in $cleanupRepos) {
                Write-Err "$($c.Path)"
                Write-Info "  Reason: $($c.Reason)"
                if ($c.Url) { Write-Info "  Remote: $($c.Url)" }
            }

            $choice = Confirm-Choice "How to handle unrecoverable repos?" @("Delete and re-clone all", "Confirm each", "Skip")
            if ($choice -eq 0) {
                foreach ($c in $cleanupRepos) {
                    Remove-AndReclone -RepoPath $c.Path -RemoteUrl $c.Url
                }
            }
            elseif ($choice -eq 1) {
                foreach ($c in $cleanupRepos) {
                    $urlHint = if ($c.Url) { " -> re-clone from $($c.Url)" } else { " (no remote)" }
                    if (Confirm-Action "Delete $($c.Path)${urlHint} ? ($($c.Reason))" $false) {
                        Remove-AndReclone -RepoPath $c.Path -RemoteUrl $c.Url
                    } else {
                        Write-Info "Kept: $($c.Path)"
                    }
                }
            }
            else {
                Write-Info "Skipped"
            }
        }
    }
}

# ============================================================
# STEP 5: Submodule sync
# ============================================================
Write-Step "STEP 5: Submodule sync"

$subRepos = @($repos | Where-Object { Test-Path $_ } | Where-Object { Test-Path "$_\.gitmodules" })
if ($subRepos.Count -eq 0) {
    Write-Info "No repos with submodules found"
} else {
    Write-Host "  Found $($subRepos.Count) repos with submodules:" -ForegroundColor White
    foreach ($r in $subRepos) { Write-Info $r }

    if (Confirm-Action "Sync submodules? (git submodule update --init --recursive --force)") {
        foreach ($r in $subRepos) {
            $name = $r.Replace($root, "")
            Write-Host "  Syncing: $name ..." -ForegroundColor Gray -NoNewline
            git -C $r submodule update --init --recursive --force 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host " ok" -ForegroundColor Green
            } else {
                Write-Host " failed" -ForegroundColor Red
            }
        }
    }
}

# ============================================================
# Done
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Repair complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
$sd = git config --global --get-all safe.directory 2>$null
$sc = git config --global core.sshCommand 2>$null
$cr = git config --global --get-regexp "curloptResolve" 2>$null
Write-Host "Global config:" -ForegroundColor White
Write-Host "  safe.directory: $sd"
Write-Host "  core.sshCommand: $sc"
Write-Host "  SSH config: $sshConfigPath"
if ($cr) {
    Write-Host "  DNS overrides:" -ForegroundColor White
    $cr | ForEach-Object { Write-Host "    $_" }
}
Write-Host ""
