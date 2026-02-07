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

# Remove stale remote refs directly from packed-refs when git prune fails.
# This handles the case where prune returns exit 1 and can't fully clean up.
function Repair-PackedRefs {
    param([string]$RepoPath)
    $packedFile = "$RepoPath\.git\packed-refs"
    if (!(Test-Path $packedFile)) { return 0 }

    # Get actual remote branches
    $result = Invoke-GitWithTimeout -RepoPath $RepoPath -GitArgs @("ls-remote", "--heads", "origin") -TimeoutSec 15
    if (!$result.Success -or $result.ExitCode -ne 0) { return -1 }

    $remoteBranches = @{}
    foreach ($line in ($result.Output -split "`n")) {
        if ($line -match "refs/heads/(.+)$") {
            $remoteBranches[$Matches[1].Trim()] = $true
        }
    }

    $lines = [System.IO.File]::ReadAllLines($packedFile)
    $newLines = [System.Collections.ArrayList]@()
    $removed = 0
    $skipNext = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match "refs/remotes/origin/(.+)$") {
            $branch = $Matches[1].Trim()
            if ($branch -eq "HEAD" -or $remoteBranches.ContainsKey($branch)) {
                [void]$newLines.Add($line)
                $skipNext = $false
            } else {
                $removed++
                $skipNext = $true
            }
        } elseif ($line -match "^\^" -and $skipNext) {
            $removed++
        } else {
            [void]$newLines.Add($line)
            $skipNext = $false
        }
    }

    if ($removed -gt 0) {
        $content = ($newLines -join "`n") + "`n"
        [System.IO.File]::WriteAllText($packedFile, $content, (New-Object System.Text.UTF8Encoding $false))
    }
    return $removed
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
            # Try to get real IPv4 via public DNS (Resolve-DnsName is more reliable than nslookup)
            $realIp = $null
            try {
                $dnsResults = Resolve-DnsName -Name $h -Server 8.8.8.8 -Type A -DnsOnly -ErrorAction Stop
                $realIp = ($dnsResults | Where-Object { $_.QueryType -eq "A" } | Select-Object -First 1).IPAddress
            } catch {
                # Fallback to nslookup if Resolve-DnsName fails
                $nslookup = nslookup $h 8.8.8.8 2>&1 | Out-String
                # Match only IPv4 addresses (x.x.x.x), skip IPv6
                $ipv4Matches = [regex]::Matches($nslookup, "Address:\s+((\d{1,3}\.){3}\d{1,3})")
                # Take the last match (first is usually the DNS server itself)
                if ($ipv4Matches.Count -gt 0) {
                    $realIp = $ipv4Matches[$ipv4Matches.Count - 1].Groups[1].Value
                }
            }
            if ($realIp -and $realIp -match "^(\d{1,3}\.){3}\d{1,3}$") {
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
                    Write-Err "Could not get real IPv4 for $h from Google DNS"
                }
            } else {
                Write-Err "No valid IPv4 found for $h via Google DNS (got: $realIp)"
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
    # Skip submodule worktrees: .git/modules/*/config exists but no HEAD at top level
    # Or: parent dir has a .gitmodules that references this path
    $isChild = $false
    foreach ($existing in $repos) {
        if ($repoPath.StartsWith("$existing\")) {
            # It's under an existing repo — check if it's a submodule
            $gitmodulesPath = Join-Path $existing ".gitmodules"
            if (Test-Path $gitmodulesPath) {
                # This is likely a submodule of $existing, skip it
                $isChild = $true; break
            }
            # Even without .gitmodules, it's a nested repo — skip
            $isChild = $true; break
        }
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
        $timeoutRepos = [System.Collections.ArrayList]@()
        $skippedRepos = [System.Collections.ArrayList]@()
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
                [void]$skippedRepos.Add(@{ Path = $repo; Url = $remote; Domain = $domain; Reason = "domain unreachable: $domain" })
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

            # --- Prune (with lock cleanup + retry) ---
            # Clean stale lock files before prune to avoid "cannot lock ref" errors
            Get-ChildItem -Path "$repo\.git\refs" -Filter "*.lock" -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

            $pruneResult = Invoke-GitWithTimeout -RepoPath $repo -GitArgs @("remote", "prune", "origin") -TimeoutSec $netTimeoutSec

            # If prune failed due to lock files (concurrent git), clean and retry once
            if ($pruneResult.Success -and $pruneResult.Output -match "cannot lock ref") {
                Get-ChildItem -Path "$repo\.git\refs" -Filter "*.lock" -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                $pruneResult = Invoke-GitWithTimeout -RepoPath $repo -GitArgs @("remote", "prune", "origin") -TimeoutSec $netTimeoutSec
            }

            if (!$pruneResult.Success) {
                # Prune timed out
                Write-Host " -> timeout (prune)" -ForegroundColor Yellow
                $netTimeoutCount++
                [void]$timeoutRepos.Add(@{ Path = $repo; Url = $remote; Domain = $domain; Reason = "timeout (prune)" })
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

            # Prune with non-zero exit: git returns exit 1 when branches were pruned (known behavior)
            # Only treat as real failure if output contains fatal/error AND no pruned branches
            $wasPruned = $pruneOut -match "\[pruned\]"
            $hasFatal = $pruneOut -match "fatal:|error:"
            if ($pruneResult.ExitCode -ne 0 -and !$wasPruned -and $hasFatal) {
                Write-Host " -> failed (prune)" -ForegroundColor Red
                [void]$failedRepos.Add(@{ Path = $repo; Url = $remote; Error = $pruneOut.Trim() })
                $netFailed++
                continue
            }

            # Prune succeeded (or pruned branches) — reset timeout counter
            if ($domain -ne "") { $domainTimeouts[$domain] = 0 }

            # If prune had exit code 1 (partial cleanup), repair packed-refs directly
            if ($pruneResult.ExitCode -ne 0 -or $wasPruned) {
                $repaired = Repair-PackedRefs -RepoPath $repo
                if ($repaired -gt 0) {
                    $wasPruned = $true
                }
            }

            # --- Fetch dry-run ---
            $fetchResult = Invoke-GitWithTimeout -RepoPath $repo -GitArgs @("fetch", "--dry-run") -TimeoutSec $netTimeoutSec

            if (!$fetchResult.Success) {
                # Fetch timed out — still count prune result
                $suffix = if ($wasPruned) { "pruned, " } else { "" }
                Write-Host " -> ${suffix}timeout (fetch)" -ForegroundColor Yellow
                if ($wasPruned) { $netPruned++ }
                $netTimeoutCount++
                [void]$timeoutRepos.Add(@{ Path = $repo; Url = $remote; Domain = $domain; Reason = "timeout (fetch)" })
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

            # Fetch failed (non-zero exit) but not dead — only fail if truly broken
            $fetchHasFatal = $fetchOut -match "fatal:|error:"
            if ($fetchResult.ExitCode -ne 0 -and $fetchHasFatal) {
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

        # --- Handle dead + failed repos (delete & re-clone) ---
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

        # --- Handle timeout + skipped repos (retry or delete & re-clone) ---
        $needsRetry = [System.Collections.ArrayList]@()
        foreach ($r in $timeoutRepos) { [void]$needsRetry.Add($r) }
        foreach ($r in $skippedRepos) { [void]$needsRetry.Add($r) }

        if ($needsRetry.Count -gt 0) {
            Write-Host ""
            Write-Warn "Repos that timed out or were skipped ($($needsRetry.Count)):"
            foreach ($r in $needsRetry) {
                $name = $r.Path.Replace($root, "")
                Write-Err "  $name ($($r.Reason))"
            }

            $choice = Confirm-Choice "How to handle timeout/skipped repos?" @(
                "Retry with 120s timeout",
                "Delete and re-clone all",
                "Confirm each",
                "Skip"
            )
            if ($choice -eq 0) {
                # Retry with much longer timeout
                foreach ($r in $needsRetry) {
                    $name = $r.Path.Replace($root, "")
                    Write-Host "  Retrying: $name (120s) ..." -ForegroundColor Gray -NoNewline
                    $retry = Invoke-GitWithTimeout -RepoPath $r.Path -GitArgs @("fetch", "--prune") -TimeoutSec 120
                    if ($retry.Success -and ($retry.ExitCode -eq 0 -or $retry.Output -match "\[pruned\]")) {
                        Write-Host " ok" -ForegroundColor Green
                    } elseif (!$retry.Success) {
                        Write-Host " still timeout" -ForegroundColor Red
                        Write-Warn "  Network issue — kept as-is (not a repo error)"
                    } else {
                        Write-Host " failed" -ForegroundColor Red
                        $errLine = ($retry.Output -split "`n" | Where-Object { $_ -match "\S" } | Select-Object -Last 1)
                        Write-Err "  $errLine"
                        if (Confirm-Action "  Delete and re-clone $name ?" $true) {
                            Remove-AndReclone -RepoPath $r.Path -RemoteUrl $r.Url
                        } else {
                            Write-Info "  Kept: $name"
                        }
                    }
                }
            }
            elseif ($choice -eq 1) {
                foreach ($r in $needsRetry) {
                    Remove-AndReclone -RepoPath $r.Path -RemoteUrl $r.Url
                }
            }
            elseif ($choice -eq 2) {
                foreach ($r in $needsRetry) {
                    $name = $r.Path.Replace($root, "")
                    $urlHint = if ($r.Url) { " -> $($r.Url)" } else { "" }
                    $action = Confirm-Choice "$name ($($r.Reason))${urlHint}" @(
                        "Retry (120s timeout)",
                        "Delete and re-clone",
                        "Skip (keep as-is)"
                    )
                    if ($action -eq 0) {
                        Write-Host "  Retrying (120s) ..." -ForegroundColor Gray -NoNewline
                        $retry = Invoke-GitWithTimeout -RepoPath $r.Path -GitArgs @("fetch", "--prune") -TimeoutSec 120
                        if ($retry.Success -and ($retry.ExitCode -eq 0 -or $retry.Output -match "\[pruned\]")) {
                            Write-Host " ok" -ForegroundColor Green
                        } else {
                            Write-Host " failed" -ForegroundColor Red
                            if (Confirm-Action "  Delete and re-clone instead?" $true) {
                                Remove-AndReclone -RepoPath $r.Path -RemoteUrl $r.Url
                            } else {
                                Write-Info "  Kept: $name"
                            }
                        }
                    }
                    elseif ($action -eq 1) {
                        Remove-AndReclone -RepoPath $r.Path -RemoteUrl $r.Url
                    }
                    else {
                        Write-Info "  Kept: $name"
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
        $subOk = 0
        $subFailed = [System.Collections.ArrayList]@()

        foreach ($r in $subRepos) {
            $name = $r.Replace($root, "")
            Write-Host "  Syncing: $name ..." -ForegroundColor Gray -NoNewline

            # Use Invoke-GitWithTimeout with generous timeout (submodules can be slow)
            $subResult = Invoke-GitWithTimeout -RepoPath $r -GitArgs @("submodule", "update", "--init", "--recursive", "--force") -TimeoutSec 120

            if ($subResult.Success -and $subResult.ExitCode -eq 0) {
                Write-Host " ok" -ForegroundColor Green
                $subOk++
            } elseif (!$subResult.Success) {
                Write-Host " timeout (120s)" -ForegroundColor Red
                [void]$subFailed.Add(@{ Path = $r; Error = "timeout after 120s"; Name = $name })
            } else {
                # Capture error details
                $errLines = ($subResult.Output -split "`n" | Where-Object { $_ -match "fatal:|error:|Failed" })
                $errMsg = if ($errLines) { ($errLines | Select-Object -First 3) -join "; " } else { "exit code $($subResult.ExitCode)" }
                Write-Host " failed" -ForegroundColor Red
                Write-Err "    $errMsg"
                [void]$subFailed.Add(@{ Path = $r; Error = $errMsg; Name = $name })
            }
        }

        Write-Host ""
        Write-Host "  Submodule results: OK=$subOk  Failed=$($subFailed.Count)" -ForegroundColor White

        if ($subFailed.Count -gt 0) {
            Write-Warn "Failed submodule syncs ($($subFailed.Count)):"
            foreach ($f in $subFailed) {
                Write-Err "  $($f.Name)"
                Write-Info "    Error: $($f.Error)"
            }

            $choice = Confirm-Choice "How to handle failed submodule repos?" @(
                "Retry each with longer timeout (300s)",
                "Delete and re-clone parent repos",
                "Confirm each",
                "Skip"
            )
            if ($choice -eq 0) {
                foreach ($f in $subFailed) {
                    Write-Host "  Retrying: $($f.Name) (300s) ..." -ForegroundColor Gray -NoNewline
                    # First clean lock files in submodules
                    Get-ChildItem -Path "$($f.Path)\.git\modules" -Filter "*.lock" -Recurse -Force -ErrorAction SilentlyContinue |
                        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                    $retry = Invoke-GitWithTimeout -RepoPath $f.Path -GitArgs @("submodule", "update", "--init", "--recursive", "--force") -TimeoutSec 300
                    if ($retry.Success -and $retry.ExitCode -eq 0) {
                        Write-Host " ok" -ForegroundColor Green
                    } elseif (!$retry.Success) {
                        Write-Host " still timeout" -ForegroundColor Red
                        Write-Warn "  Network issue — kept as-is"
                    } else {
                        Write-Host " still failed" -ForegroundColor Red
                        $errLine = ($retry.Output -split "`n" | Where-Object { $_ -match "fatal:|error:" } | Select-Object -First 1)
                        Write-Err "    $errLine"
                        $url = git -C $f.Path remote get-url origin 2>$null
                        if (Confirm-Action "  Delete and re-clone $($f.Name) ?" $true) {
                            Remove-AndReclone -RepoPath $f.Path -RemoteUrl $url
                        } else {
                            Write-Info "  Kept: $($f.Name)"
                        }
                    }
                }
            }
            elseif ($choice -eq 1) {
                foreach ($f in $subFailed) {
                    $url = git -C $f.Path remote get-url origin 2>$null
                    Remove-AndReclone -RepoPath $f.Path -RemoteUrl $url
                }
            }
            elseif ($choice -eq 2) {
                foreach ($f in $subFailed) {
                    $url = git -C $f.Path remote get-url origin 2>$null
                    $urlHint = if ($url) { " -> $url" } else { "" }
                    $action = Confirm-Choice "$($f.Name)${urlHint}" @(
                        "Retry (300s timeout)",
                        "Delete and re-clone",
                        "Skip (keep as-is)"
                    )
                    if ($action -eq 0) {
                        Write-Host "  Retrying (300s) ..." -ForegroundColor Gray -NoNewline
                        Get-ChildItem -Path "$($f.Path)\.git\modules" -Filter "*.lock" -Recurse -Force -ErrorAction SilentlyContinue |
                            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                        $retry = Invoke-GitWithTimeout -RepoPath $f.Path -GitArgs @("submodule", "update", "--init", "--recursive", "--force") -TimeoutSec 300
                        if ($retry.Success -and $retry.ExitCode -eq 0) {
                            Write-Host " ok" -ForegroundColor Green
                        } else {
                            Write-Host " failed" -ForegroundColor Red
                            if (Confirm-Action "  Delete and re-clone instead?" $true) {
                                Remove-AndReclone -RepoPath $f.Path -RemoteUrl $url
                            } else {
                                Write-Info "  Kept: $($f.Name)"
                            }
                        }
                    }
                    elseif ($action -eq 1) {
                        Remove-AndReclone -RepoPath $f.Path -RemoteUrl $url
                    }
                    else {
                        Write-Info "  Kept: $($f.Name)"
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
# STEP 6: Final verification sweep
# ============================================================
Write-Step "STEP 6: Final verification"

$remainingRepos = @($repos | Where-Object { Test-Path $_ })
Write-Info "Checking $($remainingRepos.Count) remaining repos..."

$verifyOk = 0
$verifyBroken = [System.Collections.ArrayList]@()

foreach ($repo in $remainingRepos) {
    $name = $repo.Replace($root, "")
    # Quick health check: git status + verify HEAD
    $statusOut = git -C $repo status --short 2>&1 | Out-String
    $headOk = git -C $repo rev-parse HEAD 2>$null
    if ($statusOut -match "fatal:" -or [string]::IsNullOrWhiteSpace($headOk)) {
        $errLine = ($statusOut -split "`n" | Where-Object { $_ -match "fatal:" } | Select-Object -First 1)
        [void]$verifyBroken.Add(@{ Path = $repo; Name = $name; Error = $errLine })
    } else {
        $verifyOk++
    }
}

Write-Host ""
Write-Host "  Final: OK=$verifyOk  Broken=$($verifyBroken.Count) / $($remainingRepos.Count) total" -ForegroundColor White

if ($verifyBroken.Count -gt 0) {
    Write-Warn "Still broken after all repairs ($($verifyBroken.Count)):"
    foreach ($b in $verifyBroken) {
        Write-Err "  $($b.Name)"
        if ($b.Error) { Write-Info "    $($b.Error)" }
    }

    $choice = Confirm-Choice "Last resort — delete and re-clone broken repos?" @("Delete and re-clone all", "Confirm each", "Skip")
    if ($choice -eq 0) {
        foreach ($b in $verifyBroken) {
            $url = git -C $b.Path remote get-url origin 2>$null
            Remove-AndReclone -RepoPath $b.Path -RemoteUrl $url
        }
    }
    elseif ($choice -eq 1) {
        foreach ($b in $verifyBroken) {
            $url = git -C $b.Path remote get-url origin 2>$null
            $urlHint = if ($url) { " -> $url" } else { "" }
            if (Confirm-Action "Delete and re-clone $($b.Name)${urlHint} ?" $false) {
                Remove-AndReclone -RepoPath $b.Path -RemoteUrl $url
            } else {
                Write-Info "  Kept: $($b.Name)"
            }
        }
    }
    else {
        Write-Info "Skipped"
    }
} else {
    Write-Ok "All $verifyOk repos are healthy!"
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
