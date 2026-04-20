#Azure Migrate/ASR - Enable Replication Script
#requires -Version 7 -module Az.Accounts

param (
    [Parameter(Mandatory=$true)][string]$CsvPath             # Path to CSV file for batch enable replication.
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

function enablereplication {
    param(
        [Parameter(Mandatory=$true)][string]$CsvPath
    )
    # Enable replication for machines listed in a CSV file.
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
        $machine_fixedname =  $row.TARGET_MACHINE_NAME
        $diskType          = if ($row.TARGET_DISK_TYPE) { $row.TARGET_DISK_TYPE } else { "Standard_LRS" }
        $licenseType       = if ($row.LICENSETYPE) { $row.LICENSETYPE } else { "NotSpecified" }
        $testNetworkId     = if ($row.TESTFAILOVER_VNET_ARM_ID) { $row.TESTFAILOVER_VNET_ARM_ID } else { $row.TARGET_VNET_ARM_ID }
        $testSubnetName    = if ($row.TESTFAILOVER_VNET_SUBNET_NAME) { $row.TESTFAILOVER_VNET_SUBNET_NAME } else { $row.TARGET_SUBNET }
        $targetVmSize      = if ($row.TARGET_MACHINE_SIZE) { $row.TARGET_MACHINE_SIZE } else { $null }
        $machineName       = $row.SOURCE_MACHINE_ARM_ID.Split('/')[-1]

        Write-Host "`n--- Enabling replication for machine: $($row.SOURCE_MACHINE_ARM_ID) ---" -ForegroundColor Yellow

        $uri = "/Subscriptions/$($row.VAULT_SUBSCRIPTION_ID)/resourceGroups/$($row.VAULT_RESOURCE_GROUP)/"
        $uri = $uri + "providers/Microsoft.RecoveryServices/vaults/$($row.VAULT_NAME)/replicationFabrics/$fabricName/replicationProtectionContainers/$containerName/replicationProtectedItems/"
        $uri = $uri + "$machineName`?api-version=2025-08-01"
        Write-Host "Enable Replication URI: $uri"

        $payload = @{
            properties = @{
                policyId          = "/subscriptions/$($row.VAULT_SUBSCRIPTION_ID)/resourceGroups/$($row.VAULT_RESOURCE_GROUP)/providers/Microsoft.RecoveryServices/vaults/$($row.VAULT_NAME)/replicationPolicies/24-hour-replication-policy"
                protectableItemId = "$($row.SOURCE_MACHINE_ARM_ID)"
                providerSpecificDetails = @{
                    instanceType                          = "InMageRcm"
                    fabricDiscoveryMachineId               = "$($row.SOURCE_MACHINE_ARM_ID)"
                    targetResourceGroupId                 = "/subscriptions/$($row.TARGET_SUBSCRIPTION_ID)/resourceGroups/$($row.TARGET_RESOURCE_GROUP)"
                    targetNetworkId                       = "$($row.TARGET_VNET_ARM_ID)"
                    targetSubnetName                      = "$($row.TARGET_SUBNET)"
                    testNetworkId                         = "$testNetworkId"
                    testSubnetName                        = "$testSubnetName"
                    targetVmName                          = "$machine_fixedname"
                    targetVmSize                          = $targetVmSize
                    licenseType                           = "$licenseType"
                    targetAvailabilitySetId               = if ($row.TARGET_AVAILABILITY_SET) { $row.TARGET_AVAILABILITY_SET } else { $null }
                    storageAccountId                      = $null
                    targetBootDiagnosticsStorageAccountId  = "$($row.TARGET_BOOT_DIAG_STORAGE_ACCOUNT_ARM_ID)"
                    processServerId                       = "$($row.PROCESS_SERVER)"
                    runAsAccountId                        = "$($row.RUN_AS_ACCOUNT_ID)"
                    multiVmGroupName                      = $null
                    disksToInclude                        = $null
                    disksDefault = @{
                        diskType            = "$diskType"
                        logStorageAccountId = "$($row.TARGET_LOGSTORAGE_ACCOUNT_ARM_ID)"
                    }
                }
            }
        }
        $body = $payload | ConvertTo-Json -Depth 10
        Write-Host "Enable Replication Payload:`n$body"

        $res = Invoke-AzRestMethod -Method PUT -Path $uri -Payload $body
        Write-Host "Enable Replication initiated for $($row.TARGET_MACHINE_NAME). Status code: $($res.StatusCode)." -ForegroundColor Green
        $res

        if ($res.StatusCode -in 200, 201, 202) {
            $row | Add-Member -NotePropertyName "ASR_PROTECTION_STATUS" -NotePropertyValue "enable started" -Force
        }
        else {
            $row | Add-Member -NotePropertyName "ASR_PROTECTION_STATUS" -NotePropertyValue "enable failed" -Force
            Write-Host "Enable Replication failed for $($row.TARGET_MACHINE_NAME). Response:`n$($res.Content)" -ForegroundColor Red
        }
    }

    $csvRows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nOutput CSV written to: $CsvPath" -ForegroundColor Cyan
}

# Run enable replication
enablereplication -CsvPath $CsvPath