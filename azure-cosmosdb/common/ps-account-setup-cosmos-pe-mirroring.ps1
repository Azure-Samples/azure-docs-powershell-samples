# Requires: 
# - Az PowerShell modules (Az.Accounts, Az.Resources, Az.CosmosDB)
# - Interactive sign-in via Connect-AzAccount
# - Subscription Owner or Cosmos DB Account Contributor permissions (will assign it if needed)
# - Fabric Workspace Admin role for the target workspace
# - Access to Microsoft Graph API and Fabric API (https://api.fabric.microsoft.com)
# --------------------------------------------------
# Purpose
# Comprehensive script to configure Azure Cosmos DB with private endpoints for Microsoft Fabric Mirroring
# This script combines RBAC setup, IP firewall configuration, and network ACL bypass setup

# Set strict mode for better error handling
$ErrorActionPreference = "Stop"

Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║   Azure Cosmos DB - Configure Mirroring with Private Endpoints ║
╚════════════════════════════════════════════════════════════════╝

This script will configure your Cosmos DB account with private endpoints for Fabric Mirroring.

"@ -ForegroundColor Cyan

# ---- Collect all parameters upfront ----
Write-Host "Please provide the following information:" -ForegroundColor Yellow
Write-Host ""

$subscriptionId = Read-Host "Enter the Azure Subscription ID"
$resourceGroup = Read-Host "Enter the Resource Group name"
$accountName = Read-Host "Enter the Cosmos DB account name"
$region = Read-Host "Enter the Azure region (e.g., westcentralus, eastus)"
$workspaceName = Read-Host "Enter the Fabric Workspace name"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ---- Pre-flight checks ----
Write-Host "Performing pre-flight checks..." -ForegroundColor Yellow

$requiredModules = @('Az.Accounts','Az.Resources','Az.CosmosDB')
$missing = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($missing) {
    Write-Error "The following Az modules are not installed: $($missing -join ', ')"
    Write-Error "Install them with: Install-Module -Name Az -Scope CurrentUser"
    exit 1
}

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-Host "No active Azure context detected. Launching interactive login..."
        Connect-AzAccount -ErrorAction Stop
        $context = Get-AzContext -ErrorAction Stop
    }
} catch {
    Write-Error "Authentication failed. Please run 'Connect-AzAccount' and try again."
    exit 1
}

Write-Host "Setting Azure subscription to $subscriptionId..."
try {
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Failed to set subscription to '$subscriptionId'. Verify the ID and your access."
    exit 1
}

Write-Host "✅ Pre-flight checks completed successfully!" -ForegroundColor Green
Write-Host ""

# ---- Display operations to be performed ----
Write-Host @"
═══════════════════════════════════════════════════════════════
Operations to be Performed
═══════════════════════════════════════════════════════════════

Step 1: Create/Assign RBAC Roles for Mirroring
        - Create custom Cosmos DB role with readMetadata and readAnalytics permissions
        - Create built-in Data Contributor role assignment
        - Assign roles to current user for Fabric mirroring access

Step 2: Temporarily enable public access and configure IP Firewall
        - Download Azure service tags for DataFactory and PowerQueryOnline
        - Filter IPv4 addresses for the specified region
        - Enable public network access (temporarily for setup)
        - Update Cosmos DB IP firewall rules
        ⏱️  Note: May take up to 15 minutes to propagate

Step 3: Configure Network ACL Bypass
        - Enable Fabric Network ACL Bypass capability
        - Retrieve Fabric workspace ID (You must be Admin for your workspace)
        - Configure network ACL bypass for Fabric workspace

Step 4: Create Fabric Mirror (Manual)
        - Instructions provided to create mirrored database in Fabric
        - Script will pause until you confirm completion

Step 5: Restore Network Access Settings
        - Disable public network access
        - Return account to original secure state

═══════════════════════════════════════════════════════════════

"@ -ForegroundColor Cyan

$continueSetup = Read-Host "Do you want to proceed with these operations? [y/N]"
if ($continueSetup.Trim().ToLower() -notin @('y','yes')) {
    Write-Host "Setup cancelled by user." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Track completed steps
$completedSteps = @()

# Capture initial public network access state
Write-Host "Capturing current Cosmos DB configuration..."
$initialAccount = Get-AzCosmosDBAccount -ResourceGroupName $resourceGroup -Name $accountName
$initialPublicNetworkAccess = $initialAccount.PublicNetworkAccess
Write-Host "Current Public Network Access: $initialPublicNetworkAccess"
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# STEP 1: Create/Assign RBAC Role
# ═══════════════════════════════════════════════════════════════
# Create a custom role definition with readMetadata and readAnalytics permissions
# and assign it to the current signed-in user.
# This is required to setup Cosmos DB Mirroring for Microsoft Fabric.

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  STEP 1: Create/Assign Mirroring RBAC Roles                    ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$proceedStep1 = Read-Host "Proceed with Step 1? [Y/n]"
if ($proceedStep1.Trim().ToLower() -in @('n','no')) {
    Write-Host "⏭️  Step 1 skipped" -ForegroundColor Yellow
} else {
    try {
        $roleName = "Custom-CosmosDB-Metadata-Analytics-Reader"
        $scope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.DocumentDB/databaseAccounts/$accountName"
        
        Write-Host "Checking for existing Cosmos DB SQL role definition '$roleName'..."
        $existingRole = Get-AzCosmosDBSqlRoleDefinition -ResourceGroupName $resourceGroup -AccountName $accountName -ErrorAction Stop |
                        Where-Object { $_.RoleName -eq $roleName } | Select-Object -First 1
        
        $roleGuid = $null
        $roleFullId = $null
        
        if ($existingRole) {
            $roleFullId = $existingRole.Id
            if ($roleFullId -and ($roleFullId -match '/sqlRoleDefinitions/([0-9a-fA-F-]+)$')) {
                $roleGuid = $Matches[1]
            } else {
                $roleGuid = $existingRole.Id
            }
        }
        
        if (-not $roleGuid) {
            $roleGuid = [Guid]::NewGuid().ToString()
            Write-Host "Creating new role definition with Id $roleGuid..."
            
            $dataActions = @(
                'Microsoft.DocumentDB/databaseAccounts/readMetadata',
                'Microsoft.DocumentDB/databaseAccounts/readAnalytics'
            )
            
            $createdRole = New-AzCosmosDBSqlRoleDefinition `
                -ResourceGroupName $resourceGroup `
                -AccountName $accountName `
                -RoleName $roleName `
                -AssignableScope @($scope) `
                -DataAction $dataActions `
                -Type 'CustomRole' `
                -Id $roleGuid -ErrorAction Stop
            
            $roleFullId = $createdRole.Id
            Write-Host "Created role definition '$roleName' ($roleGuid)."
        } else {
            Write-Host "Found existing role definition '$roleName' ($roleGuid)."
        }
        
        # Get current user principal ID
        Write-Host "Retrieving signed-in user ObjectId..."
        $principalId = $null
        
        $getAzADUser = Get-Command Get-AzADUser -ErrorAction SilentlyContinue
        if ($getAzADUser -and $getAzADUser.Parameters.ContainsKey('SignedIn')) {
            try {
                $signedInUser = Get-AzADUser -SignedIn -ErrorAction Stop
                $principalId = $signedInUser.Id
            } catch {
                $principalId = $null
            }
        }
        
        if (-not $principalId) {
            try {
                $token = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/' -ErrorAction Stop
                $me = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me' -Headers @{ Authorization = "Bearer $($token.Token)" } -ErrorAction Stop
                $principalId = $me.id
            } catch {
                throw "Could not determine the signed-in user. Ensure 'Connect-AzAccount' was performed with a user account."
            }
        }
        
        Write-Host "Current user object id: $principalId"
        
        # ─────────────────────────────────────────────────────────────────
        # 1A: Assign Custom Metadata/Analytics Reader Role
        # ─────────────────────────────────────────────────────────────────
        
        Write-Host ""
        Write-Host "Checking for existing custom role assignment..."
        $existingCustomAssignment = Get-AzCosmosDBSqlRoleAssignment -ResourceGroupName $resourceGroup -AccountName $accountName -ErrorAction Stop |
                                Where-Object { ($_.PrincipalId -eq $principalId) -and ($_.Scope -eq $scope) -and ($_.RoleDefinitionId -like "*${roleGuid}*") } | Select-Object -First 1
        
        if ($existingCustomAssignment) {
            Write-Host "✓ Custom role assignment already exists (Assignment Id: $($existingCustomAssignment.Id))."
        } else {
            Write-Host "→ Assigning custom metadata/analytics reader role to user..."
            $assignment = New-AzCosmosDBSqlRoleAssignment `
                -ResourceGroupName $resourceGroup `
                -AccountName $accountName `
                -RoleDefinitionId $roleGuid `
                -PrincipalId $principalId `
                -Scope $scope -ErrorAction Stop
            
            Write-Host "✓ Custom role assigned successfully. Assignment Id: $($assignment.Id)"
        }
        
        # ─────────────────────────────────────────────────────────────────
        # 1B: Assign Built-in Data Contributor Role
        # ─────────────────────────────────────────────────────────────────
        
        Write-Host ""
        Write-Host "Checking for existing Data Contributor role assignment..."
        $dataContributorRoleId = "00000000-0000-0000-0000-000000000002"
        $existingDataContributorAssignment = Get-AzCosmosDBSqlRoleAssignment -ResourceGroupName $resourceGroup -AccountName $accountName -ErrorAction Stop |
                                              Where-Object { ($_.PrincipalId -eq $principalId) -and ($_.Scope -eq $scope) -and ($_.RoleDefinitionId -like "*${dataContributorRoleId}*") } | Select-Object -First 1
        
        if ($existingDataContributorAssignment) {
            Write-Host "✓ Data Contributor role assignment already exists (Assignment Id: $($existingDataContributorAssignment.Id))."
        } else {
            Write-Host "→ Assigning built-in Data Contributor role to user..."
            $dataContributorAssignment = New-AzCosmosDBSqlRoleAssignment `
                -ResourceGroupName $resourceGroup `
                -AccountName $accountName `
                -RoleDefinitionId $dataContributorRoleId `
                -PrincipalId $principalId `
                -Scope $scope -ErrorAction Stop
            
            Write-Host "✓ Data Contributor role assigned successfully. Assignment Id: $($dataContributorAssignment.Id)"
        }
        
        Write-Host ""
        Write-Host "✅ Step 1: RBAC Roles Created/Assigned Successfully" -ForegroundColor Green
        $completedSteps += "✅ RBAC Role Configuration"
        
    } catch {
        Write-Error "Step 1 failed: $($_.Exception.Message)"
        exit 1
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# STEP 2: Configure IP Firewall
# ═══════════════════════════════════════════════════════════════
# Download and add DataFactory and PowerQueryOnline IP ranges to Cosmos DB IP firewall
# Enable public network access temporarily for setup then apply the IP firewall rules.
# This is necessary for Fabric to initially access the Cosmos DB account during initial setup.
# Once the mirroring is set up, public access can be disabled again leaving only private endpoints.

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  STEP 2: Enable public access and configure IP Firewall        ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "⏱️  Note: This step can take up to 15 minutes to complete." -ForegroundColor Yellow
Write-Host ""

$proceedStep2 = Read-Host "Proceed with Step 2? [Y/n]"
if ($proceedStep2.Trim().ToLower() -in @('n','no')) {
    Write-Host "⏭️  Step 2 skipped" -ForegroundColor Yellow
} else {
    try {
        $pageUrl = "https://www.microsoft.com/en-us/download/details.aspx?id=56519"
        
        Write-Host "Fetching Azure service tags page..."
        $pageContent = Invoke-WebRequest -Uri $pageUrl -UseBasicParsing
        $pageHtml = $pageContent.Content
        
        $jsonUrl = if ($pageHtml -match '(https?://[^"]+\.json)') { $Matches[1] } else { $null }
        if (-not $jsonUrl) {
            throw "Could not find JSON file link on the page."
        }
        
        Write-Host "Downloading service tags JSON file..."
        $jsonContent = Invoke-RestMethod -Uri $jsonUrl
        
        Write-Host "Parsing JSON for DataFactory.$region and PowerQueryOnline.$region service tags..."
        $dataFactorySearch = "DataFactory.$region"
        $powerQuerySearch = "PowerQueryOnline.$region"
        
        $dataFactoryIPs = @()
        foreach ($item in $jsonContent.values) {
            if ($item.name -ieq $dataFactorySearch) {
                $dataFactoryIPs = $item.properties.addressPrefixes
                break
            }
        }
        
        $powerQueryIPs = @()
        foreach ($item in $jsonContent.values) {
            if ($item.name -ieq $powerQuerySearch) {
                $powerQueryIPs = $item.properties.addressPrefixes
                break
            }
        }
        
        Write-Host "DataFactory IP count: $($dataFactoryIPs.Count)"
        Write-Host "PowerQueryOnline IP count: $($powerQueryIPs.Count)"
        
        $combinedIPs = @()
        if ($dataFactoryIPs.Count -gt 0) { $combinedIPs += $dataFactoryIPs }
        if ($powerQueryIPs.Count -gt 0) { $combinedIPs += $powerQueryIPs }
        
        if ($combinedIPs.Count -eq 0) {
            throw "No IP addresses found for either service."
        }
        
        Write-Host "Filtering out IPv6 addresses (Cosmos DB only supports IPv4)..."
        $ipv4OnlyIPs = $combinedIPs | Where-Object { $_ -notmatch ':' }
        
        if ($ipv4OnlyIPs.Count -eq 0) {
            throw "No IPv4 addresses found after filtering."
        }
        
        $ipv4Count = $ipv4OnlyIPs.Count
        Write-Host "IPv4 addresses: $ipv4Count"
        
        Write-Host "Enabling public network access and configuring IP firewall rules..."
        Write-Host "⏱️  This operation may take a moment..."
        
        # Combine both operations into a single call to avoid conflicts
        Update-AzCosmosDBAccount `
            -ResourceGroupName $resourceGroup `
            -Name $accountName `
            -PublicNetworkAccess "Enabled" `
            -IpRule $ipv4OnlyIPs `
            -ErrorAction Stop | Out-Null
        
        Write-Host ""
        Write-Host "✅ Step 2: IP Firewall Configured Successfully" -ForegroundColor Green
        Write-Host "   - IPv4 Addresses Added: $ipv4Count" -ForegroundColor Gray
        $completedSteps += "✅ IP Firewall Configuration ($ipv4Count addresses)"
        
    } catch {
        Write-Error "Step 2 failed: $($_.Exception.Message)"
        exit 1
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# STEP 3: Configure Network ACL Bypass
# ═══════════════════════════════════════════════════════════════
# This will configure the Cosmos DB account to allow Microsoft Fabric to bypass network ACLs.
# This is necessary for Fabric to access the Cosmos DB account for mirroring purposes when using private endpoints.


Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  STEP 3: Configure Network ACL Bypass                          ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$proceedStep3 = Read-Host "Proceed with Step 3? [Y/n]"
if ($proceedStep3.Trim().ToLower() -in @('n','no')) {
    Write-Host "⏭️  Step 3 skipped" -ForegroundColor Yellow
} else {
    try {
        Write-Host "Checking Cosmos DB account capabilities..."
        $account = Get-AzCosmosDBAccount -ResourceGroupName $resourceGroup -Name $accountName
        $currentCapabilities = $account.Capabilities | Select-Object -ExpandProperty Name
        
        if ($currentCapabilities -contains "EnableFabricNetworkAclBypass") {
            Write-Host "EnableFabricNetworkAclBypass capability already enabled."
        } else {
            Write-Host "Enabling Microsoft Fabric network ACL bypass capability..."
            
            # Get resource and add capability
            $cosmos = Get-AzResource -ResourceGroupName $resourceGroup -Name $accountName -ResourceType "Microsoft.DocumentDB/databaseAccounts"
            $cosmos.Properties.capabilities += @{ name = "EnableFabricNetworkAclBypass" }
            $cosmos | Set-AzResource -UsePatchSemantics -Force | Out-Null
            
            Write-Host "Capability enabled successfully."
        }
        
        Write-Host "Retrieving Tenant ID..."
        $tenantId = (Get-AzContext).Tenant.Id
        Write-Host "Tenant ID: $tenantId"
        
        Write-Host "Retrieving access token for Fabric API..."
        $fabricResourceUrl = "https://api.fabric.microsoft.com"
        $accessTokenSecure = Get-AzAccessToken -AsSecureString -ResourceUrl $fabricResourceUrl

        # Convert SecureString -> plain text safely
        $ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($accessTokenSecure.Token)
        try {
            $accessTokenPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
        }
        finally {
            # scrub from memory
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
        }

        $headers = @{
            "Authorization" = "$($accessTokenSecure.Type) $accessTokenPlain"  # e.g. "Bearer eyJ0eXAiOiJKV1Qi..."
            "Content-Type"  = "application/json"
        }
        
        Write-Host "Retrieving Fabric Workspace ID for workspace '$workspaceName'..."
        
        try {
            $response = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $headers -Method Get
        }
        catch {
            Write-Host "Fabric API Error Details:" -ForegroundColor Red
            Write-Host "Status Code: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Red
            Write-Host "Status Description: $($_.Exception.Response.StatusDescription)" -ForegroundColor Red
            if ($_.ErrorDetails.Message) {
                Write-Host "Error Message: $($_.ErrorDetails.Message)" -ForegroundColor Red
            }
            throw "Failed to retrieve workspaces from Fabric API: $_"
        }
        
        $workspace = $response.value | Where-Object { $_.displayName -eq $workspaceName } | Select-Object -First 1
        
        if (-not $workspace) {
            Write-Error "Failed to find Workspace ID for workspace '$workspaceName'."
            Write-Host "Available workspaces:" -ForegroundColor Yellow
            $response.value | ForEach-Object { Write-Host "  - $($_.displayName)" }
            throw "Workspace not found"
        }
        
        $workspaceId = $workspace.id
        Write-Host "Workspace ID: $workspaceId"
        
        $fabricResourceId = "/tenants/$tenantId/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Fabric/providers/Microsoft.Fabric/workspaces/$workspaceId"
        
        Write-Host "Checking current Network ACL Bypass configuration..."
        $account = Get-AzCosmosDBAccount -ResourceGroupName $resourceGroup -Name $accountName
        $currentBypass = $account.NetworkAclBypass
        $currentResourceIds = $account.NetworkAclBypassResourceId
        
        if ($currentResourceIds -contains $fabricResourceId) {
            Write-Host "Fabric Workspace '$workspaceName' is already configured in Network ACL Bypass."
        } else {
            Write-Host "Configuring Network ACL Bypass for Fabric Workspace..."
            
            $resourceIdsList = @()
            if ($currentResourceIds) {
                $resourceIdsList = @($currentResourceIds)
            }
            $resourceIdsList += $fabricResourceId
            
            if (-not $currentBypass -or $currentBypass -eq "None") {
                $bypassSetting = "AzureServices"
            } else {
                $bypassSetting = $currentBypass
            }
            
            Update-AzCosmosDBAccount `
                -ResourceGroupName $resourceGroup `
                -Name $accountName `
                -NetworkAclBypass $bypassSetting `
                -NetworkAclBypassResourceId $resourceIdsList | Out-Null
        }
        
        Write-Host ""
        Write-Host "✅ Step 3: Network ACL Bypass Configured Successfully" -ForegroundColor Green
        Write-Host "   - Workspace: $workspaceName" -ForegroundColor Gray
        $completedSteps += "✅ Network ACL Bypass Configuration"
        
    } catch {
        Write-Error "Step 3 failed: $($_.Exception.Message)"
        exit 1
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# STEP 4: Create Fabric Mirror (Manual Step)
# ═══════════════════════════════════════════════════════════════

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  STEP 4: Create Fabric Mirror (Manual)                         ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Host @"
📋 MANUAL ACTION REQUIRED

Please complete the following steps in Microsoft Fabric:

1. Navigate to your Fabric workspace: '$workspaceName'
2. Create a new Mirrored Database:
   - Click '+ New' → 'Mirrored Database'
   - Select 'Azure Cosmos DB'
3. Configure the connection
4. Complete the setup wizard and start mirroring
5. Wait for the initial synchronization to complete

Once you have successfully created the mirrored database and verified
that data is syncing, return to this script to disable public access and use private endpoints only.

"@ -ForegroundColor Yellow

$fabricComplete = Read-Host "Have you successfully created the Fabric mirror? [y/N]"
if ($fabricComplete.Trim().ToLower() -in @('y','yes')) {
    Write-Host "✅ Step 4: Fabric Mirror Created" -ForegroundColor Green
    $completedSteps += "✅ Fabric Mirror Created"
} else {
    Write-Host "⚠️  Step 4: Skipped or Not Completed" -ForegroundColor Yellow
    Write-Host "You can complete this step later and then manually run the cleanup." -ForegroundColor Yellow
    $completedSteps += "⏭️  Fabric Mirror Creation (skipped)"
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# STEP 5: Restore Network Access Settings
# ═══════════════════════════════════════════════════════════════

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  STEP 5: Restore Network Access Settings                       ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$proceedStep5 = Read-Host "Proceed with Step 5 (restore original network settings)? [Y/n]"
if ($proceedStep5.Trim().ToLower() -in @('n','no')) {
    Write-Host "⏭️  Step 5 skipped" -ForegroundColor Yellow
    Write-Host "⚠️  WARNING: Public network access remains ENABLED" -ForegroundColor Yellow
    $completedSteps += "⏭️  Network Settings Restoration (skipped - public access still enabled)"
} else {
    try {
        Write-Host "Initial Public Network Access state was: $initialPublicNetworkAccess"
        Write-Host ""
        Write-Host "Disabling public network access for security..." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "🔒 This will disable public network access, relying on:" -ForegroundColor Yellow
        Write-Host "   - Private endpoints for secure access" -ForegroundColor Yellow
        Write-Host "   - Network ACL bypass for Fabric workspace" -ForegroundColor Yellow
        Write-Host ""
        
        $confirmDisable = Read-Host "Confirm disabling public network access? [y/N]"
        if ($confirmDisable.Trim().ToLower() -in @('y','yes')) {
            Update-AzCosmosDBAccount `
                -ResourceGroupName $resourceGroup `
                -Name $accountName `
                -PublicNetworkAccess "Disabled" | Out-Null
            
            Write-Host ""
            Write-Host "✅ Step 5: Public Network Access Disabled" -ForegroundColor Green
            $completedSteps += "✅ Public Network Access Disabled"
        } else {
            Write-Host "⚠️  Public network access remains ENABLED" -ForegroundColor Yellow
            $completedSteps += "⏭️  Network Settings Restoration (cancelled - public access still enabled)"
        }
        
    } catch {
        Write-Error "Step 5 failed: $($_.Exception.Message)"
        Write-Warning "Public network access may still be enabled. Please check manually."
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════

Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                    SETUP COMPLETE!                             ║
╚════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green

Write-Host "Completed Steps:" -ForegroundColor Cyan
Write-Host "───────────────" -ForegroundColor Cyan
foreach ($step in $completedSteps) {
    Write-Host "  $step"
}

Write-Host ""
Write-Host @"
═══════════════════════════════════════════════════════════════
Configuration Summary
═══════════════════════════════════════════════════════════════
Subscription ID              : $subscriptionId
Resource Group               : $resourceGroup
Cosmos DB Account            : $accountName
Region                       : $region
Fabric Workspace             : $workspaceName
Initial Public Access        : $initialPublicNetworkAccess
Current Public Access        : $(try { (Get-AzCosmosDBAccount -ResourceGroupName $resourceGroup -Name $accountName).PublicNetworkAccess } catch { "Unknown" })

🎉 Your Cosmos DB account is now configured for Fabric Mirroring!
═══════════════════════════════════════════════════════════════

"@
