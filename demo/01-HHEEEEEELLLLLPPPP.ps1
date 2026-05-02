# =============================================================================
# Demo 01 — HHEEEEEELLLLLPPPP
#
# Goal: harvest the help text for every cmdlet/function on this box, push the
# rows into the dbo.CmdletHelp table, and prove they landed.
#
# The next demo (02-...) will turn the SearchText column into vector embeddings
# via the Foundry-backed EXTERNAL MODEL we wired up in setup\02-database.sql,
# so the shape of the rows we insert here matters — keep it stable.
# =============================================================================

# -----------------------------------------------------------------------------
# Connection — splatted so the demo audience can see every named parameter at
# once, and so we can reuse $Connection for the rest of the script (one auth,
# many queries).
# -----------------------------------------------------------------------------
$SqlInstance   = '10.10.10.65'
$DatabaseName  = 'pwsh-scripts-🤣'
$SqlCredential = New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)

$connectParams = @{
    SqlInstance   = $SqlInstance
    SqlCredential = $SqlCredential
}
$Connection = Connect-DbaInstance @connectParams

# -----------------------------------------------------------------------------
# Harvest every cmdlet/function that has either a HelpUri or a Description —
# that filter drops the noise (aliases, raw script blocks, etc.) so we only
# embed things a human might actually search for.
#
# Heads-up for the demo: this is the slow bit. On a fresh shell with lots of
# modules loaded it can run for a minute or two — good moment to talk through
# what's coming next.
# -----------------------------------------------------------------------------
$cmdlets = Get-Command -CommandType Cmdlet, Function |
    Where-Object { $_.HelpUri -or $_.Description }

$rows = foreach ($c in $cmdlets) {
    $help = Get-Help $c.Name -ErrorAction SilentlyContinue
    if (-not $help) { continue }

    # SearchText is what the embedding model will see. We collapse whitespace
    # so multi-line help text doesn't waste embedding tokens on layout.
    [PSCustomObject]@{
        Name        = $c.Name
        ModuleName  = $c.ModuleName
        Synopsis    = ($help.Synopsis    | Out-String).Trim()
        Description = ($help.Description | Out-String).Trim()
        SearchText  = "$($c.Name). $($help.Synopsis) $($help.Description)" -replace '\s+', ' '
    }
}

# -----------------------------------------------------------------------------
# Bulk insert via Write-DbaDbTableData. AutoCreateTable is OFF on purpose:
# the schema (including VECTOR(1536) for the embeddings) was created by the
# setup script and we don't want dbatools to invent a different shape.
# -----------------------------------------------------------------------------
$writeParams = @{
    SqlInstance     = $Connection
    Database        = $DatabaseName
    Table           = 'CmdletHelp'
    AutoCreateTable = $false
}
$rows | Write-DbaDbTableData @writeParams

# -----------------------------------------------------------------------------
# Sanity check — pull the first three rows back so the audience sees that
# what went up actually landed in the right shape (and that Embedding is NULL
# for now, which is exactly what the next demo will fix).
# -----------------------------------------------------------------------------
$queryParams = @{
    SqlInstance = $Connection
    Database    = $DatabaseName
    Query       = 'SELECT TOP 3 * FROM CmdletHelp'
}
Invoke-DbaQuery @queryParams

$UpdateEmbeddingsParams = @{
    SqlInstance = $Connection
    Database    = $DatabaseName
    Query       = 'UPDATE dbo.CmdletHelp
SET Embedding = AI_GENERATE_EMBEDDINGS(SearchText USE MODEL EmbeddingModel)
WHERE Embedding IS NULL;'
}
Invoke-DbaQuery @UpdateEmbeddingsParams