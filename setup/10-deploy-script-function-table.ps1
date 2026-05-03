#requires -Modules dbatools, PSFramework

# Deploys setup\09-script-function-table.sql — the dbo.ScriptFunction
# table for the demo-3 corpus. Idempotent (only CREATEs if missing) so
# re-runs preserve any data already loaded by 11-load-script-functions.

[CmdletBinding()]
param(
    [string] $SqlInstance = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),
    [string] $DatabaseName = 'pwsh-scripts-🤣'
)

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '09-script-function-table.sql'
Write-PSFMessage -Level Verbose -Message "Loading T-SQL from $scriptPath"
$sql = Get-Content -Path $scriptPath -Raw

$sql = $sql -replace '(?m)^\s*:setvar\s+\S+.*\r?\n', ''
$sql = $sql.Replace('$(DatabaseName)', $DatabaseName)

$queryParams = @{
    SqlInstance     = $SqlInstance
    Database        = $DatabaseName
    Query           = $sql
    EnableException = $true
}
if ($SqlCredential) { $queryParams.SqlCredential = $SqlCredential }

Write-PSFMessage -Level Host -Message "Deploying dbo.ScriptFunction to [$DatabaseName] on $SqlInstance"
Invoke-DbaQuery @queryParams

# Verify
$verifyParams = $queryParams.Clone()
$verifyParams.Query = 'SELECT COUNT(*) AS C FROM dbo.ScriptFunction'
$existing = (Invoke-DbaQuery @verifyParams).C
Write-PSFMessage -Level Host -Message "dbo.ScriptFunction ready. Existing rows: $existing"
Write-PSFMessage -Level Host -Message "Next: .\11-load-script-functions.ps1"
