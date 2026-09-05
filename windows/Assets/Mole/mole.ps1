#!/usr/bin/env pwsh
# Mole - Windows System Maintenance Toolkit
# Main CLI entry point

#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$CommandArgs,

    [Alias('v')]
    [switch]$Version,
    
    [Alias('h')]
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Get script directory
$script:MOLE_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:MOLE_BIN = Join-Path $script:MOLE_ROOT "bin"
$script:MOLE_LIB = Join-Path $script:MOLE_ROOT "lib"
$script:MOLE_CORE = Join-Path $script:MOLE_LIB "core"

# Read the version before loading the rest of the runtime so every entrypoint
# resolves the same release tag.
. "$script:MOLE_CORE\version.ps1"
$script:MOLE_VER = Get-MoleVersionString -RootDir $script:MOLE_ROOT

# Import core
. "$script:MOLE_LIB\core\common.ps1"

# ============================================================================
# Version Info
# ============================================================================

$script:MOLE_BUILD = "2026-01-07"

function Show-Version {
    $info = Get-MoleVersion
    Write-Host "Mole v$($info.Version)"
    Write-Host "Built: $($info.BuildDate)"
    Write-Host "PowerShell: $($info.PowerShell)"
    Write-Host "Windows: $($info.Windows)"
}

# ============================================================================
# Help
# ============================================================================

function Show-MainHelp {
    $cyan = $script:Colors.Cyan
    $gray = $script:Colors.Gray
    $green = $script:Colors.Green
    $nc = $script:Colors.NC

    Show-Banner

    Write-Host "  ${cyan}Windows System Maintenance Toolkit${nc}"
    Write-Host "  ${gray}Clean, optimize, and maintain your Windows system${nc}"
    Write-Host ""
    Write-Host "  ${green}COMMANDS:${nc}"
    Write-Host ""
    Write-Host "    ${cyan}clean${nc}       Deep system cleanup"
    Write-Host "    ${cyan}uninstall${nc}   Smart application uninstaller"
    Write-Host "    ${cyan}optimize${nc}    System optimization and repairs"
    Write-Host "    ${cyan}analyze${nc}     Disk space analyzer"
    Write-Host "    ${cyan}status${nc}      System monitor"
    Write-Host "    ${cyan}update${nc}      Update the source channel"
    Write-Host "    ${cyan}remove${nc}      Remove Mole from this system"
    Write-Host "    ${cyan}purge${nc}       Clean project artifacts"
    Write-Host ""
    Write-Host "  ${green}OPTIONS:${nc}"
    Write-Host ""
    Write-Host "    ${cyan}--version${nc}   Show version information"
    Write-Host "    ${cyan}--help${nc}      Show this help message"
    Write-Host ""
    Write-Host "  ${green}EXAMPLES:${nc}"
    Write-Host ""
    Write-Host "    ${gray}mo${nc}                      ${gray}# Interactive menu${nc}"
    Write-Host "    ${gray}mo clean${nc}                ${gray}# Deep cleanup${nc}"
    Write-Host "    ${gray}mo clean --dry-run${nc}      ${gray}# Preview cleanup${nc}"
    Write-Host "    ${gray}mo uninstall${nc}            ${gray}# Uninstall apps${nc}"
    Write-Host "    ${gray}mo analyze${nc}              ${gray}# Disk analyzer${nc}"
    Write-Host "    ${gray}mo status${nc}               ${gray}# System monitor${nc}"
    Write-Host "    ${gray}mo update${nc}               ${gray}# Pull latest windows source${nc}"
    Write-Host "    ${gray}mo remove${nc}               ${gray}# Remove Mole from this system${nc}"
    Write-Host "    ${gray}mo optimize${nc}             ${gray}# Optimize system (includes repairs)${nc}"
    Write-Host "    ${gray}mo optimize --dry-run${nc}   ${gray}# Preview optimizations${nc}"
    Write-Host "    ${gray}mo purge${nc}                ${gray}# Clean dev artifacts${nc}"
    Write-Host ""
    Write-Host "  ${green}ENVIRONMENT:${nc}"
    Write-Host ""
    Write-Host "    ${cyan}MOLE_DRY_RUN=1${nc}    Preview without changes"
    Write-Host "    ${cyan}MOLE_DEBUG=1${nc}      Enable debug output"
    Write-Host ""
    Write-Host "  ${gray}Run '${nc}mo <command> --help${gray}' for command-specific help${nc}"
    Write-Host ""
}

# ============================================================================
# Interactive Menu
# ============================================================================

function Show-MainMenu {
    $options = @(
        @{
            Name = "Clean"
            Description = "Deep system cleanup"
            Command = "clean"
            Icon = $script:Icons.Trash
        }
        @{
            Name = "Optimize"
            Description = "Optimization & repairs"
            Command = "optimize"
            Icon = $script:Icons.Arrow
        }
        @{
            Name = "Uninstall"
            Description = "Remove applications"
            Command = "uninstall"
            Icon = $script:Icons.Folder
        }
        @{
            Name = "Analyze"
            Description = "Disk space analyzer"
            Command = "analyze"
            Icon = $script:Icons.File
        }
        @{
            Name = "Status"
            Description = "System monitor"
            Command = "status"
            Icon = $script:Icons.Solid
        }
        @{
            Name = "Update"
            Description = "Pull latest source"
            Command = "update"
            Icon = $script:Icons.Arrow
        }
        @{
            Name = "Remove"
            Description = "Uninstall Mole"
            Command = "remove"
            Icon = $script:Icons.Trash
        }
        @{
            Name = "Purge"
            Description = "Clean dev artifacts"
            Command = "purge"
            Icon = $script:Icons.List
        }
    )

    $selected = Show-Menu -Title "What would you like to do?" -Options $options -AllowBack

    if ($null -eq $selected) {
        return $null
    }

    return $selected.Command
}

# ============================================================================
# Command Router
# ============================================================================

function Invoke-MoleCommand {
    param(
        [string]$CommandName,
        [string[]]$Arguments
    )

    $scriptPath = Join-Path $script:MOLE_BIN "$CommandName.ps1"

    if (-not (Test-Path $scriptPath)) {
        Write-MoleError "Unknown command: $CommandName"
        Write-Host ""
        throw "Bundled Mole command is missing: $CommandName"
    }

    # Execute the command script with arguments using splatting
    # This properly handles switch parameters passed as strings
    $argCount = if ($null -eq $Arguments) { 0 } else { @($Arguments).Count }
    if ($argCount -gt 0) {
        # Build a hashtable for splatting
        $splatParams = @{}
        $positionalArgs = @()

        foreach ($arg in $Arguments) {
            # Remove surrounding quotes if present
            $cleanArg = $arg.Trim("'`"")

            if ($cleanArg -match '^-{1,2}([\w-]+)$') {
                # It's a switch parameter (e.g., -DryRun or --dry-run)
                $paramName = $Matches[1]
                if ($paramName -eq "help" -or $paramName -eq "h") {
                    $paramName = "ShowHelp"
                }
                $splatParams[$paramName] = $true
            }
            elseif ($cleanArg -match '^-{1,2}([\w-]+)[=:](.+)$') {
                # It's a named parameter with value (e.g., --name=value)
                $paramName = $Matches[1]
                $paramValue = $Matches[2].Trim("'`"")
                $splatParams[$paramName] = $paramValue
            }
            else {
                # Positional argument
                $positionalArgs += $cleanArg
            }
        }

        # Execute with splatting
        if ($positionalArgs.Count -gt 0) {
            & $scriptPath @splatParams @positionalArgs
        }
        else {
            & $scriptPath @splatParams
        }
    }
    else {
        & $scriptPath
    }
}

# ============================================================================
# System Info Display
# ============================================================================

function Show-SystemInfo {
    $cyan = $script:Colors.Cyan
    $gray = $script:Colors.Gray
    $green = $script:Colors.Green
    $nc = $script:Colors.NC

    $winInfo = Get-WindowsVersion
    $freeSpace = Get-FreeSpace
    $isAdmin = if (Test-IsAdmin) { "${green}Yes${nc}" } else { "${gray}No${nc}" }

    Write-Host ""
    Write-Host "  ${gray}System:${nc} $($winInfo.Name)"
    Write-Host "  ${gray}Free Space:${nc} $freeSpace on $($env:SystemDrive)"
    Write-Host "  ${gray}Admin:${nc} $isAdmin"
    Write-Host ""
}

# ============================================================================
# Main
# ============================================================================

function Main {
    # Initialize
    Initialize-Mole

    # Handle switches passed as strings (when called via batch file with quoted args)
    # e.g., mole '-ShowHelp' becomes $Command = "-ShowHelp" instead of $ShowHelp = $true
    $effectiveShowHelp = $ShowHelp
    $effectiveVersion = $Version
    $effectiveCommand = $Command

    if ($Command -match '^-{1,2}(.+)$') {
        $switchName = $Matches[1].ToLower()
        switch ($switchName) {
            'showhelp' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'help' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'h' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'version' { $effectiveVersion = $true; $effectiveCommand = $null }
            'v' { $effectiveVersion = $true; $effectiveCommand = $null }
        }
    }

    # Handle version flag
    if ($effectiveVersion) {
        Show-Version
        return
    }

    # Handle help flag
    if ($effectiveShowHelp -and -not $effectiveCommand) {
        Show-MainHelp
        return
    }

    # If command specified, route to it
    if ($effectiveCommand) {
        $validCommands = @("clean", "uninstall", "analyze", "status", "optimize", "update", "remove", "purge")

        if ($effectiveCommand -in $validCommands) {
            $effectiveCommandArgs = @($CommandArgs)
            if ($effectiveShowHelp) {
                $effectiveCommandArgs = @("-ShowHelp") + $effectiveCommandArgs
            }
            Invoke-MoleCommand -CommandName $effectiveCommand -Arguments $effectiveCommandArgs
        }
        else {
            Write-MoleError "Unknown command: $effectiveCommand"
            Write-Host ""
            Write-Host "Available commands: $($validCommands -join ', ')"
            Write-Host "Run 'mo --help' for more information"
        }
        return
    }

    # Interactive mode
    Clear-Host
    Show-Banner
    Show-SystemInfo

    while ($true) {
        $selectedCommand = Show-MainMenu

        if ($null -eq $selectedCommand) {
            Clear-Host
            Write-Host ""
            Write-Host "  Goodbye!"
            Write-Host ""
            break
        }

        Clear-Host
        Invoke-MoleCommand -CommandName $selectedCommand -Arguments @()

        Write-Host ""
        Write-Host "  Press any key to continue..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        Clear-Host
        Show-Banner
        Show-SystemInfo
    }
}

# Run
try {
    Main
}
catch {
    Write-Host ""
    Write-MoleError "An error occurred: $_"
    Write-Host ""
    exit 1
}
finally {
    Clear-TempFiles
}
