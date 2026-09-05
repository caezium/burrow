# Inspect production path-validation functions without loading maintenance code.
#Requires -Version 5.1
param(
    [string]$FileOperationsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Assets/Mole/lib/core/file_ops.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($FileOperationsPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "File operations do not parse: $FileOperationsPath" }
foreach ($name in @('Test-NoReparsePointAncestor', 'Test-SafePath')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    # Keep the pre-fix implementation runnable so the rejected-path assertions
    # demonstrate the safety regression instead of only checking helper names.
    if ($null -ne $definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
}

function Resolve-SafePath([string]$Path) { [IO.Path]::GetFullPath($Path) }
function Test-ProtectedPath([string]$Path) { return $false }
function Test-Whitelisted([string]$Path) { return $false }
function Test-AllowedCleanupRoot([string]$Path) { return $true }

# The fake inspector uses the host's path syntax. It never reads user data,
# invokes maintenance, or needs permission to create filesystem links.
& {
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetTempPath())
    $profile = Join-Path $root 'burrow-mole-safety-profile'
    $cache = Join-Path $profile 'cache'
    $file = Join-Path $cache 'item.dat'
    $script:inspectionPaths = @()
    $script:reparsePath = $null
    $script:unreadablePath = $null
    $script:missingPath = $null

    function Get-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Force)
        $script:inspectionPaths += $LiteralPath
        if ($LiteralPath -eq $script:unreadablePath) { throw 'Fixture: inspection denied' }
        if ($LiteralPath -eq $script:missingPath) { return $null }
        $attributes = [IO.FileAttributes]::Directory
        if ($LiteralPath -eq $script:reparsePath) {
            $attributes = $attributes -bor [IO.FileAttributes]::ReparsePoint
        }
        [pscustomobject]@{ FullName = $LiteralPath; Attributes = $attributes }
    }

    Assert-True (Test-SafePath -Path $file) 'A normal cache file was rejected'
    $script:reparsePath = $file
    Assert-True (-not (Test-SafePath -Path $file)) 'A reparse-point target was accepted for cleanup'
    $script:reparsePath = $cache
    Assert-True (-not (Test-SafePath -Path $file)) 'A cache-directory junction was accepted for cleanup'
    $script:reparsePath = $profile
    Assert-True (-not (Test-SafePath -Path $file)) 'A junction above the allowed cleanup root was accepted'

    $script:reparsePath = $null
    foreach ($path in @($file, $cache, $profile, $root)) {
        $script:unreadablePath = $path
        Assert-True (-not (Test-SafePath -Path $file)) "An uninspectable component was accepted: $path"
    }
    $script:unreadablePath = $null
    $script:missingPath = $file
    Assert-True (-not (Test-SafePath -Path $file)) 'A missing target was accepted'
    $script:missingPath = $null
    $script:inspectionPaths = @()
    Assert-True (Test-SafePath -Path $file) 'A normal cache file was rejected after failed inspections'
    Assert-True ($script:inspectionPaths -contains $root) 'Inspection stopped before the filesystem root'
}

# On Windows, exercise a real directory junction with harmless scratch files.
# Creating junctions needs neither elevation nor Developer Mode. The destination
# and aliases all belong to this fixture; validation never deletes any of them.
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('burrow-mole-path-safety-' + [guid]::NewGuid().ToString('N'))
    $junctions = @()
    try {
        $target = Join-Path $fixture 'target'
        $cache = Join-Path $target 'cache'
        [IO.Directory]::CreateDirectory($cache) | Out-Null
        $sentinel = Join-Path $cache 'keep.txt'
        [IO.File]::WriteAllText($sentinel, 'unchanged')
        $directAlias = Join-Path $fixture 'cache-alias'
        $parentAlias = Join-Path $fixture 'profile-alias'
        New-Item -ItemType Junction -Path $directAlias -Target $cache | Out-Null
        $junctions += $directAlias
        New-Item -ItemType Junction -Path $parentAlias -Target $target | Out-Null
        $junctions += $parentAlias

        Assert-True (Test-SafePath -Path $sentinel) 'The ordinary fixture file was rejected'
        Assert-True (-not (Test-SafePath -Path (Join-Path $directAlias 'keep.txt'))) 'A real cache junction was accepted'
        Assert-True (-not (Test-SafePath -Path (Join-Path $parentAlias 'cache/keep.txt'))) 'A real junction above the cleanup root was accepted'
        Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'unchanged') 'Path validation modified the fixture'
    }
    finally {
        # Delete the links themselves before recursively removing our fixture.
        foreach ($junction in $junctions) { [IO.Directory]::Delete($junction) }
        if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
    }
    Write-Host 'Mole path safety passed, including real Windows junctions.'
}
else {
    Write-Host 'Mole path safety passed with a fake inspector; real junction checks require Windows.'
}
