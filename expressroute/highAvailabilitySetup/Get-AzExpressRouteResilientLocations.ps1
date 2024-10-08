param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$RelativeLocation = "",

    [Parameter(Mandatory = $false)]
    [string]$LocationType = ""
)

function UpdatePeeringLocationType {
    param (
        [PSCustomObject]$location
    )
    if ($location.properties.expressRouteLocationType -eq "ExpressRoutePortsLocation" -and $location.Name.ToLower().Contains("metro")) {
        $location.properties.expressRouteLocationType = "MetroDirectLocation"
    }
    elseif ($location.properties.expressRouteLocationType -eq "ExpressRoutePortsLocation" -and -not $location.Name.ToLower().Contains("metro")) {
        $location.properties.expressRouteLocationType = "ExpressRouteDirectLocation"
    }
    elseif ($location.properties.expressRouteLocationType -eq "ExpressRouteServiceProvidersLocation" -and $location.Name.ToLower().Contains("metro")) {
        $location.properties.expressRouteLocationType = "MetroPeeringLocation"
    }
    elseif ($location.properties.expressRouteLocationType -eq "ExpressRouteServiceProvidersLocation" -and -not $location.Name.ToLower().Contains("metro")) {
        $location.properties.expressRouteLocationType = "ExpressRoutePeeringLocation"
    }

    return $location
}

function Get-AzHighAvailabilityLocation {
    param (
        [string]$SubscriptionId,
        [string]$RelativeLocation,
        [string]$LocationType
    )

    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Network/ExpressRoutePortsLocations?api-version=2023-09-01&includeAllLocations=true"
    if ($RelativeLocation -ne "") {
        $uri += "&relativeLocation=$RelativeLocation"
    }

    try {
        $token = (Get-AzAccessToken -WarningAction:SilentlyContinue).token
        $headers = @{ 'Authorization' = "Bearer $Token" }
        $locations = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        $locationMap = @()
        $providers =  Get-AzExpressRouteServiceProvider -WarningAction:SilentlyContinue

        if ($RelativeLocation -ne "") {
            foreach ($location in $locations.value) {
                $location = UpdatePeeringLocationType -location $location

                if ($LocationType -eq "" -or $location.properties.expressRouteLocationType -eq $LocationType)
                {
                    $providersAvailableAtThisPeeringLocation = @()
                    if ($location.properties.relativeDistanceOfPeeringLocations -ne $null -and [double]$location.properties.relativeDistanceOfPeeringLocations -gt 0) {
                        if ($location.properties.expressRouteLocationType.Contains("PeeringLocation")) {
                            foreach ($provider in $providers) {
                                if ($provider.PeeringLocations -icontains $location.Name) {
                                    $providersAvailableAtThisPeeringLocation += $provider.Name
                                }
                            }
                        }

                        $locationMap += [PSCustomObject]@{
                            Name = $location.name
                            DistanceInKm = ([double]$location.properties.relativeDistanceOfPeeringLocations).ToString("N0")
                            DistanceInMi = ([double]$location.properties.relativeDistanceOfPeeringLocations / 1.6).ToString("N0")
                            Type = $location.properties.expressRouteLocationType
                            ProvidersAvailableAtThisPeeringLocation = $providersAvailableAtThisPeeringLocation
                        }
                    }
                }
            }

            if ($locations.value.Count -gt 0 -and $locationMap.Count -eq 0) {
                Write-Error "Failed to get distances from peering location $RelativeLocation, please check spelling of peering location."
                return $null
            }
        }
        else {
            foreach ($location in $locations.value) {
                $location = UpdatePeeringLocationType -location $location
                $providersAvailableAtThisPeeringLocation = @()

                if ($LocationType -eq "" -or $location.properties.expressRouteLocationType -eq $LocationType)
                {
                    if ($location.properties.expressRouteLocationType.Contains("PeeringLocation")) {
                        foreach ($provider in $providers) {
                            if ($provider.PeeringLocations -icontains $location.Name) {
                                $providersAvailableAtThisPeeringLocation += $provider.Name
                            }
                        }
                    }

                    $locationMap += [PSCustomObject]@{
                        Name = $location.name
                        Type = $location.properties.expressRouteLocationType
                        ProvidersAvailableAtThisPeeringLocation = $providersAvailableAtThisPeeringLocation
                    }
                }
            }
        }
        
        return $locationMap
    } catch {
        Write-Error "Failed to retrieve data from Azure API. $_"
        return $null
    }
}

$result = Get-AzHighAvailabilityLocation -SubscriptionId $SubscriptionId -RelativeLocation $RelativeLocation -LocationType $LocationType
if ($result -ne $null) {
    $result | Format-Table -AutoSize | Out-Host -Paging
} else {
    Write-Host "Failed to retrieve high availability locations."
}
