#requires -Modules dbatools, PSFramework

# Deploys setup\04-chat-procedures.sql (the SummariseFeedback +
# SummariseFeedbackWithNames procs) into the demo database. The OpenAI
# endpoint comes from SecretManagement (set by setup\00-openai.ps1); the
# chat deployment name and api-version are parameters because we don't
# auto-deploy a chat model in 00-openai.ps1 — many demo runners will
# already have one.

[CmdletBinding()]
param(
    [string] $SqlInstance      = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),

    [string] $DatabaseName     = 'pwsh-scripts-🤣',
    [string] $SecretPrefix     = 'psconfeu2026-',
    [string] $ChatDeployment   = 'gpt-4o-mini',
    [string] $ChatApiVersion   = '2024-02-01'
)

$ErrorActionPreference = 'Stop'

Write-PSFMessage -Level Host -Message "Deploying chat procedures to [$DatabaseName] on $SqlInstance"

Write-PSFMessage -Level Verbose -Message "Reading endpoint secret '$($SecretPrefix)openai-endpoint'"
$endpoint = (Get-Secret -Name "$($SecretPrefix)openai-endpoint" -AsPlainText).TrimEnd('/')
Write-PSFMessage -Level Host -Message "Endpoint:        $endpoint"
Write-PSFMessage -Level Host -Message "Chat deployment: $ChatDeployment"
Write-PSFMessage -Level Host -Message "API version:     $ChatApiVersion"

$scriptPath = Join-Path $PSScriptRoot '04-chat-procedures.sql'
Write-PSFMessage -Level Verbose -Message "Loading T-SQL from $scriptPath"
$sql = Get-Content -Path $scriptPath -Raw

# Strip the :setvar header (dbatools doesn't speak sqlcmd mode), then do
# token-substitution ourselves with [string]::Replace to avoid regex-escape
# issues if a value contains $, [, ], etc.
$sql = $sql -replace '(?m)^\s*:setvar\s+\S+.*\r?\n', ''

$tokens = @{
    DatabaseName   = $DatabaseName
    OpenAIEndpoint = $endpoint
    ChatDeployment = $ChatDeployment
    ChatApiVersion = $ChatApiVersion
}

foreach ($name in $tokens.Keys) {
    $token = '$(' + $name + ')'
    $sql = $sql.Replace($token, $tokens[$name])
}
Write-PSFMessage -Level Verbose -Message "Substituted $($tokens.Count) sqlcmd tokens"

$queryParams = @{
    SqlInstance     = $SqlInstance
    Database        = $DatabaseName
    Query           = $sql
    EnableException = $true
}
if ($SqlCredential) { $queryParams.SqlCredential = $SqlCredential }

Write-PSFMessage -Level Host -Message "Running deployment"
Invoke-DbaQuery @queryParams

Write-PSFMessage -Level Host -Message "Procedures deployed:"
Write-PSFMessage -Level Host -Message "  dbo.SummariseFeedback           (defended  — no PII in prompt, untrusted-input clause)"
Write-PSFMessage -Level Host -Message "  dbo.SummariseFeedbackWithNames  (vulnerable — joins Name + Email + Card into prompt)"
