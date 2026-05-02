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

Write-PSFMessage -Level Host -Message "Deploying [$DatabaseName] to $SqlInstance"

# Pull the bits we stashed in 00-openai.ps1
Write-PSFMessage -Level Verbose -Message "Reading OpenAI secrets with prefix '$SecretPrefix' from SecretManagement"
$endpoint   = (Get-Secret -Name "$($SecretPrefix)openai-endpoint"   -AsPlainText).TrimEnd('/')
$apiKey     =  Get-Secret -Name "$($SecretPrefix)openai-key"        -AsPlainText
$deployment =  Get-Secret -Name "$($SecretPrefix)openai-deployment" -AsPlainText
Write-PSFMessage -Level Host -Message "Endpoint:   $endpoint"
Write-PSFMessage -Level Host -Message "Deployment: $deployment"
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
    OpenAIKey           = $apiKey
    EmbeddingDeployment = $deployment
    EmbeddingApiVersion = $EmbeddingApiVersion
}

foreach ($name in $tokens.Keys) {
    $token = '$(' + $name + ')'
    $sql   = $sql.Replace($token, $tokens[$name])
}
Write-PSFMessage -Level Verbose -Message "Substituted $($tokens.Count) sqlcmd tokens"

$queryParams = @{
    SqlInstance     = $SqlInstance
    Database        = 'master'
    Query           = $sql
    EnableException = $true
}
if ($SqlCredential) { $queryParams.SqlCredential = $SqlCredential }

Write-PSFMessage -Level Host -Message "Running deployment script against $SqlInstance"
Invoke-DbaQuery @queryParams

Write-PSFMessage -Level Host -Message "Deployed [$DatabaseName] on $SqlInstance"
Write-PSFMessage -Level Host -Message "EmbeddingModel -> $endpoint/openai/deployments/$deployment"
Write-PSFMessage -Level Host -Message "Table dbo.CmdletHelp recreated empty and ready for embeddings"
