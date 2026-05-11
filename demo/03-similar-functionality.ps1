#requires -Modules dbatools, PSFramework
cls
# =============================================================================
# Demo 03 — "Show of hands: how many of you have a scripts folder where you
# suspect three different people have written Get-LastBackupAge independently?"
#
# We've cloned a corpus of PowerShell from PSConfEU speakers + a handful of
# blog-classic repos, AST-extracted every function into dbo.ScriptFunction,
# embedded the function signature + body via Foundry's text-embedding-3-small,
# and built a DiskANN vector index. (Setup chain:
# 08-clone-repos → 10-deploy-script-function-table → 11-load-script-functions
# → 12-embed-script-functions → 13-create-vector-index.)
#
# Two queries pay off the setup:
#   Act 1  Find-SimilarFunction — paste a function body, get its neighbours.
#   Act 2  Find near-duplicates — self-join across the entire estate.
#
# The trick is embedding *functions*, not whole files. A 5,000-line module is
# too lumpy to embed meaningfully; a 30-line function is the right unit. That
# decision is what makes the matches actually useful.
# =============================================================================

# -----------------------------------------------------------------------------
# region : Connection
# -----------------------------------------------------------------------------
$SqlInstance   = '10.10.10.65'
$DatabaseName  = 'pwsh-scripts-🤣'
$SqlCredential = New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)

$connectParams = @{
    SqlInstance   = $SqlInstance
    SqlCredential = $SqlCredential
}
$Connection = Connect-DbaInstance @connectParams

$queryDefaults = @{
    SqlInstance = $Connection
    Database    = $DatabaseName
}

Write-PSFMessage -Level Host -Message "Connected to $SqlInstance / [$DatabaseName]"
# endregion
Write-PSFMessage -Level Host -Message "We have a corpus of a few thousand functions from across the PowerShell community, all embedded and indexed. Let's see what's in there."

# -----------------------------------------------------------------------------
# region : Reality check — what's in the corpus?
# -----------------------------------------------------------------------------
# Audience: "Quick look at the canvas. How many functions did we extract,
# from how many files, across how many repos? This is the haystack."

$statsQuery = @'
SELECT
    COUNT(*)                                  AS TotalFunctions,
    COUNT(DISTINCT FilePath)                  AS DistinctFiles,
    COUNT(*) - COUNT(Embedding)               AS PendingEmbed,
    AVG(LEN(Body))                            AS AvgBodyLength
FROM dbo.ScriptFunction;
'@
Invoke-DbaQuery @queryDefaults -Query $statsQuery | Format-Table -AutoSize

# Audience: "Few thousand functions, hundreds of files. The vector index
# means each search is sub-second regardless. Let's go find something."
Write-PSFMessage -Level Host -Message "Few thousand functions, hundreds of files. The vector index means each search is sub-second regardless. Let's see what's similar."
Read-Host "Press Enter for the first query"
cls
# endregion

# -----------------------------------------------------------------------------
# region : Act 2 — Near-duplicates across the estate
# -----------------------------------------------------------------------------
# Audience: "Second trick. We don't have a sample function this time — we
# self-join the table on itself and ask: 'show me every PAIR of functions
# whose vectors are within X cosine distance.' The < on FunctionId stops us
# pairing each row with itself and prevents (A, B) and (B, A) duplicates."

$dupesQuery = @'
WITH Pairs AS (
    SELECT a.FunctionId AS IdA,
           b.FunctionId AS IdB,
           a.FunctionName AS FunctionNameA,
           b.FunctionName AS FunctionNameB,
           a.OwnerName AS OwnerA,
           b.OwnerName AS OwnerB,
           a.RepoName AS RepoNameA,
           b.RepoName AS RepoNameB,
           a.FilePath AS PathA,
           b.FilePath AS PathB,
           VECTOR_DISTANCE('cosine', a.Embedding, b.Embedding) AS SimilarityDistance
    FROM (SELECT TOP 5000 * FROM dbo.ScriptFunction ORDER BY FunctionId) a
    JOIN (SELECT TOP 5000 * FROM dbo.ScriptFunction ORDER BY FunctionId) b ON a.FunctionId <> b.FunctionId
    WHERE
        a.FunctionId NOT IN (
1435   , -- Clear-GroupMembers
674       , -- Clear-GroupMembers
1837,    -- Get-CommandTreeCompletion
1837,    -- Get-CommandTreeCompletion
1838,    -- Register-ArgumentCompleter
1838,    -- Register-ArgumentCompleter
8084,    -- Convert-PSObjectToHashtable
1843,    -- Set-TabExpansionOption
1843,    -- Set-TabExpansionOption
1833,    -- Set-CompletionPrivateData
1833,    -- Set-CompletionPrivateData
1835,    -- Get-CompletionWithExtension
1835,    -- Get-CompletionWithExtension
1990,    -- Get-FilestreamReturnValue
1990,    -- Get-FilestreamReturnValue
11649,    -- Reset-SqlAdmin
1841,    -- WriteCompleters
1842,    -- WriteCompleter
1841,    -- WriteCompleters
1841    -- WriteCompleters
    )
    AND b.FunctionId NOT IN (
1435   , -- Clear-GroupMembers
674       , -- Clear-GroupMembers
1837,    -- Get-CommandTreeCompletion
1837,    -- Get-CommandTreeCompletion
1838,    -- Register-ArgumentCompleter
1838,    -- Register-ArgumentCompleter
8084,    -- Convert-PSObjectToHashtable
1843,    -- Set-TabExpansionOption
1843,    -- Set-TabExpansionOption
1833,    -- Set-CompletionPrivateData
1833,    -- Set-CompletionPrivateData
1835,    -- Get-CompletionWithExtension
1835,    -- Get-CompletionWithExtension
1990,    -- Get-FilestreamReturnValue
1990,    -- Get-FilestreamReturnValue
11649,    -- Reset-SqlAdmin
1841,    -- WriteCompleters
1842,    -- WriteCompleter
1841,    -- WriteCompleters
1841    -- WriteCompleters
    )
)
SELECT TOP 20
    IdA,
    IdB,
    FunctionNameA,
    FunctionNameB,
    OwnerA,
    OwnerB,
    RepoNameA,
    RepoNameB,
    PathA,
    PathB,
    SimilarityDistance
FROM Pairs
WHERE SimilarityDistance < 0.2
    AND FunctionNameA <> FunctionNameB
     AND OwnerA <> OwnerB

     /*
     Or just using the SimilarityDistance
     */
--WHERE SimilarityDistance < 0.2
--AND SimilarityDistance > 0.1


ORDER BY SimilarityDistance;
'@

Write-PSFMessage -Level Host -Message "Here's a sample of the near-duplicates across the corpus, within a cosine distance of 0.15:"
Read-Host "Press Enter to find near-duplicates across the corpus"

Invoke-DbaQuery @queryDefaults -Query $dupesQuery | Format-Table -AutoSize -Wrap


# -----------------------------------------------------------------------------
# region : Act 1 — Find-SimilarFunction
# -----------------------------------------------------------------------------
# Audience: "First trick. We paste in a function — any function — and ask the
# database 'show me the ten functions in the corpus most similar to this
# one.' We send the text to the embedding model, get a 1536-dimension vector
# back, hand it to VECTOR_SEARCH, and let the DiskANN index do the work."

function Find-SimilarFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FunctionText,
        [int] $Top = 10
    )

    $sql = @"
DECLARE @q VECTOR(1536) =
    AI_GENERATE_EMBEDDINGS(@text USE MODEL EmbeddingModel);

SELECT TOP (@top)
    f.FunctionName,
    f.FilePath,
    f.ParamSignature,
    s.distance
FROM   VECTOR_SEARCH(
           TABLE      = dbo.ScriptFunction AS f,
           COLUMN     = Embedding,
           SIMILAR_TO = @q,
           METRIC     = 'cosine',
           TOP_N      = @top) AS s
ORDER BY s.distance;
"@

    $params = @{
        SqlInstance  = $Connection
        Database     = $DatabaseName
        Query        = $sql
        SqlParameter = @{ text = $FunctionText; top = $Top }
    }
    Invoke-DbaQuery @params
}

# Audience: "Let's try a function the audience can guess at. 'Is this file
# older than N days' — the kind of thing every monitoring script reinvents."

$demoFunctions = [ordered]@{
    StaleFile = @'
function Test-StaleFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $Days = 7
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
    return $age.TotalDays -gt $Days
}
'@

    JsonRead = @'
function Read-ConfigJson {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }
    (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json
}
'@

    CsvExport = @'
function Export-ErrorReport {
    param(
        [Parameter(Mandatory)] [object[]] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )
    $InputObject |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
'@

    RetryWrapper = @'
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [int] $RetryCount = 3,
        [int] $DelaySeconds = 2
    )
    for ($i = 0; $i -lt $RetryCount; $i++) {
        try { return & $ScriptBlock }
        catch {
            if ($i -eq ($RetryCount - 1)) { throw }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}
'@
}

# Audience: "Let's make this interactive. You pick the kind of function,
# and we'll see what neighbours the model finds."

$demoFunctionKeys = @($demoFunctions.Keys)
$continueAct1 = $true

while ($continueAct1) {
    cls
    Write-PSFMessage -Level Host -Message ''
    Write-PSFMessage -Level Host -Message 'Pick a function sample to search:'
    for ($i = 0; $i -lt $demoFunctionKeys.Count; $i++) {
        Write-PSFMessage -Level Host -Message ("  [{0}] {1}" -f ($i + 1), $demoFunctionKeys[$i])
    }
    Write-PSFMessage -Level Host -Message "  [N] Move to next act"

    $choice = (Read-Host 'Choose 1-4 or N').Trim().ToUpperInvariant()
    if ($choice -eq 'N') { break }

    $selectedIndex = 0
    if (-not [int]::TryParse($choice, [ref]$selectedIndex)) {
        Write-PSFMessage -Level Warning -Message "Invalid choice '$choice'. Pick 1-4 or N."
        continue
    }
    if ($selectedIndex -lt 1 -or $selectedIndex -gt $demoFunctionKeys.Count) {
        Write-PSFMessage -Level Warning -Message "Choice '$selectedIndex' is out of range. Pick 1-$($demoFunctionKeys.Count)."
        continue
    }

    $selectedDemoFunction = $demoFunctionKeys[$selectedIndex - 1]
    $query = $demoFunctions[$selectedDemoFunction]

    Write-PSFMessage -Level Host -Message "Selected: $selectedDemoFunction"
    Write-PSFMessage -Level Host -Message "Here's the function we're going to search for:"
    Write-PSFMessage -Level Host -Message $query
    Read-Host 'Press Enter to search for similar functions across the corpus'

    Find-SimilarFunction -FunctionText $query -Top 10 | Format-Table -AutoSize -Wrap

    $again = (Read-Host 'Run another sample? (Y/N)').Trim().ToUpperInvariant()
    if ($again -ne 'Y') { $continueAct1 = $false }
}

# Audience: "Look at the names — Test-FileAge, Get-StaleBackups,
# Check-LogRotation, whatever floats up. Every one of those was written
# independently by somebody who didn't know about the others. Same logic,
# different names, never discoverable by Get-Command. The model recognised
# the SHAPE of the function, not the keywords."

Read-Host "Press Enter for the second query"
# endregion



# Audience: "Top of the list: probably-actual-duplicates. Different repos,
# sometimes different authors, doing the same thing. Now I'm going to slide
# the threshold up live — watch the pair list grow."

# PRESENTER: edit the WHERE Distance < ... value and re-run the query a
# couple of times: 0.05 → 0.15 → 0.25 → 0.30. The pair count grows, the
# clusters get fuzzier, and somewhere in the 0.20–0.30 range you cross
# from "near-duplicate" to "thematic neighbour" — both are interesting.

# CLOSER: paste the body of Find-CmdletByMeaning from demo 01 into
# Find-SimilarFunction and let the audience watch your own demo code
# matching itself across files. It always lands.

# Three takeaways for the slide that follows:
#   1. Embed the right unit. Functions, not files. Methods, not classes.
#   2. Vector index turns a self-join from "leave it overnight" into "live
#      on a slider."
#   3. This finds the thing Get-Command can't: 'we already wrote that, it's
#      just called something different.'
# endregion
