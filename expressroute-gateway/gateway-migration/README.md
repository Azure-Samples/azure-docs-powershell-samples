Run the following operations to migrate gateway

1. Enable AFEC flag on customer subscription : 
<br>AllowDeletionOfIpPrefixFromSubnet</br>
<br>AllowMultipleAddressPrefixesOnSubnet</br>

1. Enable GWM feature flag on customer subscription: 
<br>EREnableMultipleIpv4PrefixesOnGWSubnet</br>
<br>EREnableMultipleGatewaysOnGWSubnet</br>

1. Customer need to add a second prefix to gateway subnet via powershell 
1. Install the latest powershell for Az.Network Module to have the new API to enable/disable gateway
1. Install Az.ResourceGraph module if it was not installed by default with PowerShell installation
1. Run PrepareMigration.ps1, this script will do validation and create all new resources : gateway and connections. Please note that Microsoft will auto-assign a Standard Public IP to ExpressRoute Gateway. Creation of Public IP is no longer required. 
1. Run Migration.ps1, this script will switch traffic from one gateway to another 
1. Run CommitMigration.ps1. this script will remove unused resources: disabled gateway and its connections
1. For rollback, run Migration.ps1 to switch back to original gateway then run CommitMigration.ps1
1. Note: No resouces other than ER gateway and connection should have any change during this migration flow. 

Sample powershell output 
<br><b>Script to prepare migration and create resources</b></br>
<br>PS C:\code\Networking-nfv\TSGs\ExpressRoute\TSGs\GatewayMigration> .\PrepareMigration.ps1</br>
<br>Prepare Migration: Please Enter Gateway Resource ID: /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.<br>Network/virtualNetworkGateways/AzureGateway1</br>
<br>Customer Subscription ID: 55f0d0f8-7997-4853-b0d3-91e4817cfaaa</br>
<br>Getting existing resources for gateway: /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/<br>virtualNetworkGateways/AzureGateway1</br>
<br>---------------- All validation passed, start creating new resources ----------------</br>
<br>Please choose the suffix for new resources, new resource name will be existingresourcename_<suffix>: new</br>
<br>Please select zones for new gateway: 1</br>
<br>Please choose the sku for new gateway [ErGw1AZ|ErGw2AZ|ErGw3AZ]: ErGw1AZ</br>
Please enter Y if you wish to create a Public IP for the new gateway:
<br>---------------- Creating new gateway AzureGateway1_new Sku ErGw1AZ ----------------</br>
<br>---------------- Creating new connection conn1_new with circuit /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/expressRouteCircuits/circuit ----------------</br>
<br>---------------- Prepare for migration for /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1 is completed! Taking 28.6089642616667 minutes ----------------</br>
<br>Enter anything to exit:</br>

<br><b>Script to migrate traffic from old gateway to new gateway or vice verse</b></br>
<br>PS C:\code\Networking-nfv\TSGs\ExpressRoute\TSGs\GatewayMigration> .\Migration.ps1</br>
<br>Migrate from Gateway Resource ID: /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1</br>
<br>Migrate to Gateway Resource ID: /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1_new</br>
<br>Customer Subscription ID: 55f0d0f8-7997-4853-b0d3-91e4817cfaaa</br>
<br>---------------- Enabling gateway AzureGateway1_new ----------------</br>
<br>---------------- Disabling gateway AzureGateway1 ----------------</br>
<br>---------------- Migration from /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1 to /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/</br>providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1_new is completed! Taking 4.87634857666667 minutes----------------</br>
<br>Enter anything to exit:</br>

<br><b>Script to commit migration and delete resources</b></br>
<br>PS C:\code\Networking-nfv\TSGs\ExpressRoute\TSGs\GatewayMigration> .\CommitMigration.ps1</br>
<br>Commit Migration: Please Enter Gateway Resource ID: /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1</br>
<br>Customer Subscription ID: 55f0d0f8-7997-4853-b0d3-91e4817cfaaa
<br>---------------- Found disabled gateway /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1 ----------------</br>
<br>Please enter Y to confirm this is the gateway to be deleted /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1: y</br>
<br>---------------- Removing gateway AzureGateway1 ----------------</br>
<br>---------------- Commit for migration for /subscriptions/55f0d0f8-7997-4853-b0d3-91e4817cfaaa/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1 is completed! Taking  minutes----------------</br>
<br>Enter anything to exit:</br>
