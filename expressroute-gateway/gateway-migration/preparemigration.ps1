# Need to verify PS module to ensure have the new API for PUT Gateway


# Start preparing
$gatewayUri = Read-Host "Prepare Migration: Please Enter Gateway Resource ID"
$subIdRegex = "subscriptions/"
$resourceGroupRegex = "resourceGroups/"
$vnetRegex = "virtualNetworks/"
$subId = $gatewayUri.Substring($gatewayUri.ToLower().IndexOf($subIdRegex.ToLower()) + $subIdRegex.Length, $gatewayUri.ToLower().IndexOf($resourceGroupRegex.ToLower()) - $gatewayUri.ToLower().IndexOf($subIdRegex.ToLower()) - $subIdRegex.Length -1)
Write-Host "Customer Subscription ID:" $subId
Connect-AzAccount -WarningAction Ignore | Out-Null
Select-AzSubscription -Subscription $subId -Force -WarningAction Ignore | Out-null

Write-Host "Getting existing resources for gateway:" $gatewayUri
$gateway =  Get-AzResource -ResourceId $gatewayUri  -WarningAction Ignore
$resourceGroup = $gateway.ResourceGroupName
$location = $gateway.Location
$pip = Get-AzResource -ResourceId $gateway.Properties.ipConfigurations[0].properties.publicIPAddress.id
$subnet =  Get-AzResource -ResourceId $gateway.Properties.ipConfigurations[0].properties.subnet.id
$vnetName = $subnet.ParentResource.Substring($subnet.ParentResource.ToLower().IndexOf($vnetRegex.ToLower()) + $vnetRegex.Length, $subnet.ParentResource.Length - $subnet.ParentResource.ToLower().IndexOf($vnetRegex.ToLower()) - $vnetRegex.Length)
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $resourceGroup
$subnet = Get-AzVirtualNetworkSubnetConfig -Name GatewaySubnet -VirtualNetwork $vnet

# Verify all resources are in succeeded state
if($gateway.Properties.provisioningState -ne "Succeeded")
{
          Write-Host $gateway.Name " is " $gateway.Properties.provisioningState
          Read-Host "Enter anything to exit, Prepare for migration failed"
          exit
}

$connections = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $resourceGroup | Where-Object -FilterScript {$_.VirtualNetworkGateway1.Id -eq $gatewayUri}
foreach($connection in $connections)
{
        if($connection.ProvisioningState -ne "Succeeded")
        {
          Write-Host $connection.Name " is " $connection.ProvisioningState
          Read-Host "Enter anything to exit, Prepare for migration failed"
          exit
        }
}

Write-Host "---------------- All validation passed, start creating new resources ----------------"

# Getting input from customer and create new resources

$prefix = Read-Host "Please choose the suffix for new resources, new resource name will be existingresourcename_<suffix>"
$pipName = $pip.Name + "_" + $prefix
$ipconfigName = $gateway.Properties.ipConfigurations[0].name + "_" + $prefix
$gatewayName = $gateway.Name + "_" + $prefix
$zone = Read-Host "Please select zones for new gateway"
$gatewaySku = Read-Host "Please choose the sku for new gateway [ErGw1AZ|ErGw2AZ|ErGw3AZ]"

if($pipName.Length -gt 80)
{
    $pipName = $pipName.Substring(0,80)
}

if($ipconfigName.Length -gt 80)
{
    $ipconfigName = $ipconfigName.Substring(0,80)
}

if($gatewayName.Length -gt 80)
{
    $gatewayName = $gatewayName.Substring(0,80)
}

$pipNew = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $resourceGroup -Location $location -AllocationMethod Static -Sku Standard -Zone $zone -Force
$subnetNew = Get-AzVirtualNetworkSubnetConfig -Name GatewaySubnet -VirtualNetwork $vnet
$ipconfNew = New-AzVirtualNetworkGatewayIpConfig -Name $ipconfigName -Subnet $subnetNew -PublicIpAddress $pipNew
$startTime = Get-Date
Write-Host "---------------- Creating new gateway" $gatewayName "Sku" $gatewaySku "----------------" 
New-AzVirtualNetworkGateway -Name $gatewayName -ResourceGroupName $resourceGroup -Location $location -IpConfigurations $ipconfNew -GatewayType Expressroute -GatewaySku $gatewaysku -AdminState Disabled -Force | Out-null
$gatewayNew = get-AzVirtualNetworkGateway -Name $gatewayName -ResourceGroupName $resourceGroup
Set-AzVirtualNetworkGateway -VirtualNetworkGateway $gatewayNew -AllowRemoteVnetTraffic $gateway.AllowRemoteVnetTraffic -AllowVirtualWanTraffic $gateway.AllowVirtualWanTraffic
$gatewayNew = get-AzVirtualNetworkGateway -Name $gatewayName -ResourceGroupName $resourceGroup
if($gatewayNew.ProvisioningState -ne "Succeeded")
{
          Write-Host $gatewayNew.Name " is " $gateway.ProvisioningState
          Read-Host "Enter anything to exit, Prepare for migration failed"
          exit
}

Set-AzVirtualNetworkGateway -VirtualNetworkGateway $gatewayNew -AllowRemoteVnetTraffic $true -AllowVirtualWanTraffic $true

foreach($connection in $connections)
{
        $connName = $connection.Name + "_" + $prefix
        $circuitId = $connection.Peer.Id

        Write-Host "---------------- Creating new connection" $connName "with circuit" $circuitId "----------------"
        New-AzVirtualNetworkGatewayConnection -Name $connName -ResourceGroupName $resourceGroup -Location $location -VirtualNetworkGateway1 $gatewayNew -PeerId $circuitId -ConnectionType ExpressRoute -RoutingWeight $connection.RoutingWeight | Out-null
}

$connectionsNew = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $resourceGroup | Where-Object -FilterScript {$_.VirtualNetworkGateway1.Name -contains $prefix} 
foreach($connection in $connectionsNew)
{
        if($connection.ProvisioningState -ne "Succeeded")
        {
          Write-Host $connection.Name " is " $connection.ProvisioningState
          Read-Host "Enter anything to exit, Prepare for migration failed"
          exit
        }
}

$endTime = Get-Date
$diff =  New-TimeSpan -Start $startTime -End $endTime
# Preparetion completed!
Write-Host "---------------- Prepare for migration for" $gatewayUri "is completed! Taking" $diff.TotalMinutes "minutes ----------------" 
Read-Host "Enter anything to exit"
