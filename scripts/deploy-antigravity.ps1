#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Detect', 'Deploy', 'Restore')]
    [string]$Action = 'Detect',
    [string]$InstallPath,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'antigravity-deploy.json') -Raw | ConvertFrom-Json
$cache = Join-Path $env:LOCALAPPDATA 'CockpitToolsClean\AntigravitySetup'
$session = (Get-Process -Id $PID).SessionId
$outcome = [ordered]@{
    action = $Action
    status = 'Missing'
    version = $null
    path = $null
    idePaths = @()
    localization = $null
    running = $false
    windowPid = $null
    message = $null
}

function Get-DesktopProcesses {
    Get-Process -Name Antigravity -ErrorAction SilentlyContinue | Where-Object SessionId -EQ $session
}

function Get-DesktopPath {
    if ($InstallPath) {
        $candidate = Get-Item -LiteralPath $InstallPath
        if ($candidate.PSIsContainer) {
            $candidate = Get-Item -LiteralPath (Join-Path $candidate.FullName 'Antigravity.exe')
        }
        if ($candidate.PSIsContainer -or $candidate.Name -ine 'Antigravity.exe') {
            throw 'Select the Antigravity desktop folder or its Antigravity.exe.'
        }
        return $candidate.FullName
    }

    $desktopPaths = @(Get-DesktopProcesses | ForEach-Object Path)
    $idePaths = @()
    $desktopPaths += @(Get-Command Antigravity.exe -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object Source)
    $programDirectories = @((Join-Path $env:LOCALAPPDATA 'Programs'), $env:ProgramW6432, $env:ProgramFiles)
    foreach ($directory in ($programDirectories | Where-Object { $_ } | Select-Object -Unique)) {
        $desktopPaths += Join-Path $directory 'Antigravity\Antigravity.exe'
        $desktopPaths += Join-Path $directory 'Google Antigravity\Antigravity.exe'
        $idePaths += Join-Path $directory 'Antigravity IDE\Antigravity IDE.exe'
    }

    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in (Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue)) {
        $iconPath = ([string]$entry.DisplayIcon -replace ',\s*-?\d+\s*$', '').Trim('" ')
        if ($entry.DisplayName -match '^(?:Google )?Antigravity IDE(?:\s+[\d.]+)?$') {
            if ($iconPath) { $idePaths += $iconPath }
            if ($entry.InstallLocation) { $idePaths += Join-Path $entry.InstallLocation 'Antigravity IDE.exe' }
        } elseif ($entry.DisplayName -match '^(?:Google )?Antigravity(?:\s+[\d.]+)?$') {
            if ($iconPath) { $desktopPaths += $iconPath }
            if ($entry.InstallLocation) { $desktopPaths += Join-Path $entry.InstallLocation 'Antigravity.exe' }
        }
    }

    $outcome.idePaths = @($idePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object -Unique)
    $candidates = @($desktopPaths | Where-Object { $_ -and (Split-Path -Leaf $_) -ieq 'Antigravity.exe' } |
        ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue } |
        Where-Object { -not $_.PSIsContainer } | ForEach-Object FullName | Sort-Object -Unique)
    if ($candidates.Count -gt 1) {
        $outcome.status = 'MultipleInstallations'
        throw "Multiple desktop paths found. Select one with -InstallPath: $($candidates -join ' | ')"
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }
}

function Get-DesktopState([string]$Path) {
    $exe = Get-Item -LiteralPath $Path
    $outcome.path = $exe.FullName
    $outcome.version = $exe.VersionInfo.FileVersion
    $activeProcesses = @(Get-DesktopProcesses | Where-Object Path -IEQ $exe.FullName)
    $activeWindow = $activeProcesses | Where-Object MainWindowHandle -NE 0 | Select-Object -First 1
    $outcome.running = $activeProcesses.Count -gt 0
    $outcome.windowPid = if ($activeWindow) { $activeWindow.Id } else { $null }
    $resources = Join-Path $exe.DirectoryName 'resources'
    $asar = Join-Path $resources 'app.asar'
    if ($exe.VersionInfo.ProductName -ine 'Antigravity' -or
        !(Test-Path -LiteralPath $asar -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $resources 'app.asar.unpacked') -PathType Container)) {
        $outcome.status = 'UnsupportedLayout'
        return
    }
    if ($outcome.version -ne $manifest.version -or
        (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash -ine $manifest.executableSha256) {
        $outcome.status = 'UnsupportedBuild'
        return
    }
    $asarHash = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
    $outcome.status = if ($asarHash -ieq $manifest.patchedAsarSha256) {
        $outcome.localization = "zh-CN ($($manifest.patchVersion))"
        'Localized'
    } elseif ($asarHash -ieq $manifest.originalAsarSha256) {
        $outcome.localization = 'original'
        'Original'
    } else {
        'UnrecognizedResources'
    }
    return $asar
}

function Get-VerifiedDownload([string]$Url, [string]$Sha256, [string]$Name) {
    if (([Uri]$Url).Scheme -cne 'https' -or $Sha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Invalid HTTPS download or checksum in the deployment manifest.'
    }
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $file = Join-Path $cache $Name
    if ((Test-Path -LiteralPath $file -PathType Leaf) -and
        (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ieq $Sha256) {
        return $file
    }

    $partial = "$file.$([Guid]::NewGuid().ToString('N')).partial"
    try {
        Write-Host "Downloading $Name"
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (Test-Path -LiteralPath $curl -PathType Leaf) {
            & $curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --max-time 300 --output $partial $Url
            if ($LASTEXITCODE -ne 0) { throw "Download failed for $Name (curl $LASTEXITCODE)." }
        } else {
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 300 -OutFile $partial
        }
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $Sha256) {
            throw "SHA-256 mismatch for $Name."
        }
        Move-Item -LiteralPath $partial -Destination $file -Force
        return $file
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
    }
}

function Assert-DesktopClosed([string]$Path) {
    if (@(Get-DesktopProcesses | Where-Object { !$_.Path -or $_.Path -ieq $Path }).Count) {
        throw 'Save your work, fully quit Antigravity (including its tray process), then retry.'
    }
}

function Set-DesktopAsar([string]$Source, [string]$Target, [string]$Backup, [string]$CurrentHash, [string]$ExpectedHash) {
    $temporary = "$Target.cockpit-$([Guid]::NewGuid().ToString('N')).tmp"
    Copy-Item -LiteralPath $Source -Destination $temporary
    try {
        Assert-DesktopClosed $outcome.path
        if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -ine $CurrentHash) {
            throw 'Antigravity changed during preparation. Run detection again.'
        }
        [IO.File]::Replace($temporary, $Target, $Backup)
        if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -ine $ExpectedHash) {
            [IO.File]::Replace($Backup, $Target, $temporary)
            throw 'Replacement checksum failed. The previous resources were restored.'
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Install-Localization([string]$Target) {
    $patchName = "localization-$($manifest.patchVersion).zip"
    $patchZip = Join-Path $PSScriptRoot $patchName
    if (Test-Path -LiteralPath $patchZip -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $patchZip -Algorithm SHA256).Hash -ine $manifest.patchSha256) {
            throw 'The included community patch has an unexpected checksum.'
        }
    } else {
        $patchZip = Get-VerifiedDownload $manifest.patchUrl $manifest.patchSha256 $patchName
    }
    $nodeZip = Get-VerifiedDownload $manifest.nodeUrl $manifest.nodeSha256 "node-v$($manifest.nodeVersion)-win-x64.zip"
    # The upstream patcher invokes the ASAR command through cmd.exe.
    $stagingParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($stagingParent -match '[%!]') {
        throw 'Use a Windows profile and temporary folder without percent or exclamation marks in their paths.'
    }
    $staging = Join-Path $stagingParent ("agy-" + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    $stagedResources = Join-Path $staging 'app\resources'
    New-Item -ItemType Directory -Path $stagedResources -Force | Out-Null
    $pathBeforePatch = $env:Path
    $registryBeforePatch = $env:npm_config_registry
    $scriptsBeforePatch = $env:npm_config_ignore_scripts
    try {
        Expand-Archive -LiteralPath $patchZip -DestinationPath $staging
        Expand-Archive -LiteralPath $nodeZip -DestinationPath $staging
        $patchRoot = Join-Path $staging "antigravity-chinese-$($manifest.patchRevision)"
        $nodeRoot = Join-Path $staging "node-v$($manifest.nodeVersion)-win-x64"
        $env:Path = "$nodeRoot;$pathBeforePatch"
        $env:npm_config_registry = 'https://registry.npmjs.org/'
        $env:npm_config_ignore_scripts = 'true'
        $stagedAsar = Join-Path $stagedResources 'app.asar'
        Copy-Item -LiteralPath $Target -Destination $stagedAsar
        # Some unpacked assets exceed the Windows PowerShell 5.1 path limit.
        $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
        & $robocopy "$Target.unpacked" "$stagedAsar.unpacked" /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Host
        if ($LASTEXITCODE -ge 8) { throw 'Could not stage the external Antigravity resources.' }
        & (Join-Path $nodeRoot 'node.exe') (Join-Path $patchRoot 'cli.js') install --path (Split-Path -Parent $stagedResources) | Out-Host
        if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $stagedAsar -Algorithm SHA256).Hash -ine $manifest.patchedAsarSha256) {
            throw 'The community patch did not produce the verified ASAR. The installation was not modified.'
        }
        $backup = "$Target.bak"
        if (Test-Path -LiteralPath $backup) {
            # Keep an earlier backup from another patch or app version.
            $backup = "$Target.cockpit-$($manifest.version).original"
            if (Test-Path -LiteralPath $backup) {
                if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ine $manifest.originalAsarSha256) {
                    throw 'An existing rollback file has unexpected content.'
                }
            }
        }
        Set-DesktopAsar $stagedAsar $Target $backup $manifest.originalAsarSha256 $manifest.patchedAsarSha256
    } finally {
        $env:Path = $pathBeforePatch
        $env:npm_config_registry = $registryBeforePatch
        $env:npm_config_ignore_scripts = $scriptsBeforePatch
        $parentDirectory = $stagingParent.TrimEnd('\') + '\'
        $workDirectory = [IO.Path]::GetFullPath($staging)
        if ($workDirectory.StartsWith($parentDirectory, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $workDirectory) -match '^agy-[0-9a-f]{12}$') {
            Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-Localization([string]$Target) {
    $backups = @("$Target.cockpit-$($manifest.version).original", "$Target.bak")
    $original = $backups | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and
        (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ieq $manifest.originalAsarSha256
    } | Select-Object -First 1
    if (!$original) { throw 'No matching original ASAR backup. Use the official installer to repair this version.' }
    $previous = "$Target.cockpit-$([Guid]::NewGuid().ToString('N')).previous"
    Set-DesktopAsar $original $Target $previous $manifest.patchedAsarSha256 $manifest.originalAsarSha256
    if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous }
}

$mutex = $null
$lockAcquired = $false
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run this script in Windows.' }
    if ($Action -ne 'Detect') {
        $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        if ($architecture -ne 'X64') { throw 'This deployment supports Windows x64.' }
        if ($session -eq 0) { throw 'Run deployment in the Windows desktop user session.' }
        $mutex = [Threading.Mutex]::new($false, 'Local\CockpitToolsClean-AntigravitySetup')
        try { $lockAcquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
        if (!$lockAcquired) { throw 'Another Antigravity deployment is active in this session.' }
    }

    $exePath = Get-DesktopPath
    if (!$exePath -and $Action -eq 'Deploy') {
        if (@(Get-DesktopProcesses).Count) { throw 'Antigravity is running but its installation path could not be resolved.' }
        $installer = Get-VerifiedDownload $manifest.installerUrl $manifest.installerSha256 "Antigravity-$($manifest.version)-x64.exe"
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Google LLC(,|$)') {
            throw 'The installer does not have a valid Google LLC signature.'
        }
        Write-Host "Installing Google Antigravity $($manifest.version) for the current user"
        $setup = Start-Process -FilePath $installer -ArgumentList '/S /currentuser' -Wait -PassThru
        if ($setup.ExitCode -ne 0) { throw "Google installer returned $($setup.ExitCode)." }
        $exePath = Get-DesktopPath
        if (!$exePath) { throw 'The installer exited but the desktop executable was not found.' }
    }
    if ($exePath) { $asarPath = Get-DesktopState $exePath }

    if ($Action -ne 'Detect') {
        if ($outcome.status -notin @('Original', 'Localized')) {
            throw "Cannot $Action from state $($outcome.status). This build supports Antigravity desktop $($manifest.version) x64."
        }
        if ($Action -eq 'Deploy' -and $outcome.status -eq 'Original') {
            Assert-DesktopClosed $exePath
            Install-Localization $asarPath
        } elseif ($Action -eq 'Restore' -and $outcome.status -eq 'Localized') {
            Assert-DesktopClosed $exePath
            Restore-Localization $asarPath
        }
        $null = Get-DesktopState $exePath
        $expectedState = if ($Action -eq 'Deploy') { 'Localized' } else { 'Original' }
        if ($outcome.status -ne $expectedState) { throw "Expected $expectedState after $Action." }

        if (!$NoLaunch) {
            if (!$outcome.windowPid) {
                Start-Process -FilePath $exePath -WorkingDirectory (Split-Path -Parent $exePath)
            }
            $deadline = [DateTime]::UtcNow.AddSeconds(40)
            do {
                $windowProcess = Get-DesktopProcesses | Where-Object {
                    $_.Path -ieq $exePath -and $_.MainWindowHandle -ne 0
                } | Select-Object -First 1
                if ($windowProcess) { break }
                Start-Sleep -Milliseconds 500
            } while ([DateTime]::UtcNow -lt $deadline)
            if (!$windowProcess) { throw 'No window from the selected executable appeared. Check the desktop and retry.' }
            $outcome.running = $true
            $outcome.windowPid = $windowProcess.Id
        }
    }
    [pscustomobject]$outcome | ConvertTo-Json -Depth 3
} catch {
    $outcome.message = $_.Exception.Message
    [pscustomobject]$outcome | ConvertTo-Json -Depth 3
    exit 1
} finally {
    if ($lockAcquired) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
