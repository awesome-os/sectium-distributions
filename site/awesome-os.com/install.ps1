<#
.SYNOPSIS
    Sectium / Awesome-OS Zero-Gatekeeper Windows Installer
.DESCRIPTION
    One-liner: irm https://awesome-os.com/install.ps1 | iex
    Installs sectium-es.exe, sectium-jvm.exe, sectium-jvm.wasm, sectium_cp.dll,
    and sectium_cp.wasm with zero Mark-of-the-Web (MOTW) quarantine, strict
    SHA-256 verification against release-manifest.json, optional < 1 s zig cc
    source compilation, and idempotent User PATH registration.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Dir = (Join-Path (Join-Path $env:LOCALAPPDATA 'Sectium') 'bin'),
    [ValidateSet('rolling', 'stable')]
    [string]$Channel = 'rolling',
    [switch]$FromSource,
    [string]$ManifestUrl = 'https://awesome-os.com/release-manifest.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # Ignore on platforms where SecurityProtocol is managed by the OS
}

$PlaneVersion = '0.2.0'
$AbiMagic = '0x33564742'
$AbiVersion = 3
$BaseUrl = "https://awesome-os.com/releases/$Channel"

# Fallback embedded manifest digests for offline / dry-run inspection
$DefaultArtifacts = @(
    @{
        id        = 'sectium-es-win64'
        filename  = 'sectium-es.exe'
        repoPath  = 'sections/b8g-es/dist/sectium-es.exe'
        target    = 'x86_64-windows-gnu'
        bytes     = 96256
        sha256    = '0cecb57b19a4f52b54c55a5bc57d597b94622dbffe54e26684aab085e84bfaab'
    },
    @{
        id        = 'sectium-jvm-win64'
        filename  = 'sectium-jvm.exe'
        repoPath  = 'sections/b8g-jvm/dist/sectium-jvm.exe'
        target    = 'x86_64-windows-gnu'
        bytes     = 85504
        sha256    = '3e79140f47c9028e1548a4fd775abece2a175b05f27d9234a898b526b69ebdd1'
    },
    @{
        id        = 'sectium-jvm-wasi'
        filename  = 'sectium-jvm.wasm'
        repoPath  = 'sections/b8g-jvm/dist/sectium-jvm.wasm'
        target    = 'wasm32-wasi'
        bytes     = 74355
        sha256    = '761002d39ac3f63b8f03399f43a634e13e58849f25d5835d0463cf310ce0dcc2'
    },
    @{
        id        = 'sectium-cp-win64'
        filename  = 'sectium_cp.dll'
        repoPath  = 'sections/sectium-cloud-control-plane/dist/sectium_cp.dll'
        target    = 'x86_64-windows-gnu'
        bytes     = 20480
        sha256    = '1090c8f45d9021e63cdb50c28996935c70434d7d3ae3a169a873431037264784'
    },
    @{
        id        = 'sectium-cp-wasi'
        filename  = 'sectium_cp.wasm'
        repoPath  = 'sections/sectium-cloud-control-plane/dist/sectium_cp.wasm'
        target    = 'wasm32-wasi'
        bytes     = 5695
        sha256    = '5d37c0ad32653ffe9a221ff35b80f4962754487724239bc7be97a4c55d65a5f0'
    }
)

function Write-Status {
    param([string]$Tag, [string]$Message)
    Write-Output "[$Tag] $Message"
}

function Clear-MarkOfTheWeb {
    param([string]$FilePath)
    if (Test-Path -LiteralPath $FilePath) {
        try {
            Unblock-File -LiteralPath $FilePath -ErrorAction SilentlyContinue
        } catch {
            # Unblock-File may not exist on non-Windows hosts
        }
        $zoneStream = "${FilePath}:Zone.Identifier"
        if (Test-Path -LiteralPath $zoneStream -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $zoneStream -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-Sha256 {
    param(
        [string]$FilePath,
        [string]$ExpectedSha256
    )
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $FilePath).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed for $FilePath. Expected $expected, got $actual."
    }
    return $actual
}

function Add-ToUserPath {
    param([string]$InstallDir)
    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        $entries = @()
    } else {
        $entries = $currentPath.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $normalizedTarget = $InstallDir.TrimEnd('\')
    $alreadyPresent = $false
    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\').Equals($normalizedTarget, [StringComparison]::OrdinalIgnoreCase)) {
            $alreadyPresent = $true
            break
        }
    }

    if (-not $alreadyPresent) {
        $newPath = if ($entries.Count -gt 0) { "$currentPath;$InstallDir" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        if (-not ($env:Path -like "*$normalizedTarget*")) {
            $env:Path = "$env:Path;$InstallDir"
        }
        Write-Status 'PATH' "Added $InstallDir to User PATH"
    } else {
        Write-Status 'PATH' "$InstallDir is already present in User PATH"
    }
}

function Find-ZigCompiler {
    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($null -ne $zigCmd) {
        return $zigCmd.Source
    }
    return $null
}

function Invoke-ZigSourceBuild {
    param(
        [string]$ZigPath,
        [string]$InstallDir,
        [string]$WorkspaceRoot
    )
    $esMain = Join-Path $WorkspaceRoot 'sections\b8g-es\b8g_es_main.c'
    $esVm   = Join-Path $WorkspaceRoot 'sections\b8g-es\b8g_es_vm.c'
    $jvmMain   = Join-Path $WorkspaceRoot 'sections\b8g-jvm\b8g_jvm_main.c'
    $jvmInterp = Join-Path $WorkspaceRoot 'sections\b8g-jvm\b8g_jvm_interp.c'
    $jvmAot    = Join-Path $WorkspaceRoot 'sections\b8g-jvm\b8g_jvm_aot.c'
    $cpSrc     = Join-Path $WorkspaceRoot 'sections\sectium-cloud-control-plane\sectium_cp.c'

    if (-not ((Test-Path $esMain) -and (Test-Path $jvmMain) -and (Test-Path $cpSrc))) {
        return $false
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Status 'ZIG' "Building native Win64 artifacts from C11 source via zig cc ($ZigPath)..."

    $esOut  = Join-Path $InstallDir 'sectium-es.exe'
    $jvmOut = Join-Path $InstallDir 'sectium-jvm.exe'
    $cpOut  = Join-Path $InstallDir 'sectium_cp.dll'

    & $ZigPath cc -std=c11 -O2 -s -target x86_64-windows-gnu $esMain $esVm -o $esOut
    if ($LASTEXITCODE -ne 0) { throw "zig cc failed compiling sectium-es.exe (exit $LASTEXITCODE)" }

    & $ZigPath cc -std=c11 -O2 -s -target x86_64-windows-gnu $jvmMain $jvmInterp $jvmAot -o $jvmOut
    if ($LASTEXITCODE -ne 0) { throw "zig cc failed compiling sectium-jvm.exe (exit $LASTEXITCODE)" }

    & $ZigPath cc -std=c11 -O2 -s -shared -target x86_64-windows-gnu $cpSrc -o $cpOut
    if ($LASTEXITCODE -ne 0) { throw "zig cc failed compiling sectium_cp.dll (exit $LASTEXITCODE)" }

    $sw.Stop()
    Write-Status 'ZIG' "Compiled sectium-es.exe, sectium-jvm.exe, sectium_cp.dll in $($sw.ElapsedMilliseconds) ms (zero MOTW)"
    return $true
}

function Resolve-ManifestArtifacts {
    param([string]$Url)
    $localManifest = $null
    if ($PSScriptRoot) {
        $candidate = Join-Path $PSScriptRoot 'release-manifest.json'
        if (Test-Path -LiteralPath $candidate) {
            $localManifest = $candidate
        }
    }

    if ($DryRun) {
        if ($null -ne $localManifest) {
            $manifest = Get-Content -LiteralPath $localManifest -Raw | ConvertFrom-Json
            return $manifest.artifacts | Where-Object { $_.target -eq 'x86_64-windows-gnu' -or $_.target -eq 'wasm32-wasi' }
        }
        return $DefaultArtifacts
    }

    try {
        $manifest = Invoke-RestMethod -Uri $Url -UseBasicParsing
        if ($manifest.abiMagic -ne $AbiMagic -or [int]$manifest.abiVersion -lt $AbiVersion) {
            throw "Unsupported manifest ABI: magic=$($manifest.abiMagic) version=$($manifest.abiVersion)"
        }
        return $manifest.artifacts | Where-Object { $_.target -eq 'x86_64-windows-gnu' -or $_.target -eq 'wasm32-wasi' }
    } catch {
        if ($null -ne $localManifest) {
            Write-Status 'WARN' "Remote manifest unavailable ($Url); using local release-manifest.json"
            $manifest = Get-Content -LiteralPath $localManifest -Raw | ConvertFrom-Json
            return $manifest.artifacts | Where-Object { $_.target -eq 'x86_64-windows-gnu' -or $_.target -eq 'wasm32-wasi' }
        }
        Write-Status 'WARN' "Remote manifest unavailable ($Url); using embedded rolling digests"
        return $DefaultArtifacts
    }
}

# --- Main Execution ---
$zigPath = Find-ZigCompiler
$artifacts = Resolve-ManifestArtifacts -Url $ManifestUrl

Write-Status 'SECTIUM' "Awesome-OS / Sectium Installer v$PlaneVersion (channel=$Channel, abi=$AbiMagic/v$AbiVersion)"
Write-Status 'TARGET'  "Install directory: $Dir"
Write-Status 'SECURITY' 'Zero Mark-of-the-Web (MOTW) quarantine + strict SHA-256 verification'
if ($null -ne $zigPath) {
    Write-Status 'ZIG' "Detected zig compiler at $zigPath (< 1 s C11 source build supported)"
} else {
    Write-Status 'ZIG' 'zig not found on PATH; will install verified prebuilt artifacts'
}

if ($DryRun) {
    Write-Status 'DRY-RUN' "Would create directory: $Dir"
    foreach ($art in $artifacts) {
        $url = "$BaseUrl/$($art.filename)"
        Write-Status 'DRY-RUN' "Would fetch $url ($($art.bytes) B) -> $(Join-Path $Dir $art.filename) [sha256=$($art.sha256)]"
    }
    Write-Status 'DRY-RUN' "Would strip any Zone.Identifier ADS and add $Dir to User PATH"
    Write-Status 'DONE' 'Dry-run complete (0 files modified, 0 network requests).'
    exit 0
}

if (-not (Test-Path -LiteralPath $Dir)) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
}

$workspaceRoot = $null
if ($PSScriptRoot) {
    $candidateRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (Test-Path (Join-Path $candidateRoot 'sections\sectium-cloud-control-plane\sectium_cp.c')) {
        $workspaceRoot = $candidateRoot
    }
}

$builtFromSource = $false
if ($FromSource -and ($null -ne $zigPath) -and ($null -ne $workspaceRoot)) {
    $builtFromSource = Invoke-ZigSourceBuild -ZigPath $zigPath -InstallDir $Dir -WorkspaceRoot $workspaceRoot
}

if (-not $builtFromSource) {
    foreach ($art in $artifacts) {
        $dest = Join-Path $Dir $art.filename
        $url = "$BaseUrl/$($art.filename)"
        $localArtifact = $null
        if ($null -ne $workspaceRoot -and $art.repoPath) {
            $candidateBin = Join-Path $workspaceRoot ($art.repoPath -replace '/', '\')
            if (Test-Path -LiteralPath $candidateBin) {
                $localArtifact = $candidateBin
            }
        }

        if ($null -ne $localArtifact) {
            Copy-Item -LiteralPath $localArtifact -Destination $dest -Force
        } else {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        }

        Clear-MarkOfTheWeb -FilePath $dest
        $verifiedHash = Assert-Sha256 -FilePath $dest -ExpectedSha256 $art.sha256
        Write-Status 'OK' "$($art.filename) verified (sha256=$($verifiedHash.Substring(0, 16))..., $($art.bytes) B)"
    }
}

Add-ToUserPath -InstallDir $Dir
Write-Status 'DONE' "Sectium installed to $Dir (channel=$Channel). Open a new shell to use sectium-es and sectium-jvm."
exit 0
