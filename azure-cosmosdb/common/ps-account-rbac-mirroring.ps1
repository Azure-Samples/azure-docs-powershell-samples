# Requires: Az PowerShell modules (Az.Accounts, Az.Resources, Az.CosmosDB) and an interactive sign-in via Connect-AzAccount
# --------------------------------------------------
# Purpose
# Create a custom role definition in an Azure Cosmos DB account with readMetadata and readAnalytics permissions, and assign it to the current signed-in user.
# This is required to setup Cosmos DB Mirroring for Microsoft Fabric.
# --------------------------------------------------

param(
    [string]$JsonPath = "Custom-CosmosDB-Metadata-Analytics-Reader.json"
)

# Variables - ***** SUBSTITUTE YOUR VALUES *****
$subscriptionId = Read-Host "Enter the Azure Subscription ID"
$resourceGroup  = Read-Host "Enter the Resource Group name"
$accountName    = Read-Host "Enter the Cosmos DB account name"

# Prompt whether to export the role definition to JSON (interactive)
$saveJsonAnswer = Read-Host "Save role definition to JSON in the current directory (optional)? [y/N]"
$ExportRoleToJson = $saveJsonAnswer.Trim().ToLower() -in @('y','yes')

# ---- Pre-flight checks ----
$requiredModules = @('Az.Accounts','Az.Resources','Az.CosmosDB')
$missing = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($missing) {
    Write-Warning "The following Az modules are not installed: $($missing -join ', ')"
    Write-Warning "Install them with: Install-Module -Name Az -Scope CurrentUser -Force or Install-Module -Name <ModuleName> -Scope CurrentUser"
    throw "Required Az PowerShell modules missing: $($missing -join ', ')"
}

# Ensure user is connected
try {
    $context = Get-AzContext -ErrorAction Stop
} catch {
    Write-Host "No active Azure context detected. Launching interactive login..."
    Connect-AzAccount -ErrorAction Stop
    $context = Get-AzContext -ErrorAction Stop
}

# ---- Set subscription ----
try {
    Write-Host "Setting Azure subscription to $subscriptionId..."
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop
} catch {
    throw "Failed to set subscription to '$subscriptionId'. Ensure you have access to the subscription and the id is correct. Error: $($_.Exception.Message)"
}

# ---- Constants & Scope ----
$roleName = "Custom-CosmosDB-Metadata-Analytics-Reader"
$scope    = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.DocumentDB/databaseAccounts/$accountName"
$exportedJsonPath = $null

# ---- Ensure role definition exists (idempotent) ----
Write-Host "Checking for existing Cosmos DB SQL role definition '$roleName'..."
try {
    $existingRole = Get-AzCosmosDBSqlRoleDefinition -ResourceGroupName $resourceGroup -AccountName $accountName -ErrorAction Stop |
                    Where-Object { $_.RoleName -eq $roleName } | Select-Object -First 1
} catch {
    throw "Failed to list Cosmos DB role definitions. Verify access to the Cosmos DB account. Error: $($_.Exception.Message)"
}

$roleGuid = $null
$roleFullId = $null

if ($existingRole) {
    # Extract the GUID from the returned role Id (full resource id) if present
    $roleFullId = $existingRole.Id
    if ($roleFullId -and ($roleFullId -match '/sqlRoleDefinitions/([0-9a-fA-F-]+)$')) {
        $roleGuid = $Matches[1]
    } else {
        # If the Id property is a GUID or other form, try to use it directly
        $roleGuid = $existingRole.Id
    }
}

if (-not $roleGuid) {
    # Create a new role definition
    $roleGuid = [Guid]::NewGuid().ToString()
    Write-Host "No existing role found. Creating new role definition with Id $roleGuid..."

    $dataActions = @(
        'Microsoft.DocumentDB/databaseAccounts/readMetadata',
        'Microsoft.DocumentDB/databaseAccounts/readAnalytics'
    )

    try {
        $createdRole = New-AzCosmosDBSqlRoleDefinition `
            -ResourceGroupName $resourceGroup `
            -AccountName $accountName `
            -RoleName $roleName `
            -AssignableScope @($scope) `
            -DataAction $dataActions `
            -Type 'CustomRole' `
            -Id $roleGuid -ErrorAction Stop

        # cmdlet returns object with full Id path
        $roleFullId = $createdRole.Id
        Write-Host "Created role definition '$roleName' ($roleGuid)."

        if ($ExportRoleToJson) {
            $jsonObject = [PSCustomObject]@{
                Id = $roleGuid
                RoleName = $roleName
                Type = 'CustomRole'
                AssignableScopes = @($scope)
                Permissions = @( [PSCustomObject]@{ DataActions = $dataActions; NotDataActions = @() } )
            }
            # Always write to current directory and overwrite without prompting
            $targetPath = Join-Path (Get-Location) (Split-Path $JsonPath -Leaf)
            $jsonObject | ConvertTo-Json -Depth 5 | Set-Content -Path $targetPath -Encoding UTF8 -Force
            $exportedJsonPath = $targetPath
            Write-Host "Wrote JSON file: $targetPath"
        }
    } catch {
        throw "Role definition creation failed: $($_.Exception.Message)"
    }
} else {
    Write-Host "Found existing role definition '$roleName' ($roleGuid)."
    $dataActions = @(
        'Microsoft.DocumentDB/databaseAccounts/readMetadata',
        'Microsoft.DocumentDB/databaseAccounts/readAnalytics'
    )
    if ($ExportRoleToJson) {
        $jsonObject = [PSCustomObject]@{
            Id = $roleGuid
            RoleName = $roleName
            Type = 'CustomRole'
            AssignableScopes = @($scope)
            Permissions = @( [PSCustomObject]@{ DataActions = $dataActions; NotDataActions = @() } )
        }
        # Always write to current directory and overwrite without prompting
        $targetPath = Join-Path (Get-Location) (Split-Path $JsonPath -Leaf)
        $jsonObject | ConvertTo-Json -Depth 5 | Set-Content -Path $targetPath -Encoding UTF8 -Force
        $exportedJsonPath = $targetPath
        Write-Host "Wrote JSON file: $targetPath"
    }
}

# ---- Assign to current signed-in user (idempotent) ----
Write-Host "Retrieving signed-in user ObjectId..."
$principalId = $null

# Strategy 1: Use Get-AzADUser -SignedIn if that parameter exists (newer Az.Resources versions)
$getAzADUser = Get-Command Get-AzADUser -ErrorAction SilentlyContinue
if ($getAzADUser -and $getAzADUser.Parameters.ContainsKey('SignedIn')) {
    try {
        $signedInUser = Get-AzADUser -SignedIn -ErrorAction Stop
        $principalId = $signedInUser.Id
    } catch {
        # ignore and try other strategies
        $principalId = $null
    }
}

# Strategy 2: If context Account.Id looks like an object id (GUID) or a UPN, try using that or resolving it
if (-not $principalId) {
    $acct = Get-AzContext | Select-Object -ExpandProperty Account -ErrorAction SilentlyContinue
    if ($acct -and $acct.Id) {
        # If the account Id is a GUID, use it directly
        if ($acct.Id -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
            $principalId = $acct.Id
        } elseif ($acct.Id -like '*@*') {
            # try to resolve by UPN
            try {
                $user = Get-AzADUser -UserPrincipalName $acct.Id -ErrorAction Stop
                $principalId = $user.Id
            } catch {
                $principalId = $null
            }
        }
    }
}

# Strategy 3: Use Microsoft Graph /me with an access token (robust fallback for interactive sign-in)
if (-not $principalId) {
    try {
        $token = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/' -ErrorAction Stop
        $me = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me' -Headers @{ Authorization = "Bearer $($token.Token)" } -ErrorAction Stop
        $principalId = $me.id
    } catch {
        throw "Could not determine the signed-in user. Ensure 'Connect-AzAccount' was performed with a user account and that the session can call Microsoft Graph. Error: $($_.Exception.Message)"
    }
}
Write-Host "Current user object id: $principalId"

Write-Host "Checking for existing role assignment..."
try {
    $existingAssignment = Get-AzCosmosDBSqlRoleAssignment -ResourceGroupName $resourceGroup -AccountName $accountName -ErrorAction Stop |
                            Where-Object { ($_.PrincipalId -eq $principalId) -and ($_.Scope -eq $scope) -and ($_.RoleDefinitionId -like "*${roleGuid}*") } | Select-Object -First 1
} catch {
    throw "Failed to list Cosmos DB role assignments. Verify access to Cosmos DB account. Error: $($_.Exception.Message)"
}

if ($existingAssignment) {
    Write-Host "Role assignment already exists (Assignment Id: $($existingAssignment.Id))."
} else {
    Write-Host "Creating role assignment for principal $principalId..."
    try {
        $assignment = New-AzCosmosDBSqlRoleAssignment `
            -ResourceGroupName $resourceGroup `
            -AccountName $accountName `
            -RoleDefinitionId $roleGuid `
            -PrincipalId $principalId `
            -Scope $scope -ErrorAction Stop

        Write-Host "✅ Role assigned successfully. Assignment Id: $($assignment.Id)"
    } catch {
        throw "Role assignment failed: $($_.Exception.Message)"
    }
}

# ---- Summary ----
$jsonFileLine = if ($ExportRoleToJson) { "JSON File                    : $exportedJsonPath`n" } else { "" }

Write-Host @"

========================================
Summary
========================================
Subscription                 : $subscriptionId
Resource Group               : $resourceGroup
Cosmos DB Account            : $accountName
Scope                        : $scope
Role Name                    : $roleName
Role Id (GUID)               : $roleGuid
Role Full Id                 : $roleFullId
Principal Id                 : $principalId
$jsonFileLine
✅ Cosmos Mirroring RBAC Role assigned successfully!
========================================
"@
