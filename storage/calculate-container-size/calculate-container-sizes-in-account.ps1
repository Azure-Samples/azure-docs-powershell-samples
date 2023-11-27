<#
.SYNOPSIS
Calculates the total size of blobs in all containers in a specified Azure storage account.

.DESCRIPTION
Before running this script, ensure you have:
- A storage account created
- At least one container in the storage account
- Uploaded some blobs into the container

.EXAMPLE
.\Get-AzureStorageAccountBlobSize.ps1 -StorageAccountName mystorageaccount -ResourceGroupName myResourceGroup

.NOTES
This script incurs transactional costs for Azure requests.
#>

[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName = '<name-of-your-resource-group>',
    
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccountName = '<name-of-your-storage-account>'
)

$containerstats = @()

# Get a reference to the storage account and the context.
$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$Ctx = $storageAccount.Context

$container_continuation_token = $null
do {
  $containers = Get-AzStorageContainer -Context $Ctx -MaxCount 5000 -ContinuationToken $container_continuation_token    
  $container_continuation_token = $null

  if ($containers -ne $null) {
    $container_continuation_token = $containers[$containers.Count - 1].ContinuationToken
    
    for ([int] $c = 0; $c -lt $containers.Count; $c++) {
      $container = $containers[$c].Name
      Write-Verbose "Processing container : $container"
      $total_usage = 0
      $total_blob_count = 0
      $soft_delete_usage = 0
      $soft_delete_count = 0
      $version_usage = 0
      $version_count = 
      $snapshot_count = 0 
      $snapshot_usage = 0
      $blob_continuation_token = $null
      
      do {
        $blobs = Get-AzStorageBlob -Context $Ctx -IncludeDeleted -IncludeVersion -Container $container -ConcurrentTaskCount 100 -MaxCount 5000 -ContinuationToken $blob_continuation_token
        $blob_continuation_token = $null
        
        if ($blobs -ne $null) {
          $blob_continuation_token = $blobs[$blobs.Count - 1].ContinuationToken
          
          for ([int] $b = 0; $b -lt $blobs.Count; $b++) {
            $total_blob_count++
            $total_usage += $blobs[$b].Length
            
            if ($blobs[$b].IsDeleted)
            {
              $soft_delete_count++
              $soft_delete_usage += $blobs[$b].Length
            }
            
            if ($blobs[$b].SnapshotTime -ne $null) {
              $snapshot_count++
              $snapshot_usage+= $blobs[$b].Length
            }
            
            if ($blobs[$b].VersionId -ne $null) {
              $version_count++
              $version_usage += $blobs[$b].Length
            }
          }
          
          if ($blob_continuation_token -ne $null) {
            Write-Verbose "Blob listing continuation token = {0}".Replace("{0}",$blob_continuation_token.NextMarker)
          }
        }
      } while ($blob_continuation_token -ne $null)
      
      Write-Verbose "Calculated size of $container = $total_usage with soft_delete usage of $soft_delete_usage"
      $containerstats += [PSCustomObject] @{ 
        Name = $container 
        TotalBlobCount = $total_blob_count 
        TotalBlobUsageinGB = $total_usage/1GB
        SoftDeletedBlobCount = $soft_delete_count
        SoftDeletedBlobUsageinGB = $soft_delete_usage/1GB
	SnapshotCount = $snapshot_count
	SnapshotUsageinGB = $snapshot_usage/1GB
	VersionCount = $version_count
	VersionUsageinGB = $version_usage/1GB
      }
    }
  }
  
  if ($container_continuation_token -ne $null) {
    Write-Verbose "Container listing continuation token = {0}".Replace("{0}",$container_continuation_token.NextMarker)
  }
} while ($container_continuation_token -ne $null)

Write-Host "Total container stats"
$containerstats | Format-Table -AutoSize