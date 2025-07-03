$ErrorActionPreference = "stop"

<#
.SYNOPSIS
    Automates creation of a migration volume and replication setup.

.DESCRIPTION
    This script is a guide through creating a migration volume and peering clusters for the migration assistant. 
    It invokes three requests from ANF needed to set up the migration workflow and informs the user about the two commands that need to be run on-premises:

      1. Creates a new migration volume on your target ANF capacity pool  
      2. Peers the target cluster with the external (source) on-premises cluster
      3. Prints the local peering command which needs to be executed manually on the external on-premises cluster 
      4. Authorizes the replication relationship from the ANF migration volume
      5. Prints the svm peering command which needs to be executed manually on the external on-premises cluster

   The top of the script contains all parameters that need to be filled in for the script to run correctly.
#>

######################################
# Fill in variables here
######################################

# Use this API version
$api_version = "2025-01-01"

# Insert the Azure subscription ID
$subscription_id = "<your-subscription-id>"

# Insert the NetApp account name
$netapp_account_name = "<your-netapp-account-name>"

# Insert the Azure resource group name
$resource_group_name = "<your-resource-group-name>"

# Insert the virtual network name
$vnet_name = "<your-virtual-network-name>"

# Insert the subnet name of the delegated subnet for AzureNetapp Files
$subnet_name = "<netapp-files-delegated-subnet-name>" 

# Insert the name of the migration volume here (this is the new ANF target volume). Make sure that this name is unique. A new volume will be created.
$migration_volume_name = "<your-migration-volume-name>"

# Insert the size of the migration volume here. Make sure it has enough capacity to accommodate for the actual size of the migrated volume plus extra space for new changes.
$migration_volume_size_gb = 50

# Insert the capacity pool name for the ANF capacity pool that the migration volume will go to. It should already exist and there should be a small "anchor" volume on it too.
$capacity_pool_name = "<your-capacity-pool-name>"

# Insert the name of the local (on-premises) volume to replicate
$on_premises_volume_name = "<local-volume-name>"

# Insert the name of the local cluster (on-premises) from which to replicate
$on_premises_cluster_name = "<local-cluster-name>"

# Insert the name of the SVM with the volume to replicate
$on_premises_svm = "<your-svm-name>"

# Insert the Azure region where the ANF migration volume will be located
$location = "<your-region>"

# This is a PowerShell array containing the intercluster lifs (peer addresses) of the on premises cluster
# ONTAP> network interface show -role intercluster
$lifs = @("<peer-ip-address>","<another-peer-ip-address>")


#########################
# Script runs here
#########################

# Get the subnet ID from Azure for the subnet that is ANF delegated for ANF volumes
$subnet_id = "/subscriptions/${subscription_id}/resourceGroups/${resource_group_name}/providers/Microsoft.Network/virtualNetworks/${vnet_name}/subnets/${subnet_name}"

# Get the capacity pool ID on Azure
$capacity_pool_id = "/subscriptions/${subscription_id}/resourceGroups/${resource_group_name}/providers/Microsoft.NetApp/netAppAccounts/${netapp_account_name}/capacityPools/${capacity_pool_name}"

# Create a new volume ID from $migration_volume_name and $capacity_pool_id and set the size in bytes
$volume_id = "${capacity_pool_id}/volumes/${migration_volume_name}"
$volume_size_bytes = $migration_volume_size_gb * 1GB

# Create the URLs that we'll need
$url_volume = "https://management.azure.com${volume_id}?api-version=$api_version"
$url_peer_external_cluster = "https://management.azure.com${volume_id}/peerExternalCluster?api-version=$api_version"
$url_authorize_external_replication = "https://management.azure.com${volume_id}/authorizeExternalReplication?api-version=$api_version"

# Get the token for authentication and create the headers containing it
$secureString = (Get-AzAccessToken).Token
$ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
$headers = @{"Authorization"= "Bearer $token"}

# Create the JSON containing the body for the first request creating the migration volume on ANF
# Note that this example creates an NSF volume, it is also possible to create a SMB or dual protocol volume 
# Details can be found in the API documentation: https://learn.microsoft.com/en-us/rest/api/netapp/volumes/create-or-update?view=rest-netapp-2025-03-01&tabs=HTTP#request-body
$request_body_template_json_volume = @"
{
    "type":"Microsoft.NetApp/netAppAccounts/capacityPools/volumes",
       "location":"<azure region placeholder>",
       "properties":{
				 "volumeType":"Migration", 
				 "dataProtection":{ 
					 "replication":{ 
							"endpointType":"Dst", 
							"replicationSchedule":"Hourly", 
							"remotePath":{ 
								"externalHostName":"< cluster name placeholder>", 
								"serverName":"<svm_name_placeholder>", 
								"volumeName":"<local vol name placeholder>"
									}
					 }
				},
          "serviceLevel":"Standard",
          "creationToken":"<vol_name_placeholder>",
          "usageThreshold": 0,
          "exportPolicy":{
             "rules":[
                {
                   "ruleIndex":1,
                   "unixReadOnly":false,
                   "unixReadWrite":true,
                   "cifs":false,
                   "nfsv3":true,
                   "nfsv41":false,
                   "allowedClients":"0.0.0.0/0",
                   "kerberos5ReadOnly":false,
                   "kerberos5ReadWrite":false,
                   "kerberos5iReadOnly":false,
                   "kerberos5iReadWrite":false,
                   "kerberos5pReadOnly":false,
                   "kerberos5pReadWrite":false,
                   "hasRootAccess":true
                }
             ]
          },
          "protocolTypes":[
             "NFSv3"
          ],
          "subnetId":"<delegated subnet azure id placeholder>",
          "networkFeatures":"Standard",
          "isLargeVolume":"false"
       }
    }
"@

# Convert the JSON to a PowerShell custom object 
$request_body_template_volume = $request_body_template_json_volume | convertfrom-json 

# Set the variables as were filled in above
$request_body_template_volume.properties.subnetId = $subnet_id
$request_body_template_volume.properties.dataProtection.replication.remotePath.externalHostName = $on_premises_cluster_name
$request_body_template_volume.properties.dataProtection.replication.remotePath.serverName = $on_premises_svm
$request_body_template_volume.properties.dataProtection.replication.remotePath.volumeName = $on_premises_volume_name
$request_body_template_volume.properties.creationToken = $migration_volume_name
$request_body_template_volume.properties.usageThreshold = $volume_size_bytes
$request_body_template_volume.location = $location

# Convert the PowerShell custom object back to json
$request_body_volume_json = $request_body_template_volume | ConvertTo-Json -Depth 99 

# Send the request to create a migration volume on ANF
Write-Host "Sending new ANF migration volume creation request"
$request_put_migration_volume = Invoke-WebRequest -Method Put -Headers $headers -Body $request_body_volume_json -Uri $url_volume -ContentType "application/json"
$volume_put_correlation_id = $request_put_migration_volume.Headers.'x-ms-correlation-request-id'

# Wait for volume to be successfully created
$volume_create_request_async = Invoke-WebRequest -Uri $request_put_migration_volume.Headers.'Azure-AsyncOperation' -Headers $headers -Method Get
$volume_create_request_ps_custom_object = $volume_create_request_async.Content | ConvertFrom-Json
$volume_status = $volume_create_request_ps_custom_object.status

while ($volume_status -ne "Succeeded"){
    Write-Host "Waiting for migration volume to be created in ANF"
    Write-Host "Current status: ${volume_status}"
    Write-Host "Correlation ID: ${volume_put_correlation_id}"
    if($volume_status -eq "Failed"){
        Write-Host "Error creating volume."
        $volume_create_request_ps_custom_object
        throw "Error creating volume."
    }
    Write-Host "Waiting 30s"
    Start-Sleep -Seconds 30
    $volume_create_request_async = Invoke-WebRequest -Uri $request_put_migration_volume.Headers.'Azure-AsyncOperation' -Headers $headers -Method Get
    $volume_create_request_ps_custom_object = $volume_create_request_async.Content | ConvertFrom-Json
    $volume_status = $volume_create_request_ps_custom_object.status
}

Write-Host "ANF volume creation succeeded. Continuing with next operation to peer the clusters."

# Create the body of the peerExternalCluster request 
$request_body_peer_external_cluster = New-Object -TypeName PSCustomObject -Property @{"PeerClusterName"=$on_premises_cluster_name; "PeerAddresses"=$lifs}
$request_body_peer_external_cluster_json = $request_body_peer_external_cluster | ConvertTo-Json -Depth 99 -Compress

Write-Host "Sending ANF cluster peer request now. You will need to locally peer when this completes."
$request_peer_external_cluster =  Invoke-WebRequest -Method Post -Headers $headers -Body $request_body_peer_external_cluster_json -Uri $url_peer_external_cluster -ContentType "application/json"
$peer_external_correlation_id = $request_peer_external_cluster.Headers.'x-ms-correlation-request-id'

# Wait for the ANF cluster peering to succeed
$request_peer_external_cluster_async = Invoke-WebRequest -Uri $request_peer_external_cluster.Headers.'Azure-AsyncOperation' -Method Get -Headers $headers
$request_peer_external_cluster_async_json = $request_peer_external_cluster_async.Content | ConvertFrom-Json

while ($request_peer_external_cluster_async_json.status -ne "Succeeded"){
    $peer_external_cluster_status = $request_peer_external_cluster_async_json.status
    Write-Host "Waiting on Azure cluster peering. Creating NICs in delegated subnet and preparing the stamp, etc.."
    Write-Host "Current status: $peer_external_cluster_status"
    Write-Host "Correlation ID: ${peer_external_correlation_id}"
    if($peer_external_cluster_status -eq "Failed"){
        Write-Host "Error peering clusters."
        $request_peer_external_cluster_async_json
        throw "Error peering clusters."
    }
    Write-Host "Sleeping 30"
    Start-Sleep -Seconds 30
    $request_peer_external_cluster_async = Invoke-WebRequest -Uri $request_peer_external_cluster.Headers.'Azure-AsyncOperation' -Method Get -Headers $headers
    $request_peer_external_cluster_async_json = $request_peer_external_cluster_async.Content | ConvertFrom-Json
}

# Inform about local cluster peering step to be executed manually on-premises
$peerCommand = $request_peer_external_cluster_async_json.properties.clusterPeeringCommand
$passphrase = $request_peer_external_cluster_async_json.properties.passphrase

if ([string]::IsNullOrEmpty($peerCommand)) {
    Write-Host "Azure peering is complete."
    Write-Host "No cluster-peering command was returned, so no local peering step is required."
    Read-Host -Prompt "Press <enter> to continue"
}
else {
    Write-Host "Azure peering complete."
    Write-Host "Local peering command (replace <IP-SPACE-NAME> with your ipspace name):"
    Write-Host $peerCommand
    Write-Host "Passphrase: $passphrase"
    Write-Host ""
    Write-Host "Wait for 'cluster peer show' to report Ready."
    Write-Host ""
    Read-Host -Prompt "Press <enter> when the local cluster has peered correctly to continue"
}

# Send the request to authorize the replication from the migration volume on ANF
Write-Host "Sending the command to start the replication between the volumes now that the clusters are peered"
$request_post_authorize_external_replication = Invoke-WebRequest -Uri $url_authorize_external_replication -Method Post -Headers $headers
$authorize_replication_correlation_id = $request_post_authorize_external_replication.Headers.'x-ms-correlation-request-id'

# Wait for the replication operation to succeed; we'll need to get back the SVM peer command from this step too
$request_authorize_external_replication_async = Invoke-WebRequest -Uri $request_post_authorize_external_replication.Headers.'Azure-AsyncOperation' -Method Get -Headers $headers
$request_authorize_external_replication_async_json = $request_authorize_external_replication_async.Content | ConvertFrom-Json
while ($request_authorize_external_replication_async_json.status -ne "Succeeded"){
    $authorize_replication_status = $request_authorize_external_replication_async_json.status
    Write-Host "Waiting on authorize external replication"
    Write-Host "Current status: $authorize_replication_status"
    Write-Host "Correlation ID: ${authorize_replication_correlation_id}"
    if($authorize_replication_status -eq "Failed"){
        Write-Host "Error creating vserver peering."
        $request_authorize_external_replication_async_json
        throw "Error creating vserver peering."
    }
    Write-Host "Sleeping 30"
    Start-Sleep -Seconds 30
    $request_authorize_external_replication_async = Invoke-WebRequest -Uri $request_post_authorize_external_replication.Headers.'Azure-AsyncOperation' -Method Get -Headers $headers
    $request_authorize_external_replication_async_json = $request_authorize_external_replication_async.Content | ConvertFrom-Json
}
$request_authorize_external_replication_async_json.status
$request_authorize_external_replication_async_json.percentComplete
$request_authorize_external_replication_async_json.endTime
$svmPeeringCommand = $request_authorize_external_replication_async_json.properties.svmPeeringCommand

# Inform about local cluster peering command to be executed manually on-premises
Write-Host "Complete local SVM peering with this command: ${svmPeeringCommand}"

# Ensure the token is not left in memory
$token = [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
