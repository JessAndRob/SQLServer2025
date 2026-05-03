#requires -Modules dbatools, PSFramework

# Builds a DiskANN vector index on dbo.ScriptFunction(Embedding).
#
# Run AFTER 12-embed-script-functions.ps1 — without an index,
# VECTOR_DISTANCE / VECTOR_SEARCH still work but scale linearly with
# row count, which gets painful past a few thousand rows. With the
# index, the demo's "find similar function" query stays sub-second
# even on a 30K-row corpus.
#
# Vector indexing is a SQL Server 2025 PREVIEW feature; the database
# must have PREVIEW_FEATURES = ON (already set by setup\02-database.sql).

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

# Sanity check — warn if rows still pending
$pending = (Invoke-DbaQuery @queryDefaults -Query 'SELECT COUNT(*) AS C FROM dbo.ScriptFunction WHERE Embedding IS NULL').C
if ($pending -gt 0) {
    Write-PSFMessage -Level Warning -Message "$pending rows still have NULL Embedding. The index will only cover embedded rows. Run 12-embed-script-functions.ps1 first if you want full coverage."
}

$indexSql = @'
DROP INDEX IF EXISTS IX_ScriptFunction_Embedding ON dbo.ScriptFunction;

CREATE VECTOR INDEX IX_ScriptFunction_Embedding
ON dbo.ScriptFunction(Embedding)
WITH (METRIC = 'cosine', TYPE = 'DiskANN');
'@

Write-PSFMessage -Level Host -Message "Creating vector index (DiskANN, cosine)..."
$start = Get-Date
Invoke-DbaQuery @queryDefaults -Query $indexSql -EnableException
$elapsed = (Get-Date) - $start

Write-PSFMessage -Level Host -Message ("Done in {0:N1}s. Demo is ready to run: demo\03-similar-functionality.ps1" -f $elapsed.TotalSeconds)
