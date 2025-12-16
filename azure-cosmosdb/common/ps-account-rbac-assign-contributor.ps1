# Reference: Az.CosmosDB | https://docs.microsoft.com/powershell/module/az.cosmosdb
# --------------------------------------------------
# Purpose
# This sample applies Data Contributor role to a single Azure Cosmos DB account
# This script will apply this role for the current logged in user
# to the specified Cosmos DB account.

# Set strict mode for better error handling
$ErrorActionPreference = "Stop"

# ---- Inputs ----
$resourceGroup = Read-Host "Enter the Resource Group name"
$account = Read-Host "Enter the Cosmos DB account name"

# ---- Pre-flight checks ----
Write-Host "Checking Az.CosmosDB PowerShell module..."
if (-not (Get-Module -ListAvailable -Name Az.CosmosDB)) {
    Write-Error "Az.CosmosDB module not found. Please install it with: Install-Module -Name Az.CosmosDB"
    exit 1
}

# Ensure logged in
Write-Host "Checking Azure authentication..."
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "You're not logged in. Run 'Connect-AzAccount' and try again."
        exit 1
    }
}
catch {
    Write-Error "You're not logged in. Run 'Connect-AzAccount' and try again."
    exit 1
}

# ---- Capture the current user's principal Id ----
Write-Host "Retrieving current user principal ID..."
try {
    $currentUser = Get-AzADUser -SignedIn
    $principalId = $currentUser.Id
    
    if (-not $principalId) {
        Write-Error "Failed to retrieve current user principal ID."
        exit 1
    }
}
catch {
    Write-Error "Failed to retrieve current user principal ID: $_"
    exit 1
}

Write-Host ""
Write-Host "Applying Cosmos DB Built-in Data Contributor role for user: $principalId"
Write-Host "Resource Group: $resourceGroup"
Write-Host "Cosmos Account: $account"
Write-Host "Please wait..."
Write-Host ""

# ---- Apply the RBAC policy to the Cosmos DB account ----
try {
    New-AzCosmosDBSqlRoleAssignment `
        -AccountName $account `
        -ResourceGroupName $resourceGroup `
        -RoleDefinitionName "Cosmos DB Built-in Data Contributor" `
        -Scope "/" `
        -PrincipalId $principalId | Out-Null
}
catch {
    Write-Error "Failed to apply RBAC policy: $_"
    exit 1
}

Write-Host ""
Write-Host "✅ Cosmos DB Built-in Data Contributor role applied successfully!"
