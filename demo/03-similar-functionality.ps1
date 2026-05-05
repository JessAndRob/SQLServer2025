#requires -Modules dbatools, PSFramework

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

Read-Host "Press Enter for the first query"
# endregion


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

$query = @'
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
Write-PSFMessage -Level Host -Message "Here's the function we're going to search for:"
Write-PSFMessage -Level Host -Message $query
Read-Host "Press Enter to search for similar functions across the corpus"

Find-SimilarFunction -FunctionText $query -Top 10 | Format-Table -AutoSize -Wrap

# Audience: "Look at the names — Test-FileAge, Get-StaleBackups,
# Check-LogRotation, whatever floats up. Every one of those was written
# independently by somebody who didn't know about the others. Same logic,
# different names, never discoverable by Get-Command. The model recognised
# the SHAPE of the function, not the keywords."

Read-Host "Press Enter for the second query"
# endregion


# -----------------------------------------------------------------------------
# region : Act 2 — Near-duplicates across the estate
# -----------------------------------------------------------------------------
# Audience: "Second trick. We don't have a sample function this time — we
# self-join the table on itself and ask: 'show me every PAIR of functions
# whose vectors are within X cosine distance.' The < on FunctionId stops us
# pairing each row with itself and prevents (A, B) and (B, A) duplicates."

$dupesQuery = @'
WITH RepoExtract AS (
    SELECT
        FunctionId,
        FunctionName,
        FilePath,
        Embedding,
        -- Extract repo folder (e.g., "EvotecIT_ADEssentials" from path)
        SUBSTRING(FilePath,
            CHARINDEX('scripts-corpus\', FilePath) + LEN('scripts-corpus\'),
            CHARINDEX('\', FilePath, CHARINDEX('scripts-corpus\', FilePath) + LEN('scripts-corpus\') + 1) -
            (CHARINDEX('scripts-corpus\', FilePath) + LEN('scripts-corpus\'))) AS RepoFolder
    FROM dbo.ScriptFunction
),
RepoWithOwner AS (
    SELECT
        FunctionId,
        FunctionName,
        FilePath,
        Embedding,
        RepoFolder,
        -- Extract owner (part before underscore)
        CASE
            WHEN CHARINDEX('_', RepoFolder) > 0
            THEN LEFT(RepoFolder, CHARINDEX('_', RepoFolder) - 1)
            ELSE RepoFolder
        END AS Owner,
        -- Extract repo name (part after underscore)
        CASE
            WHEN CHARINDEX('_', RepoFolder) > 0
            THEN SUBSTRING(RepoFolder, CHARINDEX('_', RepoFolder) + 1, 8000)
            ELSE ''
        END AS RepoName
    FROM RepoExtract
),
Pairs AS (
    SELECT a.FunctionId AS IdA,
           b.FunctionId AS IdB,
           a.FunctionName AS FunctionNameA,
           b.FunctionName AS FunctionNameB,
           a.Owner AS OwnerA,
           b.Owner AS OwnerB,
           a.RepoName AS RepoNameA,
           b.RepoName AS RepoNameB,
           a.FilePath AS PathA,
           b.FilePath AS PathB,
           VECTOR_DISTANCE('cosine', a.Embedding, b.Embedding) AS SimilarityDistance
    FROM RepoWithOwner a
    JOIN RepoWithOwner b ON a.FunctionId < b.FunctionId
    WHERE a.Embedding IS NOT NULL
      AND b.Embedding IS NOT NULL
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
WHERE SimilarityDistance < 0.15
    AND FunctionNameA <> FunctionNameB
    AND OwnerA <> OwnerB
ORDER BY SimilarityDistance;
'@

Write-PSFMessage -Level Host -Message "Here's a sample of the near-duplicates across the corpus, within a cosine distance of 0.15:"
Read-Host "Press Enter to find near-duplicates across the corpus"

Invoke-DbaQuery @queryDefaults -Query $dupesQuery | Format-Table -AutoSize -Wrap

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
