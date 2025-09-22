# Reference: Az.CosmosDB | https://learn.microsoft.com/powershell/module/az.cosmosdb
# --------------------------------------------------
# Purpose
# Update autoscale maximum throughput for an Azure Cosmos DB NoSQL container.
# This sets the AutoscaleMaxThroughput (the maximum RU/s the container can scale up to).
# --------------------------------------------------
# Variables - prompt for values
$resourceGroupName = Read-Host "Enter the Resource Group name"
$accountName = Read-Host "Enter the Cosmos DB account name (must be all lower case)"
$accountName = $accountName.ToLower()
$databaseName = Read-Host "Enter the database name"
$containerName = Read-Host "Enter the container name"
# Set the autoscale maximum RU/s you want the container to scale up to.
# Autoscale minimum RU/s will be approximately 10% of this value.
$newAutoscaleMaxInput = Read-Host "Enter the desired Autoscale max RU/s (e.g. 50000)"
try { $newAutoscaleMax = [int]$newAutoscaleMaxInput } catch { throw "Invalid number provided for autoscale max throughput: '$newAutoscaleMaxInput'" }
# --------------------------------------------------

Write-Host "Fetching current throughput settings for container '$containerName' in database '$databaseName'..."
$throughput = Get-AzCosmosDBSqlContainerThroughput -ResourceGroupName $resourceGroupName `
    -AccountName $accountName -DatabaseName $databaseName -Name $containerName

if (-not $throughput) {
    Write-Error "Unable to retrieve throughput settings. Verify the resource group, account, database and container names."
    return
}

# Try to detect current autoscale maximum throughput if present
$detectedAutoscaleMax = $null
if ($throughput.PSObject.Properties['AutoscaleSettings']) {
    $as = $throughput.PSObject.Properties['AutoscaleSettings'].Value
    if ($as -and $as.MaxThroughput) { $detectedAutoscaleMax = [int]$as.MaxThroughput }
}

if (-not $detectedAutoscaleMax -and $throughput.PSObject.Properties['AutoscaleMaxThroughput']) {
    $detectedAutoscaleMax = [int]$throughput.AutoscaleMaxThroughput
}

# Some cmdlet versions expose 'MaxThroughput' or 'Throughput' fields
if (-not $detectedAutoscaleMax -and $throughput.PSObject.Properties['MaxThroughput']) {
    $detectedAutoscaleMax = [int]$throughput.MaxThroughput
}

$currentManualThroughput = $null
if ($throughput.PSObject.Properties['Throughput']) { $currentManualThroughput = [int]$throughput.Throughput }

Write-Host "Current throughput settings (raw):"
$throughput | Format-List

if ($detectedAutoscaleMax) {
    Write-Host "Container is currently configured for autoscale with AutoscaleMaxThroughput = $detectedAutoscaleMax." -ForegroundColor Cyan
}
elseif ($currentManualThroughput) {
    Write-Host "Container is currently configured with manual throughput = $currentManualThroughput RU/s." -ForegroundColor Yellow
}
else {
    Write-Host "Current throughput mode is unknown from returned properties. Proceeding to update to autoscale." -ForegroundColor Yellow
}

# Inform about autoscale minimum (approx 10% of max)
$calculatedMinimum = [math]::Floor($newAutoscaleMax / 10)
Write-Host "Requested AutoscaleMaxThroughput = $newAutoscaleMax. This will result in an approximate minimum of $calculatedMinimum RU/s (10% of max)."

if ($detectedAutoscaleMax -eq $newAutoscaleMax) {
    Write-Host "Requested autoscale max is the same as current autoscale max. No update required." -ForegroundColor Green
}
else {
    Write-Host "Updating container to use autoscale maximum throughput of $newAutoscaleMax RU/s..." -ForegroundColor Green

    Update-AzCosmosDBSqlContainerThroughput -ResourceGroupName $resourceGroupName `
        -AccountName $accountName -DatabaseName $databaseName `
        -Name $containerName -AutoscaleMaxThroughput $newAutoscaleMax

    Write-Host "Update request submitted. Re-fetching throughput settings..."
    $updated = Get-AzCosmosDBSqlContainerThroughput -ResourceGroupName $resourceGroupName `
        -AccountName $accountName -DatabaseName $databaseName -Name $containerName

    Write-Host "Updated throughput settings (raw):"
    $updated | Format-List

    # Try to surface the new autoscale max after update
    $newDetected = $null
    if ($updated.PSObject.Properties['AutoscaleSettings']) {
        $uas = $updated.PSObject.Properties['AutoscaleSettings'].Value
        if ($uas -and $uas.MaxThroughput) { $newDetected = [int]$uas.MaxThroughput }
    }
    if (-not $newDetected -and $updated.PSObject.Properties['AutoscaleMaxThroughput']) { $newDetected = [int]$updated.AutoscaleMaxThroughput }
    if ($newDetected) {
        Write-Host "Container now configured for autoscale with AutoscaleMaxThroughput = $newDetected." -ForegroundColor Green
    }
    else {
        Write-Host "Unable to detect AutoscaleMaxThroughput from updated settings. Inspect the returned properties above." -ForegroundColor Yellow
    }
}
