# Run the following operations to migrate gateway

1. Enable AFEC flag on customer subscription:
   - AllowDeletionOfIpPrefixFromSubnet
   - AllowMultipleAddressPrefixesOnSubnet

1. Enable GWM feature flag on customer subscription:
   - EREnableMultipleIpv4PrefixesOnGWSubnet
   - EREnableMultipleGatewaysOnGWSubnet

1. Customer need to add a second prefix to gateway subnet via PowerShell
1. Install the latest PowerShell for Az.Network Module to have the new API to enable/disable gateway
1. Run `PrepareMigration.ps1`, this script performs validation and create all new resources :
   gateway and connections
1. Run `Migration.ps1`. This script switches traffic from one gateway to another
1. Run `CommitMigration.ps1`. This script removes unused resources: disabled gateway and its
   connections
1. For rollback, run `Migration.ps1` to switch back to original gateway then run
   `CommitMigration.ps1`
1. Note: No resources other than ER gateway and connection should have any change during this
   migration flow

## Sample output

```Output
Script to prepare migration and create resources
C:\code\Networking-nfv\TSGs\ExpressRoute\TSGs\GatewayMigration> .\PrepareMigration.ps1
Prepare Migration: Please Enter Gateway Resource ID: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1
Customer Subscription ID: 00000000-0000-0000-0000-000000000000
Getting existing resources for gateway: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1
---------------- All validation passed, start creating new resources ----------------
Please choose the suffix for new resources, new resource name will be existingresourcename_<suffix>: new
Please select zones for new gateway: 1
Please choose the sku for new gateway [ErGw1AZ|ErGw2AZ|ErGw3AZ]: ErGw1AZ
---------------- Creating new gateway AzureGateway1_new Sku ErGw1AZ ----------------
---------------- Creating new connection conn1_new with circuit /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/expressRouteCircuits/circuit ----------------
---------------- Prepare for migration for /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1 is completed! Taking 28.6089642616667 minutes ----------------
Enter anything to exit:

Script to migrate traffic from old gateway to new gateway or vice verse
PS C:\code\Networking-nfv\TSGs\ExpressRoute\TSGs\GatewayMigration> .\Migration.ps1
Migrate from Gateway Resource ID: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1
Migrate to Gateway Resource ID: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1_new
Customer Subscription ID: 00000000-0000-0000-0000-000000000000
---------------- Enabling gateway AzureGateway1_new ----------------
---------------- Disabling gateway AzureGateway1 ----------------
---------------- Migration from /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1 to /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1_new is completed! Taking 4.87634857666667 minutes----------------
Enter anything to exit:

Script to commit migration and delete resources
PS C:\code\Networking-nfv\TSGs\ExpressRoute\TSGs\GatewayMigration> .\CommitMigration.ps1
Commit Migration: Please Enter Gateway Resource ID: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1
Customer Subscription ID: 00000000-0000-0000-0000-000000000000
---------------- Found disabled gateway /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1 ----------------
Please enter Y to confirm this is the gateway to be deleted /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1: y
---------------- Removing gateway AzureGateway1 ----------------
---------------- Commit for migration for /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/testtunnelciscop3/providers/Microsoft.Network/virtualNetworkGateways/AzureGateway1 is completed! Taking  minutes----------------
Enter anything to exit:
```
