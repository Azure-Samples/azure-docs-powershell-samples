# ==================================================================================
# Azure Cosmos DB - Configure Mirroring for Private Endpoints or Virtual Networking
# ==================================================================================
#
# PURPOSE:
# Interactive script to configure Azure Cosmos DB accounts with private endpoints 
# for Microsoft Fabric Mirroring. Automates RBAC setup, temporary network access 
# configuration, and Network ACL bypass for Fabric workspaces.
#
# WHAT THIS SCRIPT DOES:
# Step 1: Creates custom RBAC role (readMetadata/readAnalytics) and assigns 
#         Data Contributor role to current user
# Step 2: Temporarily enables public access and adds DataFactory/PowerQueryOnline 
#         service tag IPs to firewall (merges with existing IPs)
# Step 3: Enables Fabric Network ACL Bypass capability and configures workspace 
#         resource ID for bypass
# Step 4: Prompts user to manually create Fabric mirror in portal
# Step 5: Restores original network settings (public access state and IP rules)
#
# WHAT PERSISTS AFTER COMPLETION:
# ✓ RBAC role definitions and assignments (custom + Data Contributor)
# ✓ Network ACL Bypass capability (EnableFabricNetworkAclBypass)
# ✓ Network ACL Bypass resource ID (Fabric workspace)
# ✓ Original public network access state
# ✓ Original IP firewall rules (if any existed)
#
# IDEMPOTENCY:
# ✓ Safe to run multiple times on the same account
# ✓ Skips creating roles/assignments that already exist
# ✓ Merges new IPs with existing ones (no duplicates)
# ✓ Preserves existing Network ACL bypass configurations
# ✓ Restores original network state at completion
#
# REQUIREMENTS:
# - Az PowerShell modules: Az.Accounts, Az.Resources, Az.CosmosDB
# - Interactive sign-in via Connect-AzAccount
# - Subscription Owner or Cosmos DB Account Contributor permissions (will assign it if needed)
# - Fabric Workspace Admin role for the target workspace
# - Access to Microsoft Graph API and Fabric API (https://api.fabric.microsoft.com)
#
# PREREQUISITES:
# - Cosmos DB account must have private endpoints configured
# - Fabric Capacity must be in same region as Cosmos DB account's primary (hub) region
# - User must be admin of target Fabric workspace
#
# USAGE:
# .\ps-account-setup-cosmos-pe-mirroring.ps1
# 
# The script will interactively prompt for:
# - Azure Subscription ID
# - Resource Group name
# - Cosmos DB account name
# - Fabric Capacity Azure region (must match Cosmos DB hub region)
# - Fabric Workspace name
#
# Each step can be optionally skipped for granular control.
#
# NOTES:
# - Step 2 may take up to 15 minutes to propagate IP firewall rules
# - Temporarily enables public access during setup (Step 2-4)
# - Returns network settings to original state in Step 5
# - Service tag IPs are region-specific and automatically downloaded
# - Script captures initial state and preserves user's custom IP rules
#
# ==============================================================================

# Set strict mode for better error handling
$ErrorActionPreference = "Stop"

Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║   Azure Cosmos DB - Configure Mirroring with                   ║
║       Private Endpoints or Virtual Networking                  ║
╚════════════════════════════════════════════════════════════════╝

This script will configure your Cosmos DB account for Fabric Mirroring that are 
configured with private endpoints or virtual networking.

"@ -ForegroundColor Cyan

# ---- Collect all parameters upfront ----
Write-Host "Please provide the following information:" -ForegroundColor Yellow
Write-Host ""

$subscriptionId = Read-Host "Enter the Azure Subscription ID"
$resourceGroup = Read-Host "Enter the Resource Group name"
$accountName = Read-Host "Enter the Cosmos DB account name"
$region = Read-Host "Enter the Azure region of your Fabric Capacity and Cosmos Account (e.g., westus, eastus)"
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
        - Assign both roles to current user for Fabric mirroring access.

Step 2: Temporarily enable public access and configure IP Firewall
        - Download Azure service tags for DataFactory and PowerQueryOnline
        - Filter IPv4 addresses for the specified region
        - Enable public network access if needed (temporarily for setup)
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

# Capture initial public network access state and IP rules
Write-Host "Capturing current Cosmos DB configuration..."
$initialAccount = Get-AzCosmosDBAccount -ResourceGroupName $resourceGroup -Name $accountName
$initialPublicNetworkAccess = $initialAccount.PublicNetworkAccess

# Capture initial IP firewall rules
$initialIpRules = @()
if ($initialAccount.IpRules) {
    foreach ($ipRule in $initialAccount.IpRules) {
        if ($ipRule -is [string]) {
            $initialIpRules += $ipRule
        } elseif ($ipRule.IpAddressOrRange) {
            $initialIpRules += $ipRule.IpAddressOrRange
        }
    }
}

Write-Host "Current Public Network Access: $initialPublicNetworkAccess"
Write-Host "Current IP Firewall Rules: $($initialIpRules.Count) rules"
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
        
        # Merge with existing IP rules to preserve user's custom rules
        Write-Host "Checking for existing IP firewall rules..."
        if ($initialIpRules -and $initialIpRules.Count -gt 0) {
            Write-Host "Found $($initialIpRules.Count) existing IP rules"
        }
        
        # Merge service tag IPs with existing IPs, avoiding duplicates
        $mergedIpRules = @($initialIpRules)
        $addedCount = 0
        foreach ($ip in $ipv4OnlyIPs) {
            if ($mergedIpRules -notcontains $ip) {
                $mergedIpRules += $ip
                $addedCount++
            }
        }
        
        Write-Host "Total IP rules after merge: $($mergedIpRules.Count) ($addedCount new)"
        
        Write-Host "Enabling public network access and configuring IP firewall rules..."
        Write-Host "⏱️  This operation may take a moment..."
        
        # Combine both operations into a single call to avoid conflicts
        Update-AzCosmosDBAccount `
            -ResourceGroupName $resourceGroup `
            -Name $accountName `
            -PublicNetworkAccess "Enabled" `
            -IpRule $mergedIpRules `
            -ErrorAction Stop | Out-Null
        
        Write-Host ""
        Write-Host "✅ Step 2: IP Firewall Configured Successfully" -ForegroundColor Green
        Write-Host "   - Total IP Rules: $($mergedIpRules.Count) ($addedCount added, $($initialIpRules.Count) preserved)" -ForegroundColor Gray
        $completedSteps += "✅ IP Firewall Configuration ($($mergedIpRules.Count) total addresses)"
        
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
3. Configure the connection:
   - Select your Cosmos DB account: https://$accountName.documents.azure.com:443/
   - Authenticate using Organizational Account (your current user)
   - Configure the remaining mirroring settings as needed
4. Complete the setup wizard and start mirroring
5. Wait for the initial synchronization to complete

Once you have successfully created the mirrored database and verified
that data is syncing, return to this script to retore network settings to their original state.

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
    if ($initialPublicNetworkAccess -eq "Enabled") {
        Write-Host "⚠️  WARNING: Public network access remains ENABLED with IP firewall rules" -ForegroundColor Yellow
    } else {
        Write-Host "⚠️  WARNING: Public network access remains ENABLED (was Disabled initially)" -ForegroundColor Yellow
    }
    $completedSteps += "⏭️  Network Settings Restoration (skipped)"
} else {
    try {
        Write-Host "Initial Public Network Access state was: $initialPublicNetworkAccess"
        Write-Host ""
        
        if ($initialPublicNetworkAccess -eq "Enabled") {
            # Public access was enabled initially - restore original IP rules
            Write-Host "Restoring original network settings..." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "🔄 This will:" -ForegroundColor Yellow
            Write-Host "   - Keep public network access ENABLED (original state)" -ForegroundColor Yellow
            Write-Host "   - Restore original IP firewall rules ($($initialIpRules.Count) rules)" -ForegroundColor Yellow
            Write-Host "   - Retain RBAC policies" -ForegroundColor Yellow
            Write-Host "   - Retain Network ACL bypass capability and resource ID" -ForegroundColor Yellow
            Write-Host ""
            
            $confirmRestore = Read-Host "Confirm restoring original network settings? [y/N]"
            if ($confirmRestore.Trim().ToLower() -in @('y','yes')) {
                if ($initialIpRules.Count -gt 0) {
                    # Restore original IP rules
                    Update-AzCosmosDBAccount `
                        -ResourceGroupName $resourceGroup `
                        -Name $accountName `
                        -PublicNetworkAccess "Enabled" `
                        -IpRule $initialIpRules | Out-Null
                    
                    Write-Host ""
                    Write-Host "✅ Step 5: Network Settings Restored (Public access enabled, $($initialIpRules.Count) original IP rules restored)" -ForegroundColor Green
                } else {
                    # No original IP rules, so clear them
                    Update-AzCosmosDBAccount `
                        -ResourceGroupName $resourceGroup `
                        -Name $accountName `
                        -PublicNetworkAccess "Enabled" `
                        -IpRule @() | Out-Null
                    
                    Write-Host ""
                    Write-Host "✅ Step 5: Network Settings Restored (Public access enabled, IP rules cleared)" -ForegroundColor Green
                }
                $completedSteps += "✅ Network Settings Restored to Original State"
            } else {
                Write-Host "⚠️  Network settings not restored" -ForegroundColor Yellow
                $completedSteps += "⏭️  Network Settings Restoration (cancelled)"
            }
        } else {
            # Public access was disabled initially - just disable it again (should already be disabled but confirm)
            Write-Host "Restoring original network settings..." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "🔄 This will:" -ForegroundColor Yellow
            Write-Host "   - Disable public network access (original state)" -ForegroundColor Yellow
            Write-Host "   - Retain RBAC policies" -ForegroundColor Yellow
            Write-Host "   - Retain Network ACL bypass capability and resource ID" -ForegroundColor Yellow
            Write-Host "   - Rely on private endpoints for secure access" -ForegroundColor Yellow
            Write-Host ""
            
            $confirmRestore = Read-Host "Confirm restoring original network settings? [y/N]"
            if ($confirmRestore.Trim().ToLower() -in @('y','yes')) {
                Update-AzCosmosDBAccount `
                    -ResourceGroupName $resourceGroup `
                    -Name $accountName `
                    -PublicNetworkAccess "Disabled" | Out-Null
                
                Write-Host ""
                Write-Host "✅ Step 5: Network Settings Restored (Public access disabled)" -ForegroundColor Green
                $completedSteps += "✅ Network Settings Restored to Original State"
            } else {
                Write-Host "⚠️  Network settings not restored" -ForegroundColor Yellow
                $completedSteps += "⏭️  Network Settings Restoration (cancelled)"
            }
        }
        
    } catch {
        Write-Error "Step 5 failed: $($_.Exception.Message)"
        Write-Warning "Network settings may not have been restored. Please check manually."
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

# Get fresh account state for final summary
Write-Host "Retrieving final account state..." -ForegroundColor Gray
try {
    $finalAccount = Get-AzCosmosDBAccount -ResourceGroupName $resourceGroup -Name $accountName -ErrorAction Stop
    $finalPublicAccess = $finalAccount.PublicNetworkAccess
    $finalIpRulesCount = if ($finalAccount.IpRules) { $finalAccount.IpRules.Count } else { 0 }
} catch {
    $finalPublicAccess = "Unknown"
    $finalIpRulesCount = "Unknown"
}

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
Current Public Access        : $finalPublicAccess
Initial IP Firewall Rules    : $($initialIpRules.Count)
Current IP Firewall Rules    : $finalIpRulesCount

🎉 Your Cosmos DB account is now configured for Fabric Mirroring!
═══════════════════════════════════════════════════════════════

"@
