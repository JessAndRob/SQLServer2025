#requires -Modules dbatools, PSFramework

# Creates a covering filtered index on dbo.ScriptFunction for the demo 3 self-join.
#
# The Dupes query in demo\03-similar-functionality.ps1 performs a self-join
# comparing every pair of functions by vector distance. A covering index on
# (FunctionId) with INCLUDE produces dramatic performance improvement:
# - Without: ~15 seconds, 84M logical reads
# - With: ~2-3 seconds, reasonable I/O
#
# Run AFTER 13-create-vector-index.ps1. This step is resumable and idempotent.

[CmdletBinding()]
param(
    [string] $SqlInstance = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),
    [string] $DatabaseName = 'pwsh-scripts-🤣'
)

$ErrorActionPreference = 'Stop'

$queryDefaults = @{
    SqlInstance = $SqlInstance
    Database    = $DatabaseName
}
if ($SqlCredential) { $queryDefaults.SqlCredential = $SqlCredential }

$coveringIndexSql = @'
DROP INDEX IF EXISTS IX_ScriptFunction_FunctionId_Embedding ON dbo.ScriptFunction;

CREATE INDEX IX_ScriptFunction_FunctionId_Embedding
ON dbo.ScriptFunction(FunctionId)
INCLUDE (FunctionName, OwnerName, RepoName, FilePath, Embedding)
WHERE Embedding IS NOT NULL;
'@

Write-PSFMessage -Level Host -Message "Creating covering filtered index for Near-Duplicates query..."
$start = Get-Date
Invoke-DbaQuery @queryDefaults -Query $coveringIndexSql
$elapsed = (Get-Date) - $start

Write-PSFMessage -Level Host -Message ("Done in {0:N1}s" -f $elapsed.TotalSeconds)
Write-PSFMessage -Level Host -Message "Demo 3 is now optimized. Next: .\14-backup-database.ps1"
