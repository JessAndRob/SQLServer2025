#requires -Modules dbatools, PSFramework

# Resumable AST loader for the demo-3 corpus.
#
# Walks $CorpusRoot for .ps1 / .psm1 files, parses each via the
# PowerShell AST, extracts every function definition, and bulk-inserts
# the rows into dbo.ScriptFunction.
#
# RESUMABILITY
# ------------
# The "already loaded" set is derived from the table itself:
#   SELECT DISTINCT FilePath FROM dbo.ScriptFunction
# Any file whose full path is already present is skipped. Each file's
# rows are written in a single Write-DbaDbTableData call (atomic via
# bulk copy) so partial-per-file states don't happen — either every
# function from a file is in the table, or none are.
#
# To start over, drop the table and re-run 10-deploy-script-function-table.ps1.

[CmdletBinding()]
param(
    [string] $SqlInstance = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),
    [string] $DatabaseName = 'pwsh-scripts-🤣',

    [string] $CorpusRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts-corpus'),

    [int] $ProgressEvery = 50,
    [int] $MaxFiles                # optional cap (smoke testing)
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CorpusRoot)) {
    throw "CorpusRoot '$CorpusRoot' does not exist. Run 08-clone-repos.ps1 first."
}

$queryDefaults = @{
    SqlInstance = $SqlInstance
    Database    = $DatabaseName
}
if ($SqlCredential) { $queryDefaults.SqlCredential = $SqlCredential }

# ----- Build the skip-set from the database --------------------------------
Write-PSFMessage -Level Host -Message "Reading already-loaded files from dbo.ScriptFunction..."
$loadedRows = Invoke-DbaQuery @queryDefaults -Query 'SELECT DISTINCT FilePath FROM dbo.ScriptFunction'
$loadedSet  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $loadedRows) { [void]$loadedSet.Add($row.FilePath) }
Write-PSFMessage -Level Host -Message "Already loaded: $($loadedSet.Count) files"

# ----- Discover candidate files --------------------------------------------
$allFiles = Get-ChildItem -Path $CorpusRoot -Recurse -Include *.ps1, *.psm1 -ErrorAction SilentlyContinue -File
$todo = $allFiles | Where-Object { -not $loadedSet.Contains($_.FullName) }
if ($MaxFiles) { $todo = $todo | Select-Object -First $MaxFiles }
$todoCount = @($todo).Count
Write-PSFMessage -Level Host -Message "Files to process: $todoCount of $($allFiles.Count) total"

if ($todoCount -eq 0) {
    Write-PSFMessage -Level Host -Message "Nothing to do."
    return
}

# ----- AST extraction helper -----------------------------------------------
function Get-ScriptFunctionRow {
    [CmdletBinding()]
    param([System.IO.FileInfo] $File)

    $tokens = $errors = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $File.FullName, [ref]$tokens, [ref]$errors)
    } catch {
        Write-PSFMessage -Level Verbose -Message ("Parse error in {0}: {1}" -f $File.FullName, $_.Exception.Message)
        return
    }

    $functions = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    foreach ($fn in $functions) {
        $params = $fn.Body.ParamBlock.Parameters | ForEach-Object {
            $type = if ($_.StaticType -and $_.StaticType.Name) { $_.StaticType.Name } else { 'object' }
            "$type `$$($_.Name.VariablePath.UserPath)"
        }

        $docComment = ($tokens | Where-Object {
            $_.Kind -eq 'Comment' -and
            $_.Extent.EndLineNumber -lt $fn.Extent.StartLineNumber
        } | Select-Object -Last 1).Text

        # text-embedding-3-small caps at ~8K tokens (~32K chars). Trim
        # the body so the embedding call stays cheap and never trips the
        # input-too-long error.
        $bodyText = $fn.Body.Extent.Text
        if ($bodyText.Length -gt 6000) {
            $bodyText = $bodyText.Substring(0, 6000) + "`n# (truncated for embedding)"
        }

        $searchText = @(
            "Function: $($fn.Name)"
            "Parameters: $($params -join ', ')"
            "Comment: $docComment"
            "Body: $bodyText"
        ) -join "`n"

        [pscustomobject]@{
            FilePath       = $File.FullName
            FunctionName   = $fn.Name
            ParamSignature = ($params -join ', ')
            Body           = $bodyText
            DocComment     = $docComment
            SearchText     = $searchText
        }
    }
}

# ----- Process per file (atomic per Write-DbaDbTableData) ------------------
$processed = 0
$rowsTotal = 0
$start = Get-Date

foreach ($file in $todo) {
    try {
        $rows = Get-ScriptFunctionRow -File $file
        if ($rows) {
            $rows | Write-DbaDbTableData @queryDefaults -Table 'ScriptFunction' -AutoCreateTable:$false -EnableException
            $rowsTotal += @($rows).Count
        }
    } catch {
        Write-PSFMessage -Level Warning -Message ("Failed to load {0}: {1}" -f $file.FullName, $_.Exception.Message)
        continue
    }

    $processed++
    if ($processed % $ProgressEvery -eq 0) {
        $elapsed = (Get-Date) - $start
        $rate = if ($elapsed.TotalSeconds -gt 0) { '{0:N1}' -f ($processed / $elapsed.TotalSeconds) } else { '?' }
        Write-PSFMessage -Level Host -Message "Processed $processed/$todoCount files, $rowsTotal functions, $rate files/s"
    }
}

$elapsed = (Get-Date) - $start
Write-PSFMessage -Level Host -Message ("Done. Loaded {0} functions from {1} files in {2:N1}s" -f $rowsTotal, $processed, $elapsed.TotalSeconds)
Write-PSFMessage -Level Host -Message "Next: .\12-embed-script-functions.ps1"
