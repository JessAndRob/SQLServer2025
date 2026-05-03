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

$pendingSql = 'SELECT COUNT(*) AS Pending FROM dbo.ScriptFunction WHERE Embedding IS NULL;'

$batch       = 0
$start       = Get-Date
$lastPending = $counts.Pending

while ($true) {
    if ($MaxBatches -and $batch -ge $MaxBatches) {
        Write-PSFMessage -Level Host -Message "Reached -MaxBatches ($MaxBatches); stopping."
        break
    }

    $batchStart = Get-Date
    try {
        $result = Invoke-DbaQuery @queryDefaults -Query $updateSql -EnableException
    } catch {
        Write-PSFMessage -Level Significant -Message ("Batch {0} failed: {1}. Sleeping 5s and retrying." -f ($batch + 1), $_.Exception.Message)
        Start-Sleep -Seconds 5
        continue
    }

    $batchCount = @($result).Count
    if ($batchCount -eq 0) { break }

    $batch += 1

    # OUTPUT count is rows touched, not rows actually embedded — AI_GENERATE_EMBEDDINGS
    # returns NULL on throttling/failure, leaving Embedding IS NULL. Re-query to see real progress.
    $currentPending = (Invoke-DbaQuery @queryDefaults -Query $pendingSql).Pending
    if ($currentPending -eq 0) { break }

    if ($currentPending -ge $lastPending) {
        Write-PSFMessage -Level Significant -Message ("Batch {0}: touched {1} rows but pending unchanged at {2} (likely throttled). Sleeping 5 min." -f $batch, $batchCount, $currentPending)
        Start-Sleep -Seconds 300
        continue
    }

    $done         = $counts.Pending - $currentPending
    $batchElapsed = (Get-Date) - $batchStart
    $progress     = $lastPending - $currentPending
    $rate         = if ($batchElapsed.TotalSeconds -gt 0) { '{0:N1}' -f ($progress / $batchElapsed.TotalSeconds) } else { '?' }
    $eta          = if ($done -gt 0) {
        $perRow = ((Get-Date) - $start).TotalSeconds / $done
        $remain = $currentPending * $perRow
        '{0:N1} min' -f ($remain / 60)
    } else { '?' }

     Write-PSFMessage -Level Host -Message ("Batch {0}: +{1} embedded ({2} rows/s) — {3}/{4} done, {6} to complete ETA {5}" -f $batch, $progress, $rate, $done, $counts.Pending, $eta,$currentPending )


    $lastPending = $currentPending
}

$elapsed    = (Get-Date) - $start
$finalPending = (Invoke-DbaQuery @queryDefaults -Query $pendingSql).Pending
$embedded   = $counts.Pending - $finalPending
Write-PSFMessage -Level Host -Message ("Done. Embedded {0} rows in {1:N1} min ({2} still pending)." -f $embedded, $elapsed.TotalMinutes, $finalPending)
Write-PSFMessage -Level Host -Message "Next: .\13-create-vector-index.ps1"
