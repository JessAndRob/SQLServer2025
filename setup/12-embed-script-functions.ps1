#requires -Modules dbatools, PSFramework

# Resumable embedding generator.
#
# Loops UPDATE TOP (n) ... AI_GENERATE_EMBEDDINGS(SearchText USE MODEL
# EmbeddingModel) until no rows remain with NULL embedding. Re-runs
# pick up where it left off — the WHERE Embedding IS NULL clause is the
# resume marker. OUTPUT INSERTED.FunctionId lets us count the actual
# rows updated in each batch.
#
# Speed bound: each row triggers one HTTP call to the Foundry embedding
# deployment. With deployment capacity 50 (50K TPM), expect roughly
# 500-1500 rows/min depending on body length. For a 30K-row corpus
# budget 30-60 minutes; the script is safe to interrupt and resume.

[CmdletBinding()]
param(
    [string] $SqlInstance = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),
    [string] $DatabaseName = 'pwsh-scripts-🤣',

    [int] $BatchSize = 50,
    [int] $MaxBatches               # optional cap (smoke testing)
)

$ErrorActionPreference = 'Stop'

$queryDefaults = @{
    SqlInstance = $SqlInstance
    Database    = $DatabaseName
}
if ($SqlCredential) { $queryDefaults.SqlCredential = $SqlCredential }

# ----- Initial counts -------------------------------------------------------
$counts = Invoke-DbaQuery @queryDefaults -Query @'
SELECT
    (SELECT COUNT(*) FROM dbo.ScriptFunction)                            AS Total,
    (SELECT COUNT(*) FROM dbo.ScriptFunction WHERE Embedding IS NULL)    AS Pending;
'@

Write-PSFMessage -Level Host -Message "Total rows:   $($counts.Total)"
Write-PSFMessage -Level Host -Message "Pending:      $($counts.Pending)"
Write-PSFMessage -Level Host -Message "Batch size:   $BatchSize"

if ($counts.Pending -eq 0) {
    Write-PSFMessage -Level Host -Message "Nothing to do."
    return
}

# ----- Embed in batches -----------------------------------------------------
$updateSql = @"
UPDATE TOP ($BatchSize) dbo.ScriptFunction
SET    Embedding = AI_GENERATE_EMBEDDINGS(SearchText USE MODEL EmbeddingModel)
OUTPUT INSERTED.FunctionId
WHERE  Embedding IS NULL;
"@

$batch = 0
$done  = 0
$start = Get-Date

while ($true) {
    if ($MaxBatches -and $batch -ge $MaxBatches) {
        Write-PSFMessage -Level Host -Message "Reached -MaxBatches ($MaxBatches); stopping."
        break
    }

    $batchStart = Get-Date
    try {
        $result = Invoke-DbaQuery @queryDefaults -Query $updateSql -EnableException
    } catch {
        Write-PSFMessage -Level Warning -Message ("Batch {0} failed: {1}. Sleeping 5s and retrying." -f ($batch + 1), $_.Exception.Message)
        Start-Sleep -Seconds 5
        continue
    }

    $batchCount = @($result).Count
    if ($batchCount -eq 0) { break }

    $done  += $batchCount
    $batch += 1

    $batchElapsed = (Get-Date) - $batchStart
    $rate = if ($batchElapsed.TotalSeconds -gt 0) { '{0:N1}' -f ($batchCount / $batchElapsed.TotalSeconds) } else { '?' }
    $eta  = if ($done -gt 0) {
        $perRow = ((Get-Date) - $start).TotalSeconds / $done
        $remain = ($counts.Pending - $done) * $perRow
        '{0:N1} min' -f ($remain / 60)
    } else { '?' }

    Write-PSFMessage -Level Host -Message ("Batch {0}: +{1} ({2} rows/s) — {3}/{4} done, ETA {5}" -f $batch, $batchCount, $rate, $done, $counts.Pending, $eta)
}

$elapsed = (Get-Date) - $start
Write-PSFMessage -Level Host -Message ("Done. Embedded {0} rows in {1:N1} min." -f $done, $elapsed.TotalMinutes)
Write-PSFMessage -Level Host -Message "Next: .\13-create-vector-index.ps1"
