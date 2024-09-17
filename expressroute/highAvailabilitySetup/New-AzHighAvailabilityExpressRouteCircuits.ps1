param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [string]$Name1 = $null,

    [string]$Name2 = $null,

    [string]$SkuFamily1 = $null,

    [string]$SkuFamily2 = $null,

    [string]$SkuTier1 = $null,

    [string]$SkuTier2 = $null,

    [string]$ServiceProviderName1 = $null,

    [string]$ServiceProviderName2 = $null,

    [string]$PeeringLocation1 = $null,

    [string]$PeeringLocation2 = $null,

    [Parameter(Mandatory = $true)]
    [int]$BandwidthInMbps,

    [Microsoft.Azure.Commands.Network.Models.PSExpressRoutePort]$ExpressRoutePort1 = $null,

    [Microsoft.Azure.Commands.Network.Models.PSExpressRoutePort]$ExpressRoutePort2 = $null,

    [Microsoft.Azure.Commands.Network.Models.PSExpressRouteCircuit]$ExistingCircuit = $null
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

function GetPeeringLocation1FromExistingCircuit {
    param (
        [Microsoft.Azure.Commands.Network.Models.PSExpressRouteCircuit]$ExistingCircuit
    )

    try {
        if ($ExistingCircuit.ExpressRoutePort -ne $null -and $ExistingCircuit.ExpressRoutePort -ne ""){
            $port = Get-AzExpressRoutePort -ResourceId $ExistingCircuit.ExpressRoutePort.Id
            return $port.PeeringLocation
        }
        else {
            return $ExistingCircuit.ServiceProviderProperties.PeeringLocation
        }   
    } catch {
        Write-Error "`nFailed to retrieve peering location from existing circuit. $_"
        exit
    }
}

function ValidateBandwidth {
    param (
        [int]$BandwidthInMbps,
        [string]$ExpressRoutePort1,
        [string]$ExpressRoutePort2
    )
    if(($ExpressRoutePort1 -or $ExpressRoutePort2) -and $BandwidthInMbps % 1000 -ne 0) {
        Write-Error "`nBandwidthInMbps is set for both circuits. Since one of the circuits is created on port, allowed bandwidths in mbps are [1000, 2000, 5000, 10000, 40000, 100000]"
        exit
    }
}


#### Start of the main program

if ($ExistingCircuit) {
    $PeeringLocation1 = GetPeeringLocation1FromExistingCircuit -ExistingCircuit $ExistingCircuit
}

if ($ExpressRoutePort1) {
    $PeeringLocation1 = $ExpressRoutePort1.PeeringLocation
}

if ($ExpressRoutePort2) {
    $PeeringLocation2 = $ExpressRoutePort2.PeeringLocation
}

# Check the distance and provide recommendations or fail operation if distance is 0 or less
WriteRecommendation -SubscriptionId $SubscriptionId -PeeringLocation1 $PeeringLocation1 -PeeringLocation2 $PeeringLocation2

# Validate bandwidth is available for the express route port, if one of the circuits are created on port
ValidateBandwidth -BandwidthInMbps $BandwidthInMbps -ExpressRoutePort1 $ExpressRoutePort1 -ExpressRoutePort2 $ExpressRoutePort2

$newGuid = [guid]::NewGuid()
$tags = @{
    "MaximumResiliency" = $newGuid.ToString()
}

try {
    # Create circuit 1
    if ($ExistingCircuit -eq $null) {
        Write "`nCreating circuit $($Name1)"
        if ($ServiceProviderName1) {
            New-AzExpressRouteCircuit -Name $Name1 -ResourceGroupName $ResourceGroupName -Location $Location -SkuTier $SkuTier1 -SkuFamily $SkuFamily1 -ServiceProviderName $ServiceProviderName1 -PeeringLocation $PeeringLocation1 -BandwidthInMbps $BandwidthInMbps -Tag $tags -WarningAction:SilentlyContinue
        }
        else {
            $BandwidthInGbps1 = $BandwidthInMbps / 1000
            $Location = $ExpressRoutePort1.Location
            New-AzExpressRouteCircuit -Name $Name1 -ResourceGroupName $ResourceGroupName -ExpressRoutePort $ExpressRoutePort1 -Location $Location -SkuTier $SkuTier1 -SkuFamily $SkuFamily1 -BandwidthInGbps $BandwidthInGbps1 -Tag $tags -WarningAction:SilentlyContinue
        }

        $circuit1 = Get-AzExpressRouteCircuit -Name $Name1 -ResourceGroupName $ResourceGroupName -WarningAction:SilentlyContinue
        if ($circuit1 -eq $null -or $circuit1.ProvisioningState -eq "Failed") {
            $errorMessage = "Failed to create circuit $($Name1) in location $($PeeringLocation1)"
            throw New-Object System.Exception($errorMessage)
        }
    }

    # Create cicuit 2
    Write "`nCreating circuit $($Name2)"
    if ($ServiceProviderName2) {
        New-AzExpressRouteCircuit -Name $Name2 -ResourceGroupName $ResourceGroupName -Location $Location -SkuTier $SkuTier2 -SkuFamily $SkuFamily2 -ServiceProviderName $ServiceProviderName2 -PeeringLocation $PeeringLocation2 -BandwidthInMbps $BandwidthInMbps -Tag $tags -WarningAction:SilentlyContinue
    }
    else {
        $BandwidthInGbps2 = $BandwidthInMbps / 1000
        $Location = $ExpressRoutePort2.Location
        New-AzExpressRouteCircuit -Name $Name2 -ResourceGroupName $ResourceGroupName -ExpressRoutePort $ExpressRoutePort2 -Location $Location -SkuTier $SkuTier2 -SkuFamily $SkuFamily2 -BandwidthInGbps $BandwidthInGbps2 -Tag $tags -WarningAction:SilentlyContinue
    }
} catch {
    Write-Error "Failed to create circuits. $_"
    exit
}
