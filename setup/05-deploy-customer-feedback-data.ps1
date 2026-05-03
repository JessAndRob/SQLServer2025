#requires -Modules dbatools, PSFramework

# Deploys setup\04-customer-feedback-data.sql — the dbo.Customers and
# dbo.Feedback tables plus the clean seed (26 customers, 102 feedback
# rows). Re-runs are destructive: tables are DROPped first so the demo
# always begins from a known state.
#
# Run AFTER 03-deploy-database.ps1 (which creates the database) and
# BEFORE 07-deploy-chat-procedures.ps1 (so the procs can reference the
# tables when they're called by demo\03-summarise-and-inject.ps1).

[CmdletBinding()]
param(
    [string] $SqlInstance      = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),

    [string] $DatabaseName     = 'pwsh-scripts-🤣'
)

$ErrorActionPreference = 'Stop'

Write-PSFMessage -Level Host -Message "Deploying customer + feedback data to [$DatabaseName] on $SqlInstance"

$scriptPath = Join-Path $PSScriptRoot '04-customer-feedback-data.sql'
Write-PSFMessage -Level Verbose -Message "Loading T-SQL from $scriptPath"
$sql = Get-Content -Path $scriptPath -Raw

# Strip the :setvar header (dbatools doesn't speak sqlcmd mode) and
# substitute the one token we use.
$sql = $sql -replace '(?m)^\s*:setvar\s+\S+.*\r?\n', ''
$sql = $sql.Replace('$(DatabaseName)', $DatabaseName)

$queryParams = @{
    SqlInstance     = $SqlInstance
    Database        = $DatabaseName
    Query           = $sql
    EnableException = $true
}
if ($SqlCredential) { $queryParams.SqlCredential = $SqlCredential }

Write-PSFMessage -Level Host -Message "Running deployment"
Invoke-DbaQuery @queryParams

# Quick post-deploy verification so a failed seed is obvious from the log.
$verifyParams = @{
    SqlInstance = $SqlInstance
    Database    = $DatabaseName
    Query       = 'SELECT (SELECT COUNT(*) FROM dbo.Customers) AS Customers, (SELECT COUNT(*) FROM dbo.Feedback) AS FeedbackRows;'
}
if ($SqlCredential) { $verifyParams.SqlCredential = $SqlCredential }
$counts = Invoke-DbaQuery @verifyParams

Write-PSFMessage -Level Host -Message "Customers seeded: $($counts.Customers)"
Write-PSFMessage -Level Host -Message "Feedback seeded:  $($counts.FeedbackRows)"
Write-PSFMessage -Level Host -Message "(No injection rows in seed — demo\03-summarise-and-inject.ps1 adds those at runtime.)"
