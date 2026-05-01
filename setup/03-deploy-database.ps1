#requires -Modules dbatools

# Deploys 02-database.sql to a SQL Server 2025 instance via dbatools, pulling
# the Azure OpenAI endpoint, key, and deployment name from SecretManagement.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SqlInstance,

    [pscredential] $SqlCredential,

    [string] $DatabaseName        = 'pwsh-scripts-🤣',
    [string] $MasterKeyPassword   = 'PSConfEU2026!',
    [string] $SecretPrefix        = 'psconfeu2026-',
    [string] $EmbeddingApiVersion = '2024-02-01'
)

$ErrorActionPreference = 'Stop'

# Pull the bits we stashed in 00-openai.ps1
$endpoint   = (Get-Secret -Name "$($SecretPrefix)openai-endpoint"   -AsPlainText).TrimEnd('/')
$apiKey     =  Get-Secret -Name "$($SecretPrefix)openai-key"        -AsPlainText
$deployment =  Get-Secret -Name "$($SecretPrefix)openai-deployment" -AsPlainText

# Load the script and substitute the sqlcmd-style variables. dbatools doesn't
# run sqlcmd-mode directives, so we strip the :setvar header block and replace
# $(VarName) tokens ourselves. Using [string]::Replace to avoid regex-escape
# headaches with values that contain $, [, ], etc.
$scriptPath = Join-Path $PSScriptRoot '02-database.sql'
$sql        = Get-Content -Path $scriptPath -Raw

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

$queryParams = @{
    SqlInstance     = $SqlInstance
    Database        = 'master'
    Query           = $sql
    EnableException = $true
}
if ($SqlCredential) { $queryParams.SqlCredential = $SqlCredential }

Invoke-DbaQuery @queryParams

Write-Host "Deployed [$DatabaseName] on $SqlInstance — EmbeddingModel pointing at $endpoint/openai/deployments/$deployment" -ForegroundColor Green
