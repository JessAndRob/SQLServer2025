# Variables
$subscriptionId = (Get-Secret -Name beard-mvp-subscription-id -AsPlainText)
$resourceGroup   = "10yearsofPSConfeu"
$location        = "swedencentral"   # text-embedding-3-small availability varies by region
$resourceName    = "snover-ai"
$deploymentName  = "text-embedding-3-small"
$modelName       = "text-embedding-3-small"
$modelVersion    = "1"
$deploymentSku   = "GlobalStandard"
$deploymentCapacity = 50
$secretPrefix    = "psconfeu2026-"

# Login and select subscription
Connect-AzAccount
Set-AzContext -SubscriptionId $subscriptionId

if (-not (Get-AzResourceGroup -Name $resourceGroup -ErrorAction 'SilentlyContinue')) {
    New-AzResourceGroup -Name $resourceGroup -Location $location
}

# Create the Azure AI Foundry (Cognitive Services) account — kind 'AIServices' is the
# Foundry resource that exposes Azure OpenAI models through the unified endpoint.
$existingAccountParams = @{
    ResourceGroupName = $resourceGroup
    Name              = $resourceName
    ErrorAction       = 'SilentlyContinue'
}
if (-not (Get-AzCognitiveServicesAccount @existingAccountParams)) {
    $newAccountParams = @{
        ResourceGroupName   = $resourceGroup
        Name                = $resourceName
        Type                = 'AIServices'
        SkuName             = 'S0'
        Location            = $location
        CustomSubdomainName = $resourceName
    }
    New-AzCognitiveServicesAccount @newAccountParams
}

# Deploy the text-embedding-3-small model into the Foundry account

$existingDeploymentParams = @{
    ResourceGroupName = $resourceGroup
    AccountName       = $resourceName
    Name              = $deploymentName
    ErrorAction       = 'SilentlyContinue'
}
if (-not (Get-AzCognitiveServicesAccountDeployment @existingDeploymentParams)) {
    $newDeploymentParams = @{
        ResourceGroupName = $resourceGroup
        AccountName       = $resourceName
        Name              = $deploymentName
        Properties        = @{
            model = @{
                format  = 'OpenAI'
                name    = $modelName
                version = $modelVersion
            }
        }
        Sku               = @{
            name     = $deploymentSku
            capacity = $deploymentCapacity
        }
    }
    New-AzCognitiveServicesAccountDeployment @newDeploymentParams
}

# Stash the endpoint, key, and deployment name in SecretManagement so the demo can pick them up
$account = Get-AzCognitiveServicesAccount -ResourceGroupName $resourceGroup -Name $resourceName
$keys    = Get-AzCognitiveServicesAccountKey -ResourceGroupName $resourceGroup -Name $resourceName

$secrets = @{
    "$($secretPrefix)openai-endpoint"   = $account.Endpoint
    "$($secretPrefix)openai-key"        = $keys.Key1
    "$($secretPrefix)openai-deployment" = $deploymentName
}

foreach ($secretName in $secrets.Keys) {
    Set-Secret -Name $secretName -Secret $secrets[$secretName]
}

