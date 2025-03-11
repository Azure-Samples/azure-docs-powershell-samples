# automate-vnet-ip-address-management.ps1
# Version: 1.0.1
# Change log: Remove PID from script
# Author: mbender-ms 
# Date: 2025-03-10
# Description: This script automates the process of creating, associating, and disassociating Virtual Networks with IPAM Pools in Azure. It uses PowerShell to interact with Azure resources and manage IP address allocations efficiently. The script is designed to be run in a synchronous manner to ensure that no API calls fail such that they need to be retried. The script includes bulk creation of Virtual Networks using IpamPools reference, association of existing Virtual Networks using IpamPool reference, and disassociation of existing Virtual Networks using IpamPool reference. It is for demonstrtation purposes only and should not be used in production environments.

# Prerequisites:
# - Azure PowerShell module installed and configured, or Azure Cloud Shell
# - Azure account with appropriate permissions to create and manage Virtual Networks, Azure Virtual Network Manager and IPAM Pools
# - Valid Azure subscription ID and resource group name
# - IPAM Pool reference ARM ID for creating and associating Virtual Networks

# Run the script in Azure PowerShell or Azure Cloud Shell with appropriate permissions to create and manage Virtual Networks, Azure Virtual Network Manager and IPAM Pools.
# This script is for demonstration purposes only and should not be used in production environments.
# Note: The script uses the Az module for Azure PowerShell. Ensure you have the latest version of the Az module installed.


# Set the variables for the script to your environment

$location = "<your resource location>" # e.g. "East US", "West Europe", etc.
$rgname = "<your resource group>" # use RG name as "*" to fetch all VNets from all RGs within subscription
$sub = "<your subscription id>" # use subscription id as "*" to fetch all VNets from all subscriptions within tenant
$ipamPoolARMId = "<your ipam pool ARM ID>" # e.g. "/subscriptions/<your subscription id>/resourceGroups/<your resource group>/providers/Microsoft.Network/ipamPools/<your ipam pool name>"
$numberIPaddresses = "8" # Number of IP addresses to allocate from the IPAM Pool. This should be a valid number based on your IPAM Pool configuration.

# Select your subscription
Set-AzContext -Subscription $sub

# Set the 
Write-Output "Starting creation of new VNets with IpamPool reference at: " (Get-Date).ToString("HH:mm:ss")
$ipamPoolPrefixAllocation = [PSCustomObject]@{
    Id = $ipamPoolARMId 
    NumberOfIpAddresses = $numberIPaddresses 
}

# Create 10 VNets using ipamPool reference - Change the number of VNets to create as needed in the for loop below
for ($i = 0; $i -lt 10; $i++) {
    $subnetName = "defaultSubnet"
    $vnetName = "bulk-ipam-vnet-$i"
    $subnet = New-AzVirtualNetworkSubnetConfig -Name $subnetName -IpamPoolPrefixAllocation $ipamPoolPrefixAllocation -DefaultOutboundAccess $false
    $job = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgname -Location $location -IpamPoolPrefixAllocation $ipamPoolPrefixAllocation -Subnet $subnet -AsJob
    $job | Wait-Job
    $actual = $job | Receive-Job
}
Write-Output "Starting creation of new VNets with IpamPool reference at: " (Get-Date).ToString("HH:mm:ss")

# fetch all virtual networks from a resource group
$vnetList = Get-AzVirtualNetwork -ResourceGroupName $rgname

# bulk disassociation update
Write-Output "Starting bulk disassociation for existing VNets at: " (Get-Date).ToString("HH:mm:ss")
$ipamPoolPrefixAllocation = $null
for ($i = 0; $i -lt @($vnetList).Count; $i++) {
    $vnetList[$i].AddressSpace.IpamPoolPrefixAllocations = $ipamPoolPrefixAllocation
    foreach ($subnet in $vnetList[$i].Subnets) {
        $subnet.IpamPoolPrefixAllocations = $ipamPoolPrefixAllocation
    }
    $job = Set-AzVirtualNetwork -VirtualNetwork $vnetList[$i] -AsJob
    $job | Wait-Job
    $actual = $job | Receive-Job
}
Write-Output "Starting bulk disassociation for existing VNets at: " (Get-Date).ToString("HH:mm:ss")

# bulk association update
Write-Output "Starting bulk association for existing VNets at: " (Get-Date).ToString("HH:mm:ss")
$ipamPoolPrefixAllocation = [PSCustomObject]@{
    Id = $ipamPoolARMId
    NumberOfIpAddresses = $numberIPaddresses
}
for ($i = 0; $i -lt @($vnetList).Count; $i++) {
    $vnetList[$i].AddressSpace.IpamPoolPrefixAllocations = $ipamPoolPrefixAllocation
    foreach ($subnet in $vnetList[$i].Subnets) {
        $subnet.IpamPoolPrefixAllocations = $ipamPoolPrefixAllocation
    }
    $job = Set-AzVirtualNetwork -VirtualNetwork $vnetList[$i] -AsJob
    $job | Wait-Job
    $actual = $job | Receive-Job
}
Write-Output "Finished bulk association for existing VNets at: " (Get-Date).ToString("HH:mm:ss")