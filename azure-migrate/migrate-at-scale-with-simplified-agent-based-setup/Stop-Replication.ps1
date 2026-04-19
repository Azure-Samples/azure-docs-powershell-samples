#Azure Migrate/ASR - Disable Replication Script
#requires -Version 7 -module Az.RecoveryServices, Az.Accounts

param (
    [Parameter(Mandatory=$true)][string]$CsvPath             # Path to CSV file for batch disable replication.
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

function disablereplication {
    param(
        [Parameter(Mandatory=$true)][string]$CsvPath
    )
    # Disable replication for machines listed in a CSV file.
    $csvRows = Import-Csv -Path $CsvPath
    Write-Host "Loaded $($csvRows.Count) machine(s) from CSV: $CsvPath" -ForegroundColor Cyan

    # Look up the InMageRcm fabric name (same vault assumed for all rows; uses first row's vault info)
    $firstRow = $csvRows[0]
    $fabricUri = "/subscriptions/$($firstRow.VAULT_SUBSCRIPTION_ID)/resourceGroups/$($firstRow.VAULT_RESOURCE_GROUP)/providers/Microsoft.RecoveryServices/vaults/$($firstRow.VAULT_NAME)/replicationFabrics?api-version=2025-08-01"
    $fabricRes = Invoke-AzRestMethod -Method GET -Path $fabricUri
    if ($fabricRes.StatusCode -ne 200) {
        Write-Host "Failed to retrieve replication fabrics. Status: $($fabricRes.StatusCode)" -ForegroundColor Red
        return
    }
    $fabrics = ($fabricRes.Content | ConvertFrom-Json).value
    $rcmFabric = $fabrics | Where-Object { $_.properties.customDetails.instanceType -eq "InMageRcm" }
    if (-not $rcmFabric) {
        Write-Host "No InMageRcm fabric found in vault $($firstRow.VAULT_NAME)" -ForegroundColor Red
        return
    }
    $fabricName = $rcmFabric.name
    Write-Host "Resolved InMageRcm fabric: $fabricName" -ForegroundColor Green

    # List replication protection containers under the fabric and pick the first one
    $containerUri = "/subscriptions/$($firstRow.VAULT_SUBSCRIPTION_ID)/resourceGroups/$($firstRow.VAULT_RESOURCE_GROUP)/providers/Microsoft.RecoveryServices/vaults/$($firstRow.VAULT_NAME)/replicationFabrics/$fabricName/replicationProtectionContainers?api-version=2025-08-01"
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

    foreach ($row in $csvRows) {
        $machineName = $row.SOURCE_MACHINE_ARM_ID.Split('/')[-1]

        if ($row.PERFORM_DISABLE -ne "yes") {
            Write-Host "`n--- Skipping machine (PERFORM_DISABLE != yes): $machineName ---" -ForegroundColor DarkGray
            continue
        }

        Write-Host "`n--- Disabling replication for machine: $($row.SOURCE_MACHINE_ARM_ID) ---" -ForegroundColor Yellow

        $uri = "/Subscriptions/$($row.VAULT_SUBSCRIPTION_ID)/resourceGroups/$($row.VAULT_RESOURCE_GROUP)/"
        $uri = $uri + "providers/Microsoft.RecoveryServices/vaults/$($row.VAULT_NAME)/replicationFabrics/$fabricName/replicationProtectionContainers/$containerName/replicationProtectedItems/$machineName/"
        $uri = $uri + "remove?api-version=2025-08-01"
        Write-Host "Disable Replication URI: $uri"

        $payload = @{
            properties = @{
                disableProtectionReason = "NotSpecified"
                replicationProviderInput = @{
                    instanceType            = "InMageRcm"
                    replicaVmDeletionStatus = "Retain"
                }
            }
        }
        $body = $payload | ConvertTo-Json -Depth 10
        Write-Host "Disable Replication Payload:`n$body"

        $res = Invoke-AzRestMethod -Method POST -Path $uri -Payload $body
        Write-Host "Disable Replication initiated for $($row.TARGET_MACHINE_NAME). Status code: $($res.StatusCode)." -ForegroundColor Green
        $res

        if ($res.StatusCode -in 200, 201, 202) {
            $row | Add-Member -NotePropertyName "ASR_PROTECTION_STATUS" -NotePropertyValue "disable started" -Force
        }
        else {
            $row | Add-Member -NotePropertyName "ASR_PROTECTION_STATUS" -NotePropertyValue "disable failed" -Force
            Write-Host "Disable Replication failed for $($row.TARGET_MACHINE_NAME). Response:`n$($res.Content)" -ForegroundColor Red
        }
    }

    $csvRows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nOutput CSV written to: $CsvPath" -ForegroundColor Cyan
}

# Run disable replication
disablereplication -CsvPath $CsvPath
