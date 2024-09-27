# New-AzHighAvailabilityVirtualNetworkGatewayConnections.ps1
## Syntax
```
New-AzHighAvailabilityVirtualNetworkGatewayConnections
	-SubscriptionId <String>
	-ResourceGroupName <String> 
	-Location <String> 
    -VirtualNetworkGateway1 <PSVirtualNetworkGateway> 
	[-Name1 <String>]
	-Name2 <String>
	[-Peer1 <PSPeering>] 
	[-Peer2 <PSPeering>]
	[-PeerId1 <String>] 
	[-PeerId2 <String>]
	[-RoutingWeight1 <Int32>]
	[-RoutingWeight2 <Int32>]
	[-ExpressRouteGatewayBypass1 <String>]
	[-ExpressRouteGatewayBypass1 <String>]
	[-ExistingVirtualNetworkGatewayConnection <PSVirtualNetworkGatewayConnection>]
```

## Description
The  **New-AzHighAvailabilityVirtualNetworkGatewayConnections**  cmdlet creates a pair of Azure express route virtual network gateway connections.

## Examples
### Example 1: Create 2 new connections.
```
 .\New-AzHighAvailabilityVirtualNetworkGatewayConnections.ps1 -SubscriptionId <subId> -ResourceGroupName <rgName> -Location <locationName> -Name1 <connection1Name> -Name2 <connection2Name> -Peer1 $circuit1.Peerings[0] -Peer2 $circuit2.Peerings[0] -RoutingWeight1 10 -RoutingWeight2 10 -VirtualNetworkGateway1 $vng
```
### Example 2:  Create 1 new connection, and use existing connection to get recommendation
```
 .\New-AzHighAvailabilityVirtualNetworkGatewayConnections.ps1 -SubscriptionId <subId> -ResourceGroupName <rgName> -Location <locationName> -Name2 <connectionName> -Peer2 $circuit1.Peerings[0] -RoutingWeight2 10 -VirtualNetworkGateway1 $vng -ExistingVirtualNetworkGatewayConnection $connection
```  