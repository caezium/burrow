param(
    [string]$Version = "v0.1.0-preview.1",
    [ValidateSet("win-x64")]
    [string]$Runtime = "win-x64",
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",
    [string]$RepositoryUrl = "https://github.com/caezium/Burrow",
    [string]$InnoSetupCompilerPath
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$platform = "x64"
$packageIdentifier = "Caezium.Burrow"
$packageName = "Burrow"
$packageVersion = $Version.TrimStart("v")
$artifactName = "$packageName-$Version-$Runtime"
$setupBaseName = "$artifactName-setup"
$setupFileName = "$setupBaseName.exe"
$zipFileName = "$artifactName.zip"
$releaseRoot = Join-Path $root "artifacts\release"
$stage = Join-Path $releaseRoot $artifactName
$zipPath = Join-Path $releaseRoot $zipFileName
$installerPath = Join-Path $releaseRoot $setupFileName
$shaPath = Join-Path $releaseRoot "SHA256SUMS.txt"
$notesPath = Join-Path $releaseRoot "RELEASE_NOTES.md"
$wingetRoot = Join-Path $releaseRoot "winget\Caezium\Burrow\$packageVersion"
$releaseBaseUrl = "$RepositoryUrl/releases/download/$Version"
$installerUrl = "$releaseBaseUrl/$setupFileName"

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Script
    )

    Write-Host "==> $Name"
    & $Script
}

function Find-InnoSetupCompiler {
    if (-not [string]::IsNullOrWhiteSpace($InnoSetupCompilerPath)) {
        if (Test-Path -LiteralPath $InnoSetupCompilerPath) {
            return (Resolve-Path -LiteralPath $InnoSetupCompilerPath).Path
        }

        throw "The configured Inno Setup compiler was not found: $InnoSetupCompilerPath"
    }

    $command = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    $candidates = @()
    if ($command) {
        $candidates += $command.Source
    }

    $candidates += @(
        "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Inno Setup Compiler (ISCC.exe) was not found. Install it with: winget install --id JRSoftware.InnoSetup -e"
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-WinGetManifests {
    param(
        [string]$InstallerSha256
    )

    if (Test-Path -LiteralPath $wingetRoot) {
        Remove-Item -LiteralPath $wingetRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $wingetRoot -Force | Out-Null

    $manifestVersion = "1.9.0"
    $releaseDate = (Get-Date).ToString("yyyy-MM-dd")
    $versionManifest = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.9.0.schema.json
# Created with BurrowWin release tooling.
PackageIdentifier: $packageIdentifier
PackageVersion: $packageVersion
DefaultLocale: en-US
ManifestType: version
ManifestVersion: $manifestVersion
"@

    $installerManifest = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.9.0.schema.json
# Created with BurrowWin release tooling.
PackageIdentifier: $packageIdentifier
PackageVersion: $packageVersion
InstallerType: inno
Scope: user
InstallModes:
- interactive
- silent
- silentWithProgress
UpgradeBehavior: install
ReleaseDate: $releaseDate
Dependencies:
  PackageDependencies:
  - PackageIdentifier: Microsoft.DotNet.DesktopRuntime.8
AppsAndFeaturesEntries:
- DisplayName: Burrow
  Publisher: Caezium
Installers:
- Architecture: x64
  InstallerUrl: $installerUrl
  InstallerSha256: $InstallerSha256
  InstallerSwitches:
    Silent: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
    SilentWithProgress: /SILENT /SUPPRESSMSGBOXES /NORESTART
ManifestType: installer
ManifestVersion: $manifestVersion
"@

    $localeManifest = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.9.0.schema.json
# Created with BurrowWin release tooling.
PackageIdentifier: $packageIdentifier
PackageVersion: $packageVersion
PackageLocale: en-US
Publisher: Caezium
PublisherUrl: https://github.com/caezium
PublisherSupportUrl: https://github.com/caezium/Burrow/issues
PackageName: Burrow
PackageUrl: $RepositoryUrl
License: MIT
LicenseUrl: $RepositoryUrl/blob/main/LICENSE
Copyright: Copyright (c) 2026 BurrowWin contributors
ShortDescription: A native Windows branch candidate for Burrow, powered by Mole.
Description: Burrow is a GUI-first system utility for status, cleanup, purge, installer cleanup, optimize, app management, disk analysis, history, activity, tray HUD, and local agent access. This Windows preview bundles the safe Mole Windows engine path plus documented Windows fallbacks.
Moniker: burrow
Tags:
- burrow
- mole
- cleanup
- system-utility
- winui
ReleaseNotesUrl: $releaseBaseUrl
ManifestType: defaultLocale
ManifestVersion: $manifestVersion
"@

    Write-Utf8NoBom -Path (Join-Path $wingetRoot "$packageIdentifier.yaml") -Content $versionManifest
    Write-Utf8NoBom -Path (Join-Path $wingetRoot "$packageIdentifier.installer.yaml") -Content $installerManifest
    Write-Utf8NoBom -Path (Join-Path $wingetRoot "$packageIdentifier.locale.en-US.yaml") -Content $localeManifest
}

New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

foreach ($path in @($stage, $zipPath, $installerPath, $shaPath, $wingetRoot)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $stage -Force | Out-Null

Invoke-Step "Restore solution" {
    dotnet restore (Join-Path $root "BurrowWin.sln")
}

Invoke-Step "Build BurrowWin" {
    dotnet build (Join-Path $root "BurrowWin.csproj") -c $Configuration -p:Platform=$platform -nr:false -v:minimal
}

Invoke-Step "Build tests" {
    dotnet build (Join-Path $root "Tests\BurrowWin.Tests\BurrowWin.Tests.csproj") -c $Configuration -nr:false -v:minimal
}

Invoke-Step "Run tests" {
    dotnet test (Join-Path $root "Tests\BurrowWin.Tests\BurrowWin.Tests.csproj") -c $Configuration --no-build -v:minimal
}

Invoke-Step "Test Mole runtime contracts" {
    & (Join-Path $PSScriptRoot "test-mole-runtime.ps1")
}

Invoke-Step "Publish portable payload" {
    dotnet publish (Join-Path $root "BurrowWin.csproj") `
        -c $Configuration `
        -p:Platform=$platform `
        -r $Runtime `
        --self-contained false `
        -o $stage `
        -nr:false `
        -v:minimal
}

Invoke-Step "Verify published Mole runtime" {
    & (Join-Path $PSScriptRoot "verify-mole-runtime.ps1") -EngineRoot (Join-Path $stage "Assets\Mole")
}

Invoke-Step "Copy release documents" {
    Copy-Item -LiteralPath (Join-Path $root "README.md") -Destination (Join-Path $stage "README.md") -Force
    Copy-Item -LiteralPath (Join-Path $root "LICENSE") -Destination (Join-Path $stage "LICENSE") -Force
    Copy-Item -LiteralPath (Join-Path $root "BURROW_WINDOWS_ALIGNMENT.md") -Destination (Join-Path $stage "BURROW_WINDOWS_ALIGNMENT.md") -Force
    Copy-Item -LiteralPath (Join-Path $root "docs\mole-windows-gap.md") -Destination (Join-Path $stage "MOLE_WINDOWS_GAP.md") -Force
    Copy-Item -LiteralPath (Join-Path $root "packaging\windows\RELEASE_NOTES_TEMPLATE.md") -Destination $notesPath -Force
    Copy-Item -LiteralPath $notesPath -Destination (Join-Path $stage "RELEASE_NOTES.md") -Force
}

Invoke-Step "Create ZIP fallback" {
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -Force
}

Invoke-Step "Create Inno Setup installer" {
    $compiler = Find-InnoSetupCompiler
    $script = Join-Path $root "packaging\windows\Burrow.iss"
    $icon = Join-Path $root "Assets\AppIcon.ico"

    & $compiler `
        "/DAppVersion=$packageVersion" `
        "/DSourceDir=$stage" `
        "/DOutputDir=$releaseRoot" `
        "/DOutputBaseFilename=$setupBaseName" `
        "/DAppIcon=$icon" `
        $script
}

Invoke-Step "Write SHA256SUMS" {
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Installer was not created: $installerPath"
    }

    $artifactPaths = @($installerPath, $zipPath)
    $lines = foreach ($artifactPath in $artifactPaths) {
        $hash = Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
        "{0}  {1}" -f $hash.Hash.ToLowerInvariant(), (Split-Path -Leaf $artifactPath)
    }

    Write-Utf8NoBom -Path $shaPath -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

Invoke-Step "Write WinGet manifests" {
    $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    Write-WinGetManifests -InstallerSha256 $installerHash
}

Write-Host ""
Write-Host "Release payload: $stage"
Write-Host "Installer:       $installerPath"
Write-Host "Portable ZIP:    $zipPath"
Write-Host "SHA256SUMS:      $shaPath"
Write-Host "Release notes:   $notesPath"
Write-Host "WinGet manifest: $wingetRoot"
