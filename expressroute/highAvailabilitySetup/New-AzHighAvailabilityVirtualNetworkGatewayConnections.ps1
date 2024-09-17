param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [string]$Name1 = $null,

    [Parameter(Mandatory = $true)]
    [string]$Name2 = $null,

    [Microsoft.Azure.Commands.Network.Models.PSPeering]$Peer1  = $null,

    [Microsoft.Azure.Commands.Network.Models.PSPeering]$Peer2 = $null,

    [string]$PeerId1  = $null,

    [string]$PeerId2 = $null,

    [Int32]$RoutingWeight1 = $null,

    [Parameter(Mandatory = $true)]
    [Int32]$RoutingWeight2 = $null,

    [string]$ExpressRouteGatewayBypass1 = $null,

    [string]$ExpressRouteGatewayBypass2 = $null,

    [Parameter(Mandatory = $true)]
    [Microsoft.Azure.Commands.Network.Models.PSVirtualNetworkGateway]$VirtualNetworkGateway1 = $null,

    [Microsoft.Azure.Commands.Network.Models.PSVirtualNetworkGatewayConnection]$ExistingVirtualNetworkGatewayConnection = $null
)

Import-Module -Name Az.Network -WarningAction:SilentlyContinue

function WriteRecommendation {
    param (
        [string]$SubscriptionId,
        [string]$PeeringLocation1,
        [string]$PeeringLocation2
    )

    $token = (Get-AzAccessToken).token
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Network/ExpressRoutePortsLocations?api-version=2023-09-01&includeAllLocations=true&relativeLocation=$PeeringLocation2"
    $headers = @{ 'Authorization' = "Bearer $token" }

    try {
        if ($PeeringLocation1 -ceq $PeeringLocation2) {
            Write-Error "Circuit 1 peering location ($($PeeringLocation1)) is the same as Circuit 2 peering location ($($PeeringLocation2)), please choose different peering locations to achieve high availability"
            exit
        }

        $locations = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

        $distanceInKm = -1
        foreach ($location in $locations.value) {
            if ($location.name -eq $PeeringLocation1) {
                $distanceInKm = ([double]$location.properties.relativeDistanceOfPeeringLocations).ToString("N0");
            }
        }

        $DistanceInMi = ([double]$distanceInKm / 1.6).ToString("N0")

        if ([double]$distanceInKm -lt 0) {
            Write-Host "`nRecommendation cannot be provided as distance between peering locations ($($PeeringLocation1)) and ($($PeeringLocation2)) is not found."
            exit
        }
        elseif ([double]$distanceInKm -eq 0) {
            Write-Host "`nDistance between peering locations ($($PeeringLocation1)) and ($($PeeringLocation2)) is 0. Please update one of the peering locations to achieve high availability."
            exit
        }
        else {
            if ([double]$distanceInKm -lt 242) {
                Write-Host "`nCircuit 1 peering location ($($PeeringLocation1)) is $($distanceInKm) km ($($DistanceInMi) miles) away from circuit 2 location ($($PeeringLocation2)). Based on the distance, it is recommended that the two circuits be used as High Available redundant circuits and the traffic be load balanced across the two circuits."
            } else {
                Write-Host "`nCircuit 1 peering location ($($PeeringLocation1)) is $($distanceInKm) km ($($DistanceInMi) miles) away from circuit 2 location ($($PeeringLocation2)). Based on the distance, it is recommended that the two circuits be used as redundant disaster recovery circuits and engineer traffic across the circuits by having one as active and the other as standby."
            }

            $response = Read-Host "`nPlease confirm you read the recommendation (Y/N)"
            if ($response -ne "Y" -and $response -ne "y") {
                exit
            }
        }
        
    } catch {
        Write-Error "`nFailed to retrieve distance between locations. $_"
        exit
    }
}

function GetPeeringLocationFromCircuitId {
    param (
        [string]$PeerId
    )

    try {
        $pattern = "/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/Microsoft.Network/expressRouteCircuits/([^/]+)"
        
        if ($PeerId -match $pattern) {
            $resourceGroupName = $matches[1]
            $circuitName = $matches[2]
        } else {
            Write-Host "Resource group name and circuit name not found."
        }

        $circuit = Get-AzExpressRouteCircuit -ResourceGroupName $resourceGroupName -Name $circuitName -WarningAction:SilentlyContinue

        if ($circuit.ExpressRoutePort -ne $null -and $circuit.ExpressRoutePort -ne ""){
            $port = Get-AzExpressRoutePort -ResourceId $circuit.ExpressRoutePort.Id
            return $port.PeeringLocation
        }
        else {
            return $circuit.ServiceProviderProperties.PeeringLocation
        }   
    } catch {
        Write-Error "`nFailed to retrieve peering location from circuit. $_"
        exit
    }
}

#### Start of the main program

if ($ExistingVirtualNetworkGatewayConnection -ne $null) {
    $PeerId1 = $ExistingVirtualNetworkGatewayConnection.Peer.Id
}
else {
    if ($Peer1 -ne $null) {
        $PeerId1 = $peer1.Id -replace "/peerings/AzurePrivatePeering.*", ""
    }
    else {
        $PeerId1 = $PeerId1 -replace "/peerings/AzurePrivatePeering.*", ""
    }
}

if ($Peer2 -ne $null) {
    $PeerId2 = $peer2.Id -replace "/peerings/AzurePrivatePeering.*", ""
}
else {
    $PeerId2 = $PeerId2 -replace "/peerings/AzurePrivatePeering.*", ""
}

$PeeringLocation1 = GetPeeringLocationFromCircuitId -PeerId $PeerId1
$PeeringLocation2 = GetPeeringLocationFromCircuitId -PeerId $PeerId2

# Check the distance and provide recommendations or fail operation if distance is 0 or less
WriteRecommendation -SubscriptionId $SubscriptionId -PeeringLocation1 $PeeringLocation1 -PeeringLocation2 $PeeringLocation2

try {
    # Create connection 1
    if ($ExistingVirtualNetworkGatewayConnection -eq $null) {
        Write "`nCreating first connection $($Name1)"
        New-AzVirtualNetworkGatewayConnection -Name $Name1 -ResourceGroupName $ResourceGroupName -Location $Location -VirtualNetworkGateway1 $VirtualNetworkGateway1 -ConnectionType "ExpressRoute" -RoutingWeight $RoutingWeight1 -PeerId $PeerId1

        $connection1 = Get-AzVirtualNetworkGatewayConnection -Name $Name1 -ResourceGroupName $ResourceGroupName -WarningAction:SilentlyContinue -ErrorAction:SilentlyContinue
        if ($connection1 -eq $null -or $circuit1.ProvisioningState -eq "Failed") {
            $errorMessage = "Failed to create connection $($Name1) in location $($PeeringLocation1)"
            throw New-Object System.Exception($errorMessage)
        }
    }

    # Create connection 2
    Write "`nCreating second connection $($Name2)"
    if ($Peer1 -ne $null) {
        $PeerId1 = $peer1.Id
    }
        
    New-AzVirtualNetworkGatewayConnection -Name $Name2 -ResourceGroupName $ResourceGroupName -Location $Location -VirtualNetworkGateway1 $VirtualNetworkGateway1 -ConnectionType "ExpressRoute" -RoutingWeight $RoutingWeight2 -PeerId $PeerId2

    $connection2 = Get-AzVirtualNetworkGatewayConnection -Name $Name2 -ResourceGroupName $ResourceGroupName -WarningAction:SilentlyContinue
    if ($connection2 -eq $null -or $circuit2.ProvisioningState -eq "Failed") {
        $errorMessage = "Failed to create connection $($Name2) in location $($PeeringLocation2)"
        throw New-Object System.Exception($errorMessage)
    }
} catch {
    Write-Error "Failed to create connections. $_"
    exit
}
