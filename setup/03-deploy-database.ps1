#requires -Modules dbatools, PSFramework

# Deploys 02-database.sql to a SQL Server 2025 instance via dbatools, pulling
# the Azure OpenAI endpoint, key, and deployment name from SecretManagement.
# All output goes through PSFramework's Write-PSFMessage so it can be captured
# by any consumer (logfile providers, host, etc.).

[CmdletBinding()]
param(
    [string] $SqlInstance = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),

    [string] $DatabaseName        = 'pwsh-scripts-🤣',
    [string] $MasterKeyPassword   = 'PSConfEU2026!',
    [string] $SecretPrefix        = 'psconfeu2026-',
    [string] $EmbeddingApiVersion = '2024-02-01'
)

$ErrorActionPreference = 'Stop'

$connectParams = @{
    SqlInstance = $SqlInstance
}
if ($SqlCredential) { $connectParams.SqlCredential = $SqlCredential }
$Connection = Connect-DbaInstance @connectParams

Write-PSFMessage -Level Host -Message "Deploying [$DatabaseName] to $SqlInstance"

# Pull the bits we stashed in 00-openai.ps1
Write-PSFMessage -Level Verbose -Message "Reading OpenAI secrets with prefix '$SecretPrefix' from SecretManagement"
$endpoint   = (Get-Secret -Name "$($SecretPrefix)openai-endpoint"   -AsPlainText).TrimEnd('/')
$Uri        =        ($endpoint -split 'com')[0] + 'com'
$apiKey     =  Get-Secret -Name "$($SecretPrefix)openai-key"        -AsPlainText
$deployment =  Get-Secret -Name "$($SecretPrefix)openai-deployment" -AsPlainText
Write-PSFMessage -Level Host -Message "Endpoint:   $endpoint"
Write-PSFMessage -Level Host -Message "Deployment: $deployment"
Write-PSFMessage -Level Host -Message "Uri: $Uri"
Write-PSFMessage -Level Host -Message "API key:    [redacted, $($apiKey.Length) chars]"

# Load the script and substitute the sqlcmd-style variables. dbatools doesn't
# run sqlcmd-mode directives, so we strip the :setvar header block and replace
# $(VarName) tokens ourselves. Using [string]::Replace to avoid regex-escape
# headaches with values that contain $, [, ], etc.
$scriptPath = Join-Path $PSScriptRoot '02-database.sql'
Write-PSFMessage -Level Verbose -Message "Loading T-SQL from $scriptPath"
$sql = Get-Content -Path $scriptPath -Raw

$sql = $sql -replace '(?m)^\s*:setvar\s+\S+.*\r?\n', ''

$tokens = @{
    DatabaseName        = $DatabaseName
    MasterKeyPassword   = $MasterKeyPassword
    OpenAIEndpoint      = $endpoint
    OpenAIUri           = $Uri
    OpenAIKey           = $apiKey
    EmbeddingDeployment = $deployment
    EmbeddingApiVersion = $EmbeddingApiVersion
}

foreach ($name in $tokens.Keys) {
    $token = '$(' + $name + ')'
    $sql   = $sql.Replace($token, $tokens[$name])
Write-PSFMessage -Level Verbose -Message "Substituted $($token) sqlcmd token with $($tokens[$name])"

}
Write-PSFMessage -Level Verbose -Message "Substituted $($tokens.Count) sqlcmd tokens"

$queryParams = @{
    SqlInstance     = $Connection
    Database        = 'master'
    Query           = $sql
    EnableException = $true
}

Write-PSFMessage -Level Host -Message $sql

Write-PSFMessage -Level Host -Message "Running deployment script against $SqlInstance"
Invoke-DbaQuery @queryParams

Write-PSFMessage -Level Host -Message "Preparing cmdlet help corpus in dbo.CmdletHelp"

$cmdlets = Get-Command -CommandType Cmdlet, Function | Where-Object { $_.HelpUri -or $_.Description }
Write-PSFMessage -Level Host -Message "Found $($cmdlets.Count) commands to inspect"

$rows = foreach ($c in $cmdlets) {
    $help = Get-Help $c.Name -ErrorAction SilentlyContinue
    if (-not $help) { continue }

    [PSCustomObject]@{
        Name        = $c.Name
        ModuleName  = $c.ModuleName
        Synopsis    = ($help.Synopsis | Out-String).Trim()
        Description = ($help.Description | Out-String).Trim()
        SearchText  = "$($c.Name). $($help.Synopsis) $($help.Description)" -replace '\s+', ' '
    }
}

Write-PSFMessage -Level Host -Message "Writing $($rows.Count) cmdlet help rows to dbo.CmdletHelp"

$writeTableParams = @{
    SqlInstance     = $Connection
    Database        = $DatabaseName
    Table           = 'CmdletHelp'
    AutoCreateTable = $false
}
$rows | Write-DbaDbTableData @writeTableParams

$updateEmbeddingsParams = @{
    SqlInstance = $Connection
    Database    = $DatabaseName
    Query       = @'
UPDATE dbo.CmdletHelp
SET Embedding = AI_GENERATE_EMBEDDINGS(SearchText USE MODEL EmbeddingModel)
WHERE Embedding IS NULL;
'@
}
Write-PSFMessage -Level Host -Message "Generating embeddings for cmdlet help rows"
Invoke-DbaQuery @updateEmbeddingsParams | Out-Null

Write-PSFMessage -Level Host -Message "Deployed [$DatabaseName] on $SqlInstance"
Write-PSFMessage -Level Host -Message "EmbeddingModel -> $endpoint/openai/deployments/$deployment"
Write-PSFMessage -Level Host -Message "Table dbo.CmdletHelp loaded and embedded"
