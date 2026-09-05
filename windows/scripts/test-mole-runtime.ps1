# Tests use function ASTs and fake OS operations. No maintenance runs on the host.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'Assets/Mole'
& (Join-Path $PSScriptRoot 'verify-mole-runtime.ps1') -EngineRoot $engine
& (Join-Path $PSScriptRoot 'test-mole-path-safety.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Read-Function([string]$Path, [string]$Name) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "Script does not parse: $Path" }
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if ($null -eq $definition) { throw "Missing function $Name in $Path" }
    return [scriptblock]::Create($definition.Extent.Text)
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('burrow-mole-runtime-' + [guid]::NewGuid().ToString('N'))
$savedDryRun = [Environment]::GetEnvironmentVariable('MOLE_DRY_RUN', 'Process')
[IO.Directory]::CreateDirectory($fixture) | Out-Null
try {
    $incomplete = Join-Path $fixture 'incomplete'
    Copy-Item -LiteralPath $engine -Destination $incomplete -Recurse
    Remove-Item -LiteralPath (Join-Path $incomplete 'bin/clean.ps1')
    $refused = $false
    try { & (Join-Path $PSScriptRoot 'verify-mole-runtime.ps1') -EngineRoot $incomplete } catch {
        $refused = $_.Exception.Message -like '*bin/clean.ps1*'
    }
    Assert-True $refused 'Packaging accepted an entrypoint without the clean command it invokes'

    # The actual router must bind preview/apply/help to the intended command,
    # and an absent command file must be an error rather than an empty success.
    & {
        $script:MOLE_BIN = Join-Path $fixture 'bin'
        [IO.Directory]::CreateDirectory($script:MOLE_BIN) | Out-Null
        $fakeCommand = @'
param([Alias('dry-run')][switch]$DryRun, [switch]$ShowHelp)
[pscustomobject]@{ Preview = [bool]$DryRun; Help = [bool]$ShowHelp }
'@
        foreach ($name in @('clean', 'optimize')) {
            [IO.File]::WriteAllText((Join-Path $script:MOLE_BIN "$name.ps1"), $fakeCommand)
        }
        function Write-MoleError { }
        . (Read-Function (Join-Path $engine 'mole.ps1') 'Invoke-MoleCommand')
        foreach ($name in @('clean', 'optimize')) {
            $preview = Invoke-MoleCommand -CommandName $name -Arguments @('--dry-run')
            Assert-True $preview.Preview "$name lost its dry-run flag"
            $apply = Invoke-MoleCommand -CommandName $name -Arguments @()
            Assert-True (-not $apply.Preview) "$name apply was changed into a preview"
            $help = Invoke-MoleCommand -CommandName $name -Arguments @('--help')
            Assert-True $help.Help "$name help was not forwarded"
        }
        $refused = $false
        try { Invoke-MoleCommand -CommandName 'missing' -Arguments @() } catch { $refused = $true }
        Assert-True $refused 'A missing command script was reported as success'
    }

    # Run the restored clean entrypoint with its action replaced by an
    # assertion, then exercise its actual error path with a failing module.
    & {
        $DebugMode = $false; $ShowHelp = $false; $Whitelist = $false
        $DryRun = $true; $System = $false; $GameMedia = $false
        $script:previewReached = $false
        function Clear-TempFiles { }
        function Start-Cleanup {
            param([bool]$IsDryRun, [bool]$IncludeSystem, [bool]$IncludeGameMedia)
            Assert-True $IsDryRun 'Clean entrypoint dropped preview mode'
            Assert-True ($env:MOLE_DRY_RUN -eq '1') 'Clean environment dropped preview mode'
            $script:previewReached = $true
        }
        . (Read-Function (Join-Path $engine 'bin/clean.ps1') 'Main')
        Main
        Assert-True $script:previewReached 'Clean entrypoint did not dispatch'
        $DryRun = $false
        $script:previewReached = $false
        Main
        Assert-True $script:previewReached 'Clean ignored the environment preview guard'

        $script:ExportListFile = Join-Path $fixture 'preview.txt'
        $script:Config = @{ WhitelistFile = (Join-Path $fixture 'whitelist.txt') }
        $script:Icons = @{ Admin = ''; Solid = ''; Success = '' }
        function Clear-Host { }
        function Get-WindowsVersion { @{ Name = 'Fixture' } }
        function Get-FreeSpace { '0' }
        function Reset-CleanupStats { }
        function Set-DryRunMode { param([bool]$Enabled); Assert-True $Enabled 'Cleanup module lost preview mode' }
        function Invoke-UserCleanup { throw 'fixture cleanup failure' }
        function Write-MoleError { }
        . (Read-Function (Join-Path $engine 'bin/clean.ps1') 'Start-Cleanup')
        $refused = $false
        try { Start-Cleanup -IsDryRun $true -IncludeSystem $false -IncludeGameMedia $false } catch {
            $refused = $_.Exception.Message -eq 'fixture cleanup failure'
        }
        Assert-True $refused 'Cleanup swallowed a module failure'
    }

    # Exercise the real dry-run branches. Any mutator call increments a
    # counter and throws, even if a command's own catch would hide the error.
    & {
        $script:DryRun = $true
        $script:OptimizationsApplied = 0
        $script:unexpectedMutations = 0
        $script:Icons = @{ Arrow = ''; DryRun = ''; Warning = ''; Admin = ''; Success = '' }
        function Test-IsAdmin { $true }
        function Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        foreach ($name in @('Remove-Item', 'Clear-DnsClientCache', 'Optimize-Volume', 'Start-Service',
                            'Stop-Service', 'Stop-Process', 'Start-Process', 'Set-Service', 'netsh', 'Start-Sleep')) {
            Set-Item -LiteralPath "Function:$name" -Value {
                $script:unexpectedMutations++
                throw 'Preview reached a mutating command'
            }
        }
        $tasks = @('Optimize-DiskDrive', 'Optimize-SearchIndex', 'Clear-DnsCache', 'Optimize-Network',
                   'Test-SystemFiles', 'Repair-FontCache', 'Repair-StoreCache', 'Repair-SearchIndex', 'Repair-IconCache')
        foreach ($name in $tasks) {
            . (Read-Function (Join-Path $engine 'bin/optimize.ps1') $name)
            & $name
        }
        Assert-True ($script:unexpectedMutations -eq 0) 'An optimize preview attempted to mutate the host'

        # Every actual action is replaced before exercising live Main. The
        # optional SFC prompt is retained only for an interactive console.
        foreach ($name in ($tasks + @('Get-StartupPrograms', 'Test-DiskHealth', 'Test-WindowsUpdate',
                                      'Show-OptimizeSummary', 'Show-SystemHealth', 'Clear-Host'))) {
            Set-Item -LiteralPath "Function:$name" -Value { }
        }
        function Get-SystemHealth { @{} }
        $script:prompts = 0
        function Read-Host { $script:prompts++; 'n' }
        $DebugMode = $false; $ShowHelp = $false; $DryRun = $false
        . (Read-Function (Join-Path $engine 'bin/optimize.ps1') 'Main')
        $env:MOLE_DRY_RUN = '1'
        Main
        Assert-True $script:DryRun 'Optimize ignored the environment preview guard'
        Assert-True ($script:prompts -eq 0) 'An optimize preview prompted for a live repair'
        $env:MOLE_DRY_RUN = '0'
        Main
        $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
        Assert-True ($script:prompts -eq [int]$interactive) 'Optimize prompted with redirected stdio'
    }
    # A real failed action must make the overall command fail, even while
    # independent actions continue. Only mocked OS functions execute here.
    & {
        $optimize = Join-Path $engine 'bin/optimize.ps1'
        $script:Icons = @{ Arrow = ''; Error = ''; Success = ''; Warning = '' }
        foreach ($name in @('Register-OptimizeFailure', 'Clear-DnsCache', 'Optimize-Network',
                            'Repair-StoreCache', 'Show-OptimizeSummary', 'Main')) {
            . (Read-Function $optimize $name)
        }
        foreach ($name in @('Optimize-DiskDrive', 'Get-StartupPrograms', 'Test-DiskHealth',
                            'Test-WindowsUpdate', 'Repair-FontCache', 'Repair-SearchIndex',
                            'Repair-IconCache', 'Show-SystemHealth', 'Clear-Host')) {
            Set-Item -LiteralPath "Function:$name" -Value { }
        }
        $networkTask = ${function:Optimize-Network}
        $storeTask = ${function:Repair-StoreCache}
        function Optimize-Network { }
        function Repair-StoreCache { }
        function Get-SystemHealth { @{} }
        function Test-IsAdmin { $false }
        function Clear-DnsClientCache { throw 'fixture DNS failure' }
        $DebugMode = $false; $ShowHelp = $false; $DryRun = $false
        $env:MOLE_DRY_RUN = '0'
        $refused = $false
        try { Main } catch { $refused = $_.Exception.Message -like '*1 failed action*' }
        Assert-True $refused 'Optimize reported overall success after a failed DNS mutation'
        Assert-True ($script:OptimizationsApplied -eq 0) 'Optimize counted a failed DNS mutation as applied'

        # Native applications do not throw on a nonzero exit status in Windows
        # PowerShell. Both netsh failures must be observed before counting work.
        Set-Item -LiteralPath Function:Optimize-Network -Value $networkTask
        function Test-IsAdmin { $true }
        function netsh { $script:LASTEXITCODE = 5 }
        $script:FailedActions = 0
        Optimize-Network
        Assert-True ($script:FailedActions -eq 2) 'Optimize ignored a native netsh failure'
        Assert-True ($script:OptimizationsApplied -eq 0) 'Optimize counted failed netsh operations as applied'

        # The fake process never launches or sleeps. A timeout must kill/reap
        # the exact returned child and must not count a repair as successful.
        Set-Item -LiteralPath Function:Repair-StoreCache -Value $storeTask
        function Start-Process { $script:fakeStoreProcess }
        foreach ($state in @('success', 'nonzero', 'timeout')) {
            $script:FailedActions = 0
            $script:OptimizationsApplied = 0
            $script:RepairsApplied = 0
            $script:fakeStoreProcess = [pscustomobject]@{
                ExitCode = $(if ($state -eq 'nonzero') { 7 } else { 0 })
                HasExited = $state -ne 'timeout'
                TimedOut = $state -eq 'timeout'
                WaitCalls = 0
                Killed = $false
                Disposed = $false
            }
            $script:fakeStoreProcess | Add-Member ScriptMethod WaitForExit {
                param($Timeout)
                $this.WaitCalls++
                if ($null -ne $Timeout) { return -not $this.TimedOut }
            }
            $script:fakeStoreProcess | Add-Member ScriptMethod Kill {
                $this.Killed = $true; $this.HasExited = $true
            }
            $script:fakeStoreProcess | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
            Repair-StoreCache
            $succeeded = $state -eq 'success'
            Assert-True (($script:FailedActions -eq 0) -eq $succeeded) "Store reset $state had the wrong result"
            Assert-True ($script:OptimizationsApplied -eq [int]$succeeded) "Store reset $state counted an unsuccessful action"
            Assert-True ($script:RepairsApplied -eq [int]$succeeded) "Store reset $state counted an unsuccessful repair"
            Assert-True $script:fakeStoreProcess.Disposed 'Store reset leaked its process handle'
            Assert-True ($script:fakeStoreProcess.Killed -eq ($state -eq 'timeout')) 'Store reset killed the wrong process state'
            if ($state -eq 'timeout') {
                Assert-True ($script:fakeStoreProcess.WaitCalls -eq 2) 'Store reset did not reap its timed-out child'
            }
        }
    }

    # A cache deletion failure must not leave a stopped service/Explorer behind
    # or produce a successful repair count. All operations remain fake.
    & {
        $script:DryRun = $false
        $script:Icons = @{ Arrow = ''; Error = ''; Success = ''; Warning = '' }
        $script:FailedActions = 0; $script:OptimizationsApplied = 0; $script:RepairsApplied = 0
        $script:serviceStops = 0; $script:serviceStarts = 0
        $script:explorerStops = 0; $script:explorerStarts = 0
        function Test-IsAdmin { $true }
        function Test-NoReparsePointAncestor { $true }
        function Get-Service { [pscustomobject]@{ Status = 'Running' } }
        function Stop-Service { $script:serviceStops++ }
        function Start-Service { $script:serviceStarts++ }
        function Start-Sleep { }
        function Test-Path { param($Path, $LiteralPath, $PathType); $PathType -ne 'Container' }
        function Get-Item { [pscustomobject]@{ PSIsContainer = $false } }
        function Remove-Item { throw 'fixture cache deletion failed' }
        function Get-Process { [pscustomobject]@{ Id = 12345 } }
        function Stop-Process { $script:explorerStops++ }
        function Start-Process { $script:explorerStarts++ }
        function Get-ChildItem { [pscustomobject]@{ FullName = (Join-Path $fixture 'cache.db') } }
        foreach ($name in @('Register-OptimizeFailure', 'Assert-OptimizeCachePath',
                            'Remove-OptimizeCacheFile', 'Repair-FontCache', 'Repair-IconCache')) {
            . (Read-Function (Join-Path $engine 'bin/optimize.ps1') $name)
        }
        Repair-FontCache
        Assert-True ($script:FailedActions -eq 1) 'Font cache deletion failure was hidden'
        Assert-True ($script:OptimizationsApplied -eq 0 -and $script:RepairsApplied -eq 0) 'Failed font repair was counted'
        Assert-True ($script:serviceStops -eq 2 -and $script:serviceStarts -eq 2) 'Font repair did not restore its stopped services'
        $script:FailedActions = 0
        Repair-IconCache
        Assert-True ($script:FailedActions -eq 1) 'Icon cache deletion failure was hidden'
        Assert-True ($script:OptimizationsApplied -eq 0 -and $script:RepairsApplied -eq 0) 'Failed icon repair was counted'
        Assert-True ($script:explorerStops -eq 1 -and $script:explorerStarts -eq 1) 'Icon repair did not restore Explorer'
    }

    # Optimize's fixed cache paths share the ancestor inspection with cleanup.
    # Refusal occurs before any file-system mutator, including recursive work.
    & {
        $script:cacheMutations = 0
        function Test-NoReparsePointAncestor { $false }
        function Remove-Item { $script:cacheMutations++ }
        function Get-Item { throw 'Unsafe cache path reached metadata lookup' }
        function Get-ChildItem { throw 'Unsafe cache path reached directory traversal' }
        foreach ($name in @('Assert-OptimizeCachePath', 'Remove-OptimizeCacheFile', 'Clear-OptimizeCacheDirectory')) {
            . (Read-Function (Join-Path $engine 'bin/optimize.ps1') $name)
        }
        foreach ($name in @('Remove-OptimizeCacheFile', 'Clear-OptimizeCacheDirectory')) {
            $refused = $false
            try { & $name -Path (Join-Path $fixture 'redirected-cache') } catch {
                $refused = $_.Exception.Message -like '*reparse point*'
            }
            Assert-True $refused "$name did not reject an uninspectable or redirected cache path"
        }
        Assert-True ($script:cacheMutations -eq 0) 'A rejected optimize cache path reached a mutator'
    }
    Write-Output 'Mole routing, preview boundaries, failures, and noninteractive execution: PASS'
}
finally {
    [Environment]::SetEnvironmentVariable('MOLE_DRY_RUN', $savedDryRun, 'Process')
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $fixture -Recurse -Force
}
