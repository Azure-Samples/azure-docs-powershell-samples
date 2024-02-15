# <SetVariables>
$NSnetworkModels = "Microsoft.Azure.Commands.Network.Models"
$NScollections = "System.Collections.Generic"

Connect-AzAccount
# The SubscriptionId in which to create these objects
$SubscriptionId = ''
# Set the resource group name and location for your managed instance
$resourceGroupName = "myResourceGroup-$(Get-Random)"
$location = "eastus2"
# Set the networking values for your managed instance
$vNetName = "myVnet-$(Get-Random)"
$vNetAddressPrefix = "10.0.0.0/16"
$defaultSubnetName = "myDefaultSubnet-$(Get-Random)"
$defaultSubnetAddressPrefix = "10.0.0.0/24"
$miSubnetName = "MISubnet-$(Get-Random)"
$miSubnetAddressPrefix = "10.0.0.0/24"
#Set the managed instance name for the new managed instance
$instanceName = "mi-name-$(Get-Random)"
# Set the admin login and password for your managed instance
$miAdminSqlLogin = "SqlAdmin"
$miAdminSqlPassword = "ChangeThisPassword!!"
# Set the managed instance service tier, compute level, and license mode
$edition = "General Purpose"
$vCores = 8
$maxStorage = 256
$computeGeneration = "Gen5"
$license = "LicenseIncluded" #"BasePrice" or LicenseIncluded if you have don't have SQL Server licence that can be used for AHB discount
$dbname = 'SampleDB'

# </SetVariables>

# <CreateResourceGroup>

# Set subscription context
$subscriptionContextParams = @{
    SubscriptionId = $SubscriptionId
}
Set-AzContext @subscriptionContextParams

# Create a resource group
$resourceGroupParams = @{
    Name = $resourceGroupName
    Location = $location
    Tag = @{Owner="SQLDB-Samples"}
}
$resourceGroup = New-AzResourceGroup @resourceGroupParams

# </CreateResourceGroup>

# <CreateVirtualNetwork>

# Configure virtual network, subnets, network security group, and routing table
$networkSecurityGroupParams = @{
    Name = 'myNetworkSecurityGroupMiManagementService'
    ResourceGroupName = $resourceGroupName
    Location = $location
}
$networkSecurityGroupMiManagementService = New-AzNetworkSecurityGroup @networkSecurityGroupParams

$routeTableParams = @{
    Name = 'myRouteTableMiManagementService'
    ResourceGroupName = $resourceGroupName
    Location = $location
}
$routeTableMiManagementService = New-AzRouteTable @routeTableParams

$virtualNetworkParams = @{
    ResourceGroupName = $resourceGroupName
    Location = $location
    Name = $vNetName
    AddressPrefix = $vNetAddressPrefix
}

$virtualNetwork = New-AzVirtualNetwork @virtualNetworkParams

$subnetConfigParams = @{
    Name = $miSubnetName
    VirtualNetwork = $virtualNetwork
    AddressPrefix = $miSubnetAddressPrefix
    NetworkSecurityGroup = $networkSecurityGroupMiManagementService
    RouteTable = $routeTableMiManagementService
}

$subnetConfig = Add-AzVirtualNetworkSubnetConfig @subnetConfigParams | Set-AzVirtualNetwork

$virtualNetwork = Get-AzVirtualNetwork -Name $vNetName -ResourceGroupName $resourceGroupName

$subnet= $virtualNetwork.Subnets[0]

# Create a delegation
$subnet.Delegations = New-Object "$NScollections.List``1[$NSnetworkModels.PSDelegation]"
$delegationName = "dgManagedInstance" + (Get-Random -Maximum 1000)
$delegationParams = @{
    Name = $delegationName
    ServiceName = "Microsoft.Sql/managedInstances"
}
$delegation = New-AzDelegation @delegationParams
$subnet.Delegations.Add($delegation)

Set-AzVirtualNetwork -VirtualNetwork $virtualNetwork

$miSubnetConfigId = $subnet.Id

$allowParameters = @{
    Access = 'Allow'
    Protocol = 'Tcp'
    Direction= 'Inbound'
    SourcePortRange = '*'
    SourceAddressPrefix = 'VirtualNetwork'
    DestinationAddressPrefix = '*'
}
$denyInParameters = @{
    Access = 'Deny'
    Protocol = '*'
    Direction = 'Inbound'
    SourcePortRange = '*'
    SourceAddressPrefix = '*'
    DestinationPortRange = '*'
    DestinationAddressPrefix = '*'
}
$denyOutParameters = @{
    Access = 'Deny'
    Protocol = '*'
    Direction = 'Outbound'
    SourcePortRange = '*'
    SourceAddressPrefix = '*'
    DestinationPortRange = '*'
    DestinationAddressPrefix = '*'
}

$networkSecurityGroupParams = @{
    ResourceGroupName = $resourceGroupName
    Name = "myNetworkSecurityGroupMiManagementService"
}

$networkSecurityGroup = Get-AzNetworkSecurityGroup @networkSecurityGroupParams

$allowRuleParams = @{
    Access = 'Allow'
    Protocol = 'Tcp'
    Direction = 'Inbound'
    SourcePortRange = '*'
    SourceAddressPrefix = 'VirtualNetwork'
    DestinationAddressPrefix = '*'
}

$denyInRuleParams = @{
    Access = 'Deny'
    Protocol = '*'
    Direction = 'Inbound'
    SourcePortRange = '*'
    SourceAddressPrefix = '*'
    DestinationPortRange = '*'
    DestinationAddressPrefix = '*'
}

$denyOutRuleParams = @{
    Access = 'Deny'
    Protocol = '*'
    Direction = 'Outbound'
    SourcePortRange = '*'
    SourceAddressPrefix = '*'
    DestinationPortRange = '*'
    DestinationAddressPrefix = '*'
}

$networkSecurityGroup |
    Add-AzNetworkSecurityRuleConfig @allowRuleParams -Priority 1000 -Name "allow_tds_inbound" -DestinationPortRange 1433 |
    Add-AzNetworkSecurityRuleConfig @allowRuleParams -Priority 1100 -Name "allow_redirect_inbound" -DestinationPortRange 11000-11999 |
    Add-AzNetworkSecurityRuleConfig @denyInRuleParams -Priority 4096 -Name "deny_all_inbound" |
    Add-AzNetworkSecurityRuleConfig @denyOutRuleParams -Priority 4096 -Name "deny_all_outbound" |
    Set-AzNetworkSecurityGroup


# </CreateVirtualNetwork>

# <CreateManagedInstance>

# Create credentials
$secpassword = ConvertTo-SecureString $miAdminSqlPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential -ArgumentList @($miAdminSqlLogin, $secpassword)

$managedInstanceParams = @{
    Name = $instanceName
    ResourceGroupName = $resourceGroupName
    Location = $location
    SubnetId = $miSubnetConfigId
    AdministratorCredential = $credential
    StorageSizeInGB = $maxStorage
    VCore = $vCores
    Edition = $edition
    ComputeGeneration = $computeGeneration
    LicenseType = $license
}

New-AzSqlInstance @managedInstanceParams

# </CreateManagedInstance>

# <CreateDatabase>

$databaseParams = @{
    ResourceGroupName = $resourceGroupName
    InstanceName = $instanceName
    Name = $dbname
    Collation = 'Latin1_General_100_CS_AS_SC'
}

New-AzSqlInstanceDatabase @databaseParams

# </CreateDatabase>

# Clean up deployment 
# Remove-AzResourceGroup -ResourceGroupName $resourceGroupName
