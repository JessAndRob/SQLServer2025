#requires -Modules dbatools, PSFramework

# Restores the demo database from a .bak created by 14-backup-database.ps1.
# Defaults to the most recently written .bak in $BackupRoot — pass -BackupPath
# to pick a specific one.
#
# Reads the backup header first and prints the embedded git metadata so
# you can confirm you're restoring the version of the demo you intended.

[CmdletBinding()]
param(
    [string] $SqlInstance = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),
    [string] $DatabaseName = 'pwsh-scripts-🤣',

    [string] $BackupRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'backups'),
    [string] $BackupPath
)

$ErrorActionPreference = 'Stop'

# ---- Pick a backup file ---------------------------------------------------
if (-not $BackupPath) {
    if (-not (Test-Path $BackupRoot)) {
        throw "No -BackupPath given and $BackupRoot does not exist."
    }
    $latest = Get-ChildItem -Path $BackupRoot -Filter '*.bak' -File |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1
    if (-not $latest) {
        throw "No .bak files in $BackupRoot. Run 14-backup-database.ps1 first."
    }
    $BackupPath = $latest.FullName
    Write-PSFMessage -Level Host -Message "Defaulting to most recent backup: $($latest.Name)"
} else {
    if (-not (Test-Path $BackupPath)) { throw "Backup file not found: $BackupPath" }
}

$headerParams = @{
    SqlInstance     = $SqlInstance
    Path            = $BackupPath
    EnableException = $true
}
if ($SqlCredential) { $headerParams.SqlCredential = $SqlCredential }

$header = Read-DbaBackupHeader @headerParams | Select-Object -First 1

Write-PSFMessage -Level Host -Message "----- Backup metadata -----"
Write-PSFMessage -Level Host -Message "File:        $BackupPath"
Write-PSFMessage -Level Host -Message "Source DB:   $($header.DatabaseName)"
Write-PSFMessage -Level Host -Message "Backed up:   $($header.BackupFinishDate)"
Write-PSFMessage -Level Host -Message "Description:"
foreach ($line in ($header.BackupDescription -split "`r?`n")) {
    Write-PSFMessage -Level Host -Message "  $line"
}
Write-PSFMessage -Level Host -Message "----------------------------"

# ---- Restore --------------------------------------------------------------
$restoreParams = @{
    SqlInstance     = $SqlInstance
    Path            = $BackupPath
    DatabaseName    = $DatabaseName
    WithReplace     = $true
    EnableException = $true
}
if ($SqlCredential) { $restoreParams.SqlCredential = $SqlCredential }

Write-PSFMessage -Level Host -Message "Restoring as [$DatabaseName] on $SqlInstance"
$result = Restore-DbaDatabase @restoreParams

Write-PSFMessage -Level Host -Message "Done. Restored database: $($result.Database)"
Write-PSFMessage -Level Host -Message "Demo is ready: demo\03-summarise-and-inject.ps1 / demo\03-similar-functionality.ps1"
