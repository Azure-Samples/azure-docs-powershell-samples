
# <SetVariables>
# <GlobalVariables>
$SubscriptionId = "<Enter Subscription ID>"
$Location = "<Enter Location>"
$ResourceGroupName = "<Enter Resource Group Name>"
$userName = "<Enter User Name for the virtual machine"
# </GlobalVariables>

# <StorageVariables>
$StorageName = "sqlvm" + "storage"
$StorageSku = "Premium_LRS"
# </StorageVariables>

# <NetworkVariables>
$InterfaceName = $ResourceGroupName + "ServerInterface"
$NsgName = $ResourceGroupName + "nsg"
$TCPIPAllocationMethod = "Dynamic"
$VNetName = $ResourceGroupName + "VNet"
$SubnetName = "Default"
$VNetAddressPrefix = "10.0.0.0/16"
$VNetSubnetAddressPrefix = "10.0.0.0/24"
$DomainName = $ResourceGroupName
# </NetworkVariables>

# <ComputeVariables>
$VMName = $ResourceGroupName + "VM"
$ComputerName = $ResourceGroupName + "Server"
$VMSize = "Standard_DS13"
$OSDiskName = $VMName + "OSDisk"
# </ComputeVariables>

# <ImageVariables>
$OfferName = "SQL2022-WS2022"
$PublisherName = "MicrosoftSQLServer"
$Version = "latest"
$Sku = "SQLDEV-GEN2"
$License = 'PAYG'

# <CreateCredential>
# Define a credential object
$SecurePassword = ConvertTo-SecureString '<strong password>' `
   -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential ($userName, $securePassword)
# </CreateCredential>
# </ImageVariables>

# </SetVariables>

# <FullScript>

# <CreateResourceGroup>

# Set subscription context
Connect-AzAccount
$subscriptionContextParams = @{
    SubscriptionId = $SubscriptionId
}
Set-AzContext @subscriptionContextParams

# Create a resource group
$resourceGroupParams = @{
    Name = $resourceGroupName
    Location = $Location
    Tag = @{Owner="SQLDocs-Samples"}
}
$resourceGroup = New-AzResourceGroup @resourceGroupParams

# </CreateResourceGroup>


# <CreateStorageAccount>
# Create storage account
$StorageAccount = New-AzStorageAccount -ResourceGroupName $ResourceGroupName `
   -Name $StorageName -SkuName $StorageSku `
   -Kind "Storage" -Location $Location
# </CreateStorageAccount>

# <CreateSubnetConfig>
# Create a subnet configuration
$SubnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $VNetSubnetAddressPrefix
# </CreateSubnetConfig>

# <CreateVirtualNetwork>
# Create a virtual network
$VNet = New-AzVirtualNetwork -Name $VNetName `
   -ResourceGroupName $ResourceGroupName -Location $Location `
   -AddressPrefix $VNetAddressPrefix -Subnet $SubnetConfig
# </CreateVirtualNetwork>

# <CreatePublicIP>
# Create a public IP address
$PublicIp = New-AzPublicIpAddress -Name $InterfaceName `
-ResourceGroupName $ResourceGroupName -Location $Location `
-AllocationMethod $TCPIPAllocationMethod -DomainNameLabel $DomainName
# </CreatePublicIP>

# <CreateNetworkSecurityGroupRules>
# Create a network security group rule
$NsgRuleRDP = New-AzNetworkSecurityRuleConfig -Name "RDPRule" -Protocol Tcp `
-Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * `
-DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow

$NsgRuleSQL = New-AzNetworkSecurityRuleConfig -Name "MSSQLRule"  -Protocol Tcp `
-Direction Inbound -Priority 1001 -SourceAddressPrefix * -SourcePortRange * `
-DestinationAddressPrefix * -DestinationPortRange 1433 -Access Allow
# </CreateNetworkSecurityGroupRules>

# <CreateNetworkSecurityGroup>
# Create a network security group
$Nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName `
-Location $Location -Name $NsgName `
-SecurityRules $NsgRuleRDP,$NsgRuleSQL
# </CreateNetworkSecurityGroup>

# <CreateNetworkInterface>
# Create a network interface
$Interface = New-AzNetworkInterface -Name $InterfaceName `
   -ResourceGroupName $ResourceGroupName -Location $Location `
   -SubnetId $VNet.Subnets[0].Id -PublicIpAddressId $PublicIp.Id `
   -NetworkSecurityGroupId $Nsg.Id
# </CreateNetworkInterface>

# <CreateVirtualMachine>
# Create a virtual machine configuration
$VMName = $ResourceGroupName + "VM"
$VMConfig = New-AzVMConfig -VMName $VMName -VMSize Standard_DS13_V2 |
    Set-AzVMOperatingSystem -Windows -ComputerName $VMName -Credential $Cred -ProvisionVMAgent -EnableAutoUpdate |
    Set-AzVMSourceImage -PublisherName $PublisherName -Offer $OfferName -Skus $Sku  -Version $Version |
    Add-AzVMNetworkInterface -Id $Interface.Id

# Create the VM
New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VMConfig
# </CreateVirtualMachine>

# <RegisterSQLIaaSExtension>

# Register the SQL IaaS Agent extension to your subscription
Register-AzResourceProvider -ProviderNamespace Microsoft.SqlVirtualMachine

# Register SQL Server VM with the extension
New-AzSqlVM -Name $VMName -ResourceGroupName $ResourceGroupName -Location $Location `
-LicenseType $License
# </RegisterSQLIaaSExtension>

# </FullScript>

# <Cleanup>
# Clean up deployment 
# Stop-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName
# Remove-AzResourceGroup -ResourceGroupName $ResourceGroupName
# </Cleanup>
