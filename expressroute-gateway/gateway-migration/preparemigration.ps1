# Need to verify PS module to ensure have the new API for PUT Gateway
# Start preparing
$gatewayUri = Read-Host "Prepare Migration: Please Enter Gateway Resource ID"
$gatewayUri = $gatewayUri.Trim()

if (-not $gatewayUri) {
    Write-Error "Gateway Resource ID can not be null."
    exit
}

$subIdRegex = "subscriptions/"
$resourceGroupRegex = "resourceGroups/"
$vnetRegex = "virtualNetworks/"
$subId = $gatewayUri.Substring($gatewayUri.ToLower().IndexOf($subIdRegex.ToLower()) + $subIdRegex.Length, $gatewayUri.ToLower().IndexOf($resourceGroupRegex.ToLower()) - $gatewayUri.ToLower().IndexOf($subIdRegex.ToLower()) - $subIdRegex.Length -1)
Write-Host "Customer Subscription ID:" $subId
Connect-AzAccount -WarningAction Ignore | Out-Null
Select-AzSubscription -Subscription $subId -Force -WarningAction Ignore | Out-null
Write-Host "Getting existing resources for gateway:" $gatewayUri
$gateway = Get-AzResource -ResourceId $gatewayUri -WarningAction Ignore

if (-not $gateway) {
    Write-Error "The Gateway introduced is not valid."
    exit
}

$resourceGroup = $gateway.ResourceGroupName
$location = $gateway.Location
$subnet = Get-AzResource -ResourceId $gateway.Properties.ipConfigurations[0].properties.subnet.id
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

# Fetch connections referencing this gateway across the subscription via Azure Resource Graph
# Note: Requires Az.ResourceGraph module
$argQuery = @"
Resources
| where type =~ 'microsoft.network/connections'
| where properties.virtualNetworkGateway1.id =~ '$gatewayUri'
| project name, resourceGroup
"@

$argResults = Search-AzGraph -Query $argQuery -Subscription $subId -WarningAction Ignore

# Resolve full connection objects by name and resource group
$connections = @()
foreach ($result in $argResults) {
    try {
        $conn = Get-AzVirtualNetworkGatewayConnection -Name $result.name -ResourceGroupName $result.resourceGroup -WarningAction Ignore
        if ($null -ne $conn) { $connections += $conn }
    } catch {
        Write-Verbose "Failed to resolve connection $($result.name) in RG $($result.resourceGroup): $($_.Exception.Message)"
    }
}

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
$ipconfigName = $gateway.Properties.ipConfigurations[0].name + "_" + $prefix
$gatewayName = $gateway.Name + "_" + $prefix
$validSkus = @("ErGw1AZ", "ErGw2AZ", "ErGw3AZ", "Standard", "HighPerformance", "UltraPerformance", "ErGwScale")

$gatewaySku = Read-Host "Please choose the sku for new gateway [ErGw1AZ|ErGw2AZ|ErGw3AZ|ErGwScale], if region do not have zones [Standard|HighPerformance|UltraPerformance]"

if ($validSkus -notcontains $gatewaySku) {
    Write-Host "Invalid SKU. Valid values are: ErGw1AZ, ErGw2AZ, ErGw3AZ, ErGwScale, Standard, HighPerformance, UltraPerformance"
    Read-Host "Enter anything to exit, Prepare for migration failed"
    exit
}

if($ipconfigName.Length -gt 80)
{
    $ipconfigName = $ipconfigName.Substring(0,80)
}
if($gatewayName.Length -gt 80)
{
    $gatewayName = $gatewayName.Substring(0,80)
}
$subnetNew = Get-AzVirtualNetworkSubnetConfig -Name GatewaySubnet -VirtualNetwork $vnet

$pipCreate = Read-Host "Please enter Y if you wish to create a Public IP for the new gateway"
if($pipCreate.ToLower() -ne "y")
{
    $ipconfNew = New-AzVirtualNetworkGatewayIpConfig -Name $ipconfigName -Subnet $subnetNew
} else {
    if(-not $gateway.Properties.ipConfigurations[0].properties.PublicIpAddress){
        $pipName = $gateway.Name + "-pip_" + $prefix
    } else {
        $pip = Get-AzResource -ResourceId $gateway.Properties.ipConfigurations[0].properties.PublicIpAddress.Id
        $pipName = $pip.Name + "_" + $prefix
    }
    if($pipName.Length -gt 80)
    {
        $pipName = $pipName.Substring(0,80)
    }
    $zone = Read-Host "Please enter zones for the Public IP, if region does not have zones, please enter null"
    if($zone -eq "null")
    {
        Write-Host "Region do not support zones"
        $zone = $null
    } else {
        $zone = $zone.Split(",")
    }
    $pipNew = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $resourceGroup -Location $location -AllocationMethod Static -Sku Standard -Zone $zone -Force
    $ipconfNew = New-AzVirtualNetworkGatewayIpConfig -Name $ipconfigName -Subnet $subnetNew -PublicIpAddress $pipNew
}
$startTime = Get-Date

$existingGatewayName = $gateway.Name
$gatewayExisting = get-AzVirtualNetworkGateway -Name $existingGatewayName -ResourceGroupName $resourceGroup

# If "ErGwScale" SKU is selected, ask for scale units
if ($gatewaySku -eq "ErGwScale") {
    $minScaleUnit = [int](Read-Host "Please enter the minimum scale unit for the gateway")
    $maxScaleUnit = [int](Read-Host "Please enter the maximum scale unit for the gateway")

    if ($minScaleUnit -lt 1 -or $maxScaleUnit -gt 40) {
        Write-Host "Valid range for scale units is 1 to 40"
        exit
    }
    if ($minScaleUnit -gt $maxScaleUnit) {
        Write-Host "Error: Minimum scale unit must be less than or equal to the maximum scale unit."
        exit
    }
}

$ipConfigProps = @{
    subnet = @{ id = $ipconfNew.Subnet.Id } 
    privateIPAllocationMethod = 'Dynamic'
}
if ($null -ne $ipconfNew.PublicIpAddress) {
    $ipConfigProps.publicIpAddress = @{ id = $ipconfNew.PublicIpAddress.Id }
}

$resourceProps = @{
    gatewayType = 'ExpressRoute'
    ipConfigurations = @(@{
        name = $ipconfNew.Name
        properties = $ipConfigProps
    })
    sku = @{ name = "$gatewaySku"; tier = "$gatewaySku" }
    adminState = 'Disabled'
    allowRemoteVnetTraffic = $gatewayExisting.AllowRemoteVnetTraffic
    allowVirtualWanTraffic = $gatewayExisting.AllowVirtualWanTraffic
}

if ($gatewaySku -eq "ErGwScale") {
    $resourceProps.autoscaleConfiguration = @{ bounds = @{ min = $minScaleUnit; max = $maxScaleUnit } }
}

$template = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    resources = @(@{
        type = 'Microsoft.Network/virtualNetworkGateways'
        apiVersion = '2024-07-01'
        name = $gatewayName
        location = $location
        properties = $resourceProps
    })
}

Write-Host "---------------- Creating new gateway $gatewayName with $gatewaySku SKU ----------------"
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroup -TemplateObject $template -Force | Out-Null

$gatewayNew = get-AzVirtualNetworkGateway -Name $gatewayName -ResourceGroupName $resourceGroup
if($gatewayNew.ProvisioningState -ne "Succeeded")
{
    Write-Host $gatewayNew.Name " is " $gatewayNew.ProvisioningState
    Read-Host "Enter anything to exit, Prepare for migration failed"
    exit
}

Write-Host "---------------- Attempting to update existing gateway $existingGatewayName if it has legacy connections. ----------------"
Set-AzVirtualNetworkGateway -VirtualNetworkGateway $gatewayExisting
if($gatewayExisting.ProvisioningState -ne "Succeeded")
{
    Write-Host $gatewayExisting.Name " is " $gatewayExisting.ProvisioningState
    Read-Host "Enter anything to exit, Prepare for migration failed while converting existing gateway to new encapsulation type"
    exit
}
else {
     Write-Host $existingGatewayName " is " $gatewayExisting.ProvisioningState
     Write-Host "---------------- Update of old gateway is successful! ----------------"
}

foreach($connection in $connections)
{
    $connName = $connection.Name + "_" + $prefix
    $circuitId = $connection.Peer.Id
    $isAuth = $true;
    $isFP = $true;
    $isFPPE = $true;
    if($connection.AuthorizationKey -eq $null -or $connection.AuthorizationKey -eq "")
    {
        $isAuth = $false
    }
    
    if($connection.ExpressRouteGatewayBypass -eq $null)
    {
        $isFP = $false
    }
    else
    {
        $isFP = $connection.ExpressRouteGatewayBypass
    }

    if($connection.EnablePrivateLinkFastPath -eq $null)
    {
        $isFPPE = $false
    }
    else
    {
        $isFPPE = $connection.EnablePrivateLinkFastPath
    }
    Write-Host Existing connection properties: ExpressRouteGatewayBypass: $connection.ExpressRouteGatewayBypass, EnablePrivateLinkFastPath: $connection.EnablePrivateLinkFastPath, Route Weight: $connection.RoutingWeight, AuthorizationKey: $connection.AuthorizationKey
    Write-Host Copying properties: ExpressRouteGatewayBypass: $isFP, EnablePrivateLinkFastPath: $isFPPE, Route Weight: $connection.RoutingWeight, AuthorizationKey: $isAuth

    if($isAuth)
    {
        if($isFP -and $isFPPE)
        {
            New-AzVirtualNetworkGatewayConnection -Name $connName -ResourceGroupName $resourceGroup -Location $location -VirtualNetworkGateway1 $gatewayNew -PeerId $circuitId -ConnectionType ExpressRoute -RoutingWeight $connection.RoutingWeight -ExpressRouteGatewayBypass -EnablePrivateLinkFastPath -AuthorizationKey "*****************" | Out-null
        }
        elseif($isFP)
        {
            New-AzVirtualNetworkGatewayConnection -Name $connName -ResourceGroupName $resourceGroup -Location $location -VirtualNetworkGateway1 $gatewayNew -PeerId $circuitId -ConnectionType ExpressRoute -RoutingWeight $connection.RoutingWeight -ExpressRouteGatewayBypass -AuthorizationKey "*****************" | Out-null
        }
        else
        {
            New-AzVirtualNetworkGatewayConnection -Name $connName -ResourceGroupName $resourceGroup -Location $location -VirtualNetworkGateway1 $gatewayNew -PeerId $circuitId -ConnectionType ExpressRoute -RoutingWeight $connection.RoutingWeight -AuthorizationKey "*****************" | Out-null
        }
    }
    else {
       if($isFP -and $isFPPE)
        {
            New-AzVirtualNetworkGatewayConnection -Name $connName -ResourceGroupName $resourceGroup -Location $location -VirtualNetworkGateway1 $gatewayNew -PeerId $circuitId -ConnectionType ExpressRoute -RoutingWeight $connection.RoutingWeight -ExpressRouteGatewayBypass -EnablePrivateLinkFastPath | Out-null
        }
        elseif($isFP)
        {
            New-AzVirtualNetworkGatewayConnection -Name $connName -ResourceGroupName $resourceGroup -Location $location -VirtualNetworkGateway1 $gatewayNew -PeerId $circuitId -ConnectionType ExpressRoute -RoutingWeight $connection.RoutingWeight -ExpressRouteGatewayBypass | Out-null
        }
        else
        {
            New-AzVirtualNetworkGatewayConnection -Name $connName -ResourceGroupName $resourceGroup -Location $location -VirtualNetworkGateway1 $gatewayNew -PeerId $circuitId -ConnectionType ExpressRoute -RoutingWeight $connection.RoutingWeight | Out-null
        }
    }

    $connNew = Get-AzVirtualNetworkGatewayConnection -Name $connName -ResourceGroupName $resourceGroup
    Write-Host New connection properties: ExpressRouteGatewayBypass: $connNew.ExpressRouteGatewayBypass, EnablePrivateLinkFastPath: $connNew.EnablePrivateLinkFastPath, Route Weight: $connNew.RoutingWeight, AuthorizationKey: $connNew.AuthorizationKey
}

$connectionsNew = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $resourceGroup | Where-Object -FilterScript {
    $_.VirtualNetworkGateway1.Name -contains $prefix
}

foreach($connection in $connectionsNew)
{
    if($connection.ProvisioningState -ne "Succeeded")
    {
        Write-Host $connection.Name " is " $connection.ProvisioningState
        Read-Host "Enter anything to exit, Prepare for migration failed"
        exit
    }
}

# logic to check if maintenance configuration is assigned to old gateway, if yes then create a new assignment for the new gateway using the same maintenance configuration

# Variables
$oldGatewayName = $gateway.Name
$newGatewayName = $gatewayNew.Name
$resourceType = "virtualNetworkGateways"
$providerName = "Microsoft.Network"

# Check for existing maintenance configuration assignment
try {
    $assignments = Get-AzConfigurationAssignment -ResourceGroupName $resourceGroup -ResourceName $oldGatewayName -ProviderName $providerName -ResourceType $resourceType
} catch {
    Write-Output "No maintenance configuration assignment found for $oldGatewayName"
    $assignments = @()
}

if ($assignment -ne $null -and $assignments.Count -gt 0) {
    foreach ($assignment in $assignments) {
        $maintenanceConfigId = $assignment.MaintenanceConfigurationId

        # Parse Maintenance Configuration ID to get the config name
        $parsed = $maintenanceConfigId -split "/"
        $maintenanceConfigName = $parsed[-1]

        # Retrieve the configuration object
        $config = Get-AzMaintenanceConfiguration -ResourceGroupName $resourceGroup -Name $maintenanceConfigName

        # Assign the configuration to the new gateway
        New-AzConfigurationAssignment `
            -ResourceGroupName $resourceGroup `
            -ResourceName $newGatewayName `
            -Location $config.Location `
            -ResourceType $resourceType `
            -ProviderName $providerName `
            -ConfigurationAssignmentName $config.Name `
            -MaintenanceConfigurationId $maintenanceConfigId

        Write-Output "Assigned maintenance configuration '$maintenanceConfigName' to '$newGatewayName'"
    }
} else {
    Write-Output "No configuration assignment exists for $oldGatewayName, so nothing was assigned to $newGatewayName"
}

$endTime = Get-Date
$diff = New-TimeSpan -Start $startTime -End $endTime
# Preparetion completed!
Write-Host "---------------- Prepare for migration for" $gatewayUri "is completed! Taking" $diff.TotalMinutes "minutes ----------------"
Read-Host "Enter anything to exit"
