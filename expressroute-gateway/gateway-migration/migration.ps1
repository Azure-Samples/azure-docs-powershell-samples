# Need to verify PS module to ensure have the new API for PUT Gateway


# Start preparing
$gatewayUriDisabled = Read-Host "Migrate from Gateway Resource ID"
$gatewayUriEnabled = Read-Host "Migrate to Gateway Resource ID"
$subIdRegex = "subscriptions/"
$resourceGroupRegex = "resourceGroups/"
$vnetRegex = "virtualNetworks/"
$subId = $gatewayUriDisabled.Substring($gatewayUriDisabled.ToLower().IndexOf($subIdRegex.ToLower()) + $subIdRegex.Length, $gatewayUriDisabled.ToLower().IndexOf($resourceGroupRegex.ToLower()) - $gatewayUriDisabled.ToLower().IndexOf($subIdRegex.ToLower()) - $subIdRegex.Length -1)
Write-Host "Customer Subscription ID:" $subId
Connect-AzAccount -WarningAction Ignore | Out-Null
Select-AzSubscription -Subscription $subId -Force  | Out-null
$gatewayDisabled = Get-AzResource -ResourceId $gatewayUriDisabled
$gatewayEnabled =  Get-AzResource -ResourceId $gatewayUriEnabled
$gwtDisabled = Get-AzVirtualNetworkGateway -Name $gatewayDisabled.Name -ResourceGroupName $gatewayDisabled.ResourceGroupName
$gwtEnabled = Get-AzVirtualNetworkGateway -Name $gatewayEnabled.Name -ResourceGroupName $gatewayEnabled.ResourceGroupName
$resourceGroup = $gatewayDisabled.ResourceGroupName
# Validate all connections and gateways
if($gwtEnabled.provisioningState -ne "Succeeded")
{
          Write-Host $gwtEnabled.Name " is " $gwtEnabled.provisioningState
          Read-Host "Enter anything to exit, Migration failed"
          exit
}

$connections = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $resourceGroup | Where-Object -FilterScript {$_.VirtualNetworkGateway1.Id -eq $gatewayUriEnabled}
foreach($connection in $connections)
{
        if($connection.ProvisioningState -ne "Succeeded")
        {
          Write-Host $connection.Name " is " $connection.ProvisioningState
          Read-Host "Enter anything to exit, Prepare for migration failed"
          exit
        }
}

if($gwtDisabled.provisioningState -ne "Succeeded")
{
          Write-Host $gwtDisabled.Name " is " $gwtDisabled.provisioningState
          Read-Host "Enter anything to exit, Migration failed"
          exit
}

$connections = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $resourceGroup | Where-Object -FilterScript {$_.VirtualNetworkGateway1.Id -eq $gatewayUriDisabled}
foreach($connection in $connections)
{
        if($connection.ProvisioningState -ne "Succeeded")
        {
          Write-Host $connection.Name " is " $connection.ProvisioningState
          Read-Host "Enter anything to exit, Prepare for migration failed"
          exit
        }
}

# Migrating traffic 
$startTime = Get-Date

Write-Host "---------------- Enabling gateway" $gwtEnabled.Name "----------------"
$gwt1 = Set-AzVirtualNetworkGateway -VirtualNetworkGateway $gwtEnabled -AdminState Enabled

if($gwt1.ProvisioningState -ne "Succeeded")
{
          Write-Host "Not able to enable" $gwt1.Name
          Read-Host "Enter anything to exit, Migration failed"
          exit
}

Write-Host "---------------- Disabling gateway" $gwtDisabled.Name "----------------"
$gwt2 = Set-AzVirtualNetworkGateway -VirtualNetworkGateway $gwtDisabled -AdminState Disabled

if($gwt2.ProvisioningState -ne "Succeeded")
{
          Write-Host "Not able to disable" $gwt2.Name
          Read-Host "Enter anything to exit, Migration failed"
          exit
}
$endTime = Get-Date
$diff =  New-TimeSpan -Start $startTime -End $endTime
# Migration completed!
Write-Host "---------------- Migration from" $gatewayUriDisabled "to" $gatewayUriEnabled "is completed! Taking" $diff.TotalMinutes "minutes----------------"
Read-Host "Enter anything to exit"