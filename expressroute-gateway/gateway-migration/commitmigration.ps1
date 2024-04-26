# Start preparing
$gatewayUri = Read-Host "Commit Migration: Please Enter Gateway Resource ID"
$subIdRegex = "subscriptions/"
$resourceGroupRegex = "resourceGroups/"
$vnetRegex = "virtualNetworks/"
$gatewayRegex = "virtualNetworkGateways/"
$ipconfigRegex = "ipConfigurations/"
$subId = $gatewayUri.Substring($gatewayUri.ToLower().IndexOf($subIdRegex.ToLower()) + $subIdRegex.Length, $gatewayUri.ToLower().IndexOf($resourceGroupRegex.ToLower()) - $gatewayUri.ToLower().IndexOf($subIdRegex.ToLower()) - $subIdRegex.Length -1)
Write-Host "Customer Subscription ID:" $subId
Connect-AzAccount -WarningAction Ignore | Out-Null
Select-AzSubscription -Subscription $subId -Force  | Out-null
$gateway =  Get-AzResource -ResourceId $gatewayUri 
$resourceGroup = $gateway.ResourceGroupName
$subnet =  Get-AzResource -ResourceId $gateway.Properties.ipConfigurations[0].properties.subnet.id
$vnetName = $subnet.ParentResource.Substring($subnet.ParentResource.ToLower().IndexOf($vnetRegex.ToLower()) + $vnetRegex.Length, $subnet.ParentResource.Length - $subnet.ParentResource.ToLower().IndexOf($vnetRegex.ToLower()) - $vnetRegex.Length)
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $resourceGroup
$subnet = Get-AzVirtualNetworkSubnetConfig -Name GatewaySubnet -VirtualNetwork $vnet
$gatewayToDelete = ""
foreach($ipconfig in $subnet.IpConfigurations)
{
    $gatewayName = $ipconfig.Id.substring($ipconfig.Id.ToLower().IndexOf($gatewayRegex.ToLower()) + $gatewayRegex.Length, $ipconfig.Id.ToLower().IndexOf($ipconfigRegex.ToLower()) - $ipconfig.Id.ToLower().IndexOf($gatewayRegex.ToLower()) - $gatewayRegex.Length-1)
    $tempGwt = get-AzVirtualNetworkGateway -Name $gatewayName -ResourceGroupName $gateway.ResourceGroupName
    if($tempGwt.AdminState.tolower().Contains("disable"))
    {
        $gatewayToDelete = $tempGwt.Id
    }
}

Write-Host "---------------- Found disabled gateway" $gatewayToDelete "----------------"
$confirm = Read-Host "Please enter Y to confirm this is the gateway to be deleted" $gatewayToDelete
$confirm
if($confirm.ToLower() -ne "y")
{
    Read-Host "Enter anything to exit, Commit for migration is cancelled"
    exit
}

# Getting input from customer and delete resources
$startTime = Get-Date
$connections = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $gateway.ResourceGroupName | Where-Object -FilterScript {$_.VirtualNetworkGateway1.Id -eq $gatewayToDelete}
foreach($connection in $connections)
{
        if($connection.ProvisioningState -ne "Succeeded")
        {
          Write-Host $connection.Name " is " $connection.ProvisioningState
          Read-Host "Enter anything to exit, Prepare for migration failed"
          exit
        }
}

foreach($connection in $connections)
{
        Write-Host "---------------- Removing connection" $connection.Name "----------------"
        Remove-AzVirtualNetworkGatewayConnection -Name $connection.Name -ResourceGroupName $connection.ResourceGroupName -Force
}

$gateway = Get-AzResource -ResourceId $gatewayToDelete
Write-Host "---------------- Removing gateway" $gateway.Name "----------------"
Remove-AzVirtualNetworkGateway -Name $gateway.Name -ResourceGroupName $gateway.ResourceGroupName -Force

# Commit completed!
$endTime = Get-Date
$diff =  New-TimeSpan -Start $startTime -End $endTime
Write-Host "---------------- Commit for migration for" $gatewayToDelete "is completed! Taking" $diff.TotalMinutes "minutes----------------"
Read-Host "Enter anything to exit"
