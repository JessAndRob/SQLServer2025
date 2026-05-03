#requires -Modules dbatools, PSFramework

# Deploys setup\04-chat-procedures.sql (the SummariseFeedback +
# SummariseFeedbackWithNames procs) into the demo database.
#
# Important: this must produce the SAME OpenAIUri value that
# 03-deploy-database.ps1 used, because the database scoped credential is
# named after that URI. We mirror 03's logic exactly:
#   $endpoint = (secret).TrimEnd('/')
#   $Uri      = ($endpoint -split 'com')[0] + 'com'
# so the credential reference [OpenAIUri] in the proc resolves to the
# credential created by 03.

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
$endpoint     = (Get-Secret -Name "$($SecretPrefix)openai-endpoint" -AsPlainText).TrimEnd('/')
$Uri          = ($endpoint -split 'com')[0] + 'com'
$ChatEndpoint = "$Uri/openai/deployments/$ChatDeployment/chat/completions?api-version=$ChatApiVersion"

Write-PSFMessage -Level Host -Message "OpenAIUri (credential name): $Uri"
Write-PSFMessage -Level Host -Message "ChatEndpoint:                $ChatEndpoint"
Write-PSFMessage -Level Host -Message "ChatDeployment:              $ChatDeployment"

$scriptPath = Join-Path $PSScriptRoot '04-chat-procedures.sql'
Write-PSFMessage -Level Verbose -Message "Loading T-SQL from $scriptPath"
$sql = Get-Content -Path $scriptPath -Raw

# Strip the :setvar header (dbatools doesn't speak sqlcmd mode), then do
# token-substitution ourselves with [string]::Replace so values containing
# $, [, ], etc. don't blow up regex escaping.
$sql = $sql -replace '(?m)^\s*:setvar\s+\S+.*\r?\n', ''

$tokens = @{
    DatabaseName   = $DatabaseName
    OpenAIUri      = $Uri
    ChatEndpoint   = $ChatEndpoint
    ChatDeployment = $ChatDeployment
}

foreach ($name in $tokens.Keys) {
    $token = '$(' + $name + ')'
    $sql = $sql.Replace($token, $tokens[$name])
    Write-PSFMessage -Level Verbose -Message "Substituted $token with $($tokens[$name])"
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
Write-PSFMessage -Level Host -Message "Both procs reference credential [$Uri] created by 03-deploy-database.ps1"
