#Azure Migrate/ASR - Get Replication Status Script
#requires -Version 7 -module Az.Accounts

param (
    [Parameter(Mandatory=$true)][string]$CsvPath,            # Path to CSV file with vault details.
    [Parameter(Mandatory=$false)][string]$OutputCsvPath = ".\replication_status_output.csv"
)

# Check if user is logged in to Azure, if not prompt to login.
if (Get-AzContext) {
    Write-Host "`n`rAlready logged in to Azure`n"
    Write-Host (Get-AzContext).Subscription.Name
}
else {
    Write-Host "`nNot logged in to Azure. Please login."
    Connect-AzAccount
}

if (-not (Test-Path $CsvPath)) {
    Write-Host "CSV file not found: $CsvPath" -ForegroundColor Red
    return
}

function getreplicationstatus {
    param(
        [Parameter(Mandatory=$true)][string]$CsvPath,
        [string]$OutputCsvPath
    )

    $csvRows = Import-Csv -Path $CsvPath
    Write-Host "Loaded $($csvRows.Count) machine(s) from CSV: $CsvPath" -ForegroundColor Cyan

    # Use first row's vault info (same vault assumed for all rows)
    $firstRow = $csvRows[0]
    $subscriptionId = $firstRow.VAULT_SUBSCRIPTION_ID
    $resourceGroup  = $firstRow.VAULT_RESOURCE_GROUP
    $vaultName      = $firstRow.VAULT_NAME

    # Look up the InMageRcm fabric
    $fabricUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/replicationFabrics?api-version=2025-08-01"
    $fabricRes = Invoke-AzRestMethod -Method GET -Path $fabricUri
    if ($fabricRes.StatusCode -ne 200) {
        Write-Host "Failed to retrieve replication fabrics. Status: $($fabricRes.StatusCode)" -ForegroundColor Red
        return
    }
    $fabrics = ($fabricRes.Content | ConvertFrom-Json).value
    $rcmFabric = $fabrics | Where-Object { $_.properties.customDetails.instanceType -eq "InMageRcm" }
    if (-not $rcmFabric) {
        Write-Host "No InMageRcm fabric found in vault $vaultName" -ForegroundColor Red
        return
    }
    $fabricName = $rcmFabric.name
    Write-Host "Resolved InMageRcm fabric: $fabricName" -ForegroundColor Green

    # List replication protection containers under the fabric and pick the first one
    $containerUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/replicationFabrics/$fabricName/replicationProtectionContainers?api-version=2025-08-01"
    $containerRes = Invoke-AzRestMethod -Method GET -Path $containerUri
    if ($containerRes.StatusCode -ne 200) {
        Write-Host "Failed to retrieve replication protection containers. Status: $($containerRes.StatusCode)" -ForegroundColor Red
        return
    }
    $containers = ($containerRes.Content | ConvertFrom-Json).value
    if (-not $containers -or $containers.Count -eq 0) {
        Write-Host "No replication protection containers found under fabric $fabricName" -ForegroundColor Red
        return
    }
    $containerName = $containers[0].name
    Write-Host "Resolved replication protection container: $containerName" -ForegroundColor Green

    # List all replication protected items
    $itemsUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/replicationFabrics/$fabricName/replicationProtectionContainers/$containerName/replicationProtectedItems?api-version=2025-08-01"

    Write-Host "`nFetching replication protected items..." -ForegroundColor Cyan

    $itemsRes = Invoke-AzRestMethod -Method GET -Path $itemsUri
    if ($itemsRes.StatusCode -ne 200) {
        Write-Host "Failed to retrieve replication protected items. Status: $($itemsRes.StatusCode)" -ForegroundColor Red
        Write-Host "Response: $($itemsRes.Content)" -ForegroundColor Red
        return
    }

    $items = ($itemsRes.Content | ConvertFrom-Json).value
    if (-not $items -or $items.Count -eq 0) {
        Write-Host "No replication protected items found." -ForegroundColor Yellow
        return
    }

    Write-Host "Found $($items.Count) protected item(s).`n" -ForegroundColor Green

    $results = @()
    foreach ($item in $items) {
        $props = $item.properties
        $providerDetails = $props.providerSpecificDetails

        $results += [PSCustomObject]@{
            "Machine Name"           = $props.friendlyName
            "Protection State"       = $props.protectionState
            "Replication Health"     = $props.replicationHealth
            "Failover Health"        = $props.failoverHealth
            "Test Failover State"    = $props.testFailoverState
            "Active Location"        = $props.activeLocation
            "Target VM Name"         = $providerDetails.targetVmName
            "Last RpoCalculatedTime" = $providerDetails.lastRpoCalculatedTime
            "RPO (seconds)"          = $providerDetails.rpoInSeconds
            "Agent Version"          = $providerDetails.agentUpgradeState
        }
    }

    # Display results in console
    $results | Format-Table -AutoSize

    # Export to CSV
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Output CSV written to: $OutputCsvPath" -ForegroundColor Cyan
}

# Run get replication status
getreplicationstatus -CsvPath $CsvPath -OutputCsvPath $OutputCsvPath
