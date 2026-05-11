#requires -Modules dbatools, PSFramework

# =============================================================================
# Demo 01 — "HHEEEEEELLLLLPPPP"
#
# Setup for this demo now lives in setup\03-deploy-database.ps1 so this file
# can stay stage-fast: connect, ask a question, get relevant cmdlets.
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
Write-PSFMessage -Level Host -Message "We have all the cmdlet help data we need, but let's ask some questions to find the right cmdlets for our needs. "
Read-Host "Press Enter to continue"
# endregion
cls

# -----------------------------------------------------------------------------
# region : Act 1 — find cmdlets by meaning
# -----------------------------------------------------------------------------
function Find-CmdletByMeaning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Question,
        [int] $Top = 5
    )

    $sql = @"
DECLARE @q VECTOR(1536) =
    AI_GENERATE_EMBEDDINGS(@question USE MODEL EmbeddingModel);

SELECT TOP (@top)
    Name,
    ModuleName,
    Synopsis,
    VECTOR_DISTANCE('cosine', Embedding, @q) AS Distance
FROM dbo.CmdletHelp
WHERE Embedding IS NOT NULL
ORDER BY Distance;
"@

    $params = $queryDefaults.Clone()
    $params.Query = $sql
    $params.SqlParameter = @{ question = $Question; top = $Top }
    Invoke-DbaQuery @params
}

Write-PSFMessage -Level Host -Message "Question: I need to read a file line by line"
Find-CmdletByMeaning -Question 'I need to read a file line by line' -Top 5 | Format-Table -AutoSize -Wrap

Read-Host "Press Enter for the next question"
cls
Write-PSFMessage -Level Host -Message "Question: how do I parse JSON"
Find-CmdletByMeaning -Question 'how do I parse JSON' -Top 5 | Format-Table -AutoSize -Wrap

Read-Host "Press Enter for the next question"
cls
Write-PSFMessage -Level Host -Message "Question: wait until a job finishes"
Find-CmdletByMeaning -Question 'wait until a job finishes' -Top 5 | Format-Table -AutoSize -Wrap
# endregion
