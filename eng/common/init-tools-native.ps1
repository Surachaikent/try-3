<#
.SYNOPSIS
Entry point script for installing native tools

.DESCRIPTION
Reads $RepoRoot\global.json file to determine native assets to install
and executes installers for those tools

.PARAMETER BaseUri
Base file directory or Url from which to acquire tool archives

.PARAMETER InstallDirectory
Directory to install native toolset.  This is a command-line override for the default
Install directory precedence order:
- InstallDirectory command-line override
- NETCOREENG_INSTALL_DIRECTORY environment variable
- (default) %USERPROFILE%/.netcoreeng/native

.PARAMETER Clean
Switch specifying to not install anything, but cleanup native asset folders

.PARAMETER Force
Clean and then install tools

.PARAMETER DownloadRetries
Total number of retry attempts

.PARAMETER RetryWaitTimeInSeconds
Wait time between retry attempts in seconds

.PARAMETER GlobalJsonFile
File path to global.json file

.NOTES
#>
[CmdletBinding(PositionalBinding=$false)]
Param (
  [string] $BaseUri = 'https://netcorenativeassets.blob.core.windows.net/resource-packages/external',
  [string] $InstallDirectory,
  [switch] $Clean = $False,
  [switch] $Force = $False,
  [int] $DownloadRetries = 5,
  [int] $RetryWaitTimeInSeconds = 30,
  [string] $GlobalJsonFile
)

if (!$GlobalJsonFile) {
  $GlobalJsonFile = Join-Path (Get-Item $PSScriptRoot).Parent.Parent.FullName 'global.json'
}

Set-StrictMode -version 2.0
$ErrorActionPreference='Stop'

. $PSScriptRoot\pipeline-logging-functions.ps1
Import-Module -Name (Join-Path $PSScriptRoot 'native\CommonLibrary.psm1')

try {
  # Define verbose switch if undefined
  $Verbose = $VerbosePreference -Eq 'Continue'

  $EngCommonBaseDir = Join-Path $PSScriptRoot 'native\'
  $NativeBaseDir = $InstallDirectory
  if (!$NativeBaseDir) {
    $NativeBaseDir = CommonLibrary\Get-NativeInstallDirectory
  }
  $Env:CommonLibrary_NativeInstallDir = $NativeBaseDir
  $InstallBin = Join-Path $NativeBaseDir 'bin'
  $InstallerPath = Join-Path $EngCommonBaseDir 'install-tool.ps1'

  # Process tools list
  Write-Host "Processing $GlobalJsonFile"
  If (-Not (Test-Path $GlobalJsonFile)) {
    Write-Host "Unable to find '$GlobalJsonFile'"
    exit 0
  }
  $NativeTools = Get-Content($GlobalJsonFile) -Raw |
                    ConvertFrom-Json |
                    Select-Object -Expand 'native-tools' -ErrorAction SilentlyContinue
  if ($NativeTools) {
    $NativeTools.PSObject.Properties | ForEach-Object {
      $ToolName = $_.Name
      $ToolVersion = $_.Value
      $LocalInstallerArguments =  @{ ToolName = "$ToolName" }
      $LocalInstallerArguments += @{ InstallPath = "$InstallBin" }
      $LocalInstallerArguments += @{ BaseUri = "$BaseUri" }
      $LocalInstallerArguments += @{ CommonLibraryDirectory = "$EngCommonBaseDir" }
      $LocalInstallerArguments += @{ Version = "$ToolVersion" }

      if ($Verbose) {
        $LocalInstallerArguments += @{ Verbose = $True }
      }
      if (Get-Variable 'Force' -ErrorAction 'SilentlyContinue') {
        if($Force) {
          $LocalInstallerArguments += @{ Force = $True }
        }
      }
      if ($Clean) {
        $LocalInstallerArguments += @{ Clean = $True }
      }

      Write-Verbose "Installing $ToolName version $ToolVersion"
      Write-Verbose "Executing '$InstallerPath $($LocalInstallerArguments.Keys.ForEach({"-$_ '$($LocalInstallerArguments.$_)'"}) -join ' ')'"
      & $InstallerPath @LocalInstallerArguments
      if ($LASTEXITCODE -Ne "0") {
        $errMsg = "$ToolName installation failed"
        if ((Get-Variable 'DoNotAbortNativeToolsInstallationOnFailure' -ErrorAction 'SilentlyContinue') -and $DoNotAbortNativeToolsInstallationOnFailure) {
            $showNativeToolsWarning = $true
            if ((Get-Variable 'DoNotDisplayNativeToolsInstallationWarnings' -ErrorAction 'SilentlyContinue') -and $DoNotDisplayNativeToolsInstallationWarnings) {
                $showNativeToolsWarning = $false
            }
            if ($showNativeToolsWarning) {
                Write-Warning $errMsg
            }
            $toolInstallationFailure = $true
        } else {
            # We cannot change this to Write-PipelineTelemetryError because of https://github.com/dotnet/arcade/issues/4482
            Write-Host $errMsg
            exit 1
        }
      }
    }

    if ((Get-Variable 'toolInstallationFailure' -ErrorAction 'SilentlyContinue') -and $toolInstallationFailure) {
        # We cannot change this to Write-PipelineTelemetryError because of https://github.com/dotnet/arcade/issues/4482
        Write-Host 'Native tools bootstrap failed'
        exit 1
    }
  }
  else {
    Write-Host 'No native tools defined in global.json'
    exit 0
  }

  if ($Clean) {
    exit 0
  }
  if (Test-Path $InstallBin) {
    Write-Host 'Native tools are available from ' (Convert-Path -Path $InstallBin)
    Write-Host "##vso[task.prependpath]$(Convert-Path -Path $InstallBin)"
    return $InstallBin
  }
  else {
    Write-PipelineTelemetryError -Category 'NativeToolsBootstrap' -Message 'Native tools install directory does not exist, installation failed'
    exit 1
  }
  exit 0
}
catch {
  Write-Host $_.ScriptStackTrace
  Write-PipelineTelemetryError -Category 'NativeToolsBootstrap' -Message $_
  ExitWithExitCode 1
}
