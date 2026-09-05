# Validate packaged sources without running a maintenance command.
#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$EngineRoot,
    [string]$Conductor
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Conductor -and -not (Test-Path -LiteralPath $Conductor -PathType Leaf)) {
    throw "Bundled conductor is missing: $Conductor"
}

$required = @(
    'mole.ps1', 'invoke-mole.ps1', 'burrow-engine.cmd', 'mo.cmd',
    'bin/clean.ps1', 'bin/optimize.ps1',
    'lib/core/base.ps1', 'lib/core/common.ps1', 'lib/core/file_ops.ps1',
    'lib/core/log.ps1', 'lib/core/ui.ps1', 'lib/core/version.ps1',
    'lib/clean/user.ps1', 'lib/clean/caches.ps1', 'lib/clean/dev.ps1',
    'lib/clean/apps.ps1', 'lib/clean/system.ps1'
)
foreach ($relative in $required) {
    $path = Join-Path $EngineRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Bundled Mole runtime is incomplete: $relative"
    }
    if ([IO.Path]::GetExtension($path) -eq '.ps1') {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -ne 0) {
            throw "Bundled Mole script does not parse: $relative ($($parseErrors[0].Message))"
        }
    }
}
Write-Output 'Bundled Mole clean/optimize runtime: complete and parseable'
