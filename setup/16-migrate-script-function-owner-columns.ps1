#requires -Modules dbatools, PSFramework

# One-time migration for existing demo databases.
#
# Adds OwnerName and RepoName columns to dbo.ScriptFunction, backfills values
# from FilePath, and rebuilds the covering filtered index used by the dupes query.
#
# This avoids reloading the full corpus and re-embedding just to pick up the
# schema change.

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

$migrationSql = @'
IF COL_LENGTH('dbo.ScriptFunction', 'OwnerName') IS NULL
BEGIN
    ALTER TABLE dbo.ScriptFunction ADD OwnerName NVARCHAR(200) NULL;
END;

IF COL_LENGTH('dbo.ScriptFunction', 'RepoName') IS NULL
BEGIN
    ALTER TABLE dbo.ScriptFunction ADD RepoName NVARCHAR(300) NULL;
END;

;WITH Parsed AS (
    SELECT
        sf.FunctionId,
        folder.RepoFolder,
        CASE
            WHEN CHARINDEX('_', folder.RepoFolder) > 0
            THEN LEFT(folder.RepoFolder, CHARINDEX('_', folder.RepoFolder) - 1)
            ELSE folder.RepoFolder
        END AS OwnerName,
        CASE
            WHEN CHARINDEX('_', folder.RepoFolder) > 0
            THEN SUBSTRING(folder.RepoFolder, CHARINDEX('_', folder.RepoFolder) + 1, 8000)
            ELSE N''
        END AS RepoName
    FROM dbo.ScriptFunction AS sf
    CROSS APPLY (SELECT CHARINDEX('scripts-corpus\', sf.FilePath) AS MarkerPos) AS marker
    CROSS APPLY (
        SELECT CASE
            WHEN marker.MarkerPos > 0
            THEN marker.MarkerPos + LEN('scripts-corpus\')
            ELSE 0
        END AS RepoStartPos
    ) AS startpos
    CROSS APPLY (
        SELECT CASE
            WHEN startpos.RepoStartPos > 0
            THEN CHARINDEX('\', sf.FilePath, startpos.RepoStartPos)
            ELSE 0
        END AS RepoEndPos
    ) AS endpos
    CROSS APPLY (
        SELECT CASE
            WHEN startpos.RepoStartPos > 0 AND endpos.RepoEndPos > startpos.RepoStartPos
            THEN SUBSTRING(sf.FilePath, startpos.RepoStartPos, endpos.RepoEndPos - startpos.RepoStartPos)
            ELSE N''
        END AS RepoFolder
    ) AS folder
)
UPDATE sf
SET sf.OwnerName = p.OwnerName,
    sf.RepoName  = p.RepoName
FROM dbo.ScriptFunction AS sf
JOIN Parsed AS p
    ON p.FunctionId = sf.FunctionId
WHERE ISNULL(sf.OwnerName, N'') <> ISNULL(p.OwnerName, N'')
   OR ISNULL(sf.RepoName,  N'') <> ISNULL(p.RepoName,  N'');

DROP INDEX IF EXISTS IX_ScriptFunction_FunctionId_Embedding ON dbo.ScriptFunction;

CREATE INDEX IX_ScriptFunction_FunctionId_Embedding
ON dbo.ScriptFunction(FunctionId)
INCLUDE (FunctionName, OwnerName, RepoName, FilePath, Embedding)
WHERE Embedding IS NOT NULL;
'@

Write-PSFMessage -Level Host -Message "Applying one-time ScriptFunction owner/repo migration..."
$start = Get-Date
Invoke-DbaQuery @queryDefaults -Query $migrationSql -EnableException
$elapsed = (Get-Date) - $start

$checkSql = @'
SELECT
    COUNT(*) AS TotalRows,
    SUM(CASE WHEN ISNULL(OwnerName, N'') <> N'' THEN 1 ELSE 0 END) AS OwnerPopulated,
    SUM(CASE WHEN ISNULL(RepoName, N'')  <> N'' THEN 1 ELSE 0 END) AS RepoPopulated
FROM dbo.ScriptFunction;
'@
$check = Invoke-DbaQuery @queryDefaults -Query $checkSql -EnableException

Write-PSFMessage -Level Host -Message ("Migration complete in {0:N1}s" -f $elapsed.TotalSeconds)
Write-PSFMessage -Level Host -Message ("Rows: {0}; OwnerName populated: {1}; RepoName populated: {2}" -f $check.TotalRows, $check.OwnerPopulated, $check.RepoPopulated)
Write-PSFMessage -Level Host -Message "You can now run demo\03-similar-functionality.ps1 without reloading the corpus."
