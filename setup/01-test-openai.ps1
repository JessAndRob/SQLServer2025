# Quick smoke test for the Foundry text-embedding-3-small deployment.
# Pulls the endpoint/key/deployment from SecretManagement and asks for a
# single embedding. Prints the vector length and the first few values.

$secretPrefix = "psconfeu2026-"

$endpoint   = Get-Secret -Name "$($secretPrefix)openai-endpoint"   -AsPlainText
$apiKey     = Get-Secret -Name "$($secretPrefix)openai-key"        -AsPlainText
$deployment = Get-Secret -Name "$($secretPrefix)openai-deployment" -AsPlainText

$apiVersion = "2024-10-21"
$uri = "{0}openai/deployments/{1}/embeddings?api-version={2}" -f $endpoint, $deployment, $apiVersion

$body = @{
    input = "Hello from PSConfEU 2026 — is this thing on?"
} | ConvertTo-Json

$invokeParams = @{
    Uri         = $uri
    Method      = 'Post'
    Headers     = @{ 'api-key' = $apiKey }
    ContentType = 'application/json'
    Body        = $body
}

$response = Invoke-RestMethod @invokeParams

$vector = $response.data[0].embedding
[pscustomobject]@{
    Model         = $response.model
    PromptTokens  = $response.usage.prompt_tokens
    TotalTokens   = $response.usage.total_tokens
    VectorLength  = $vector.Count
    FirstFive     = $vector[0..4] -join ', '
}
