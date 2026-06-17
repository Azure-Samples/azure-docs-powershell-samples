# <FullScript>
# Connect-AzAccount
# The SubscriptionId in which to create these objects
$subscriptionId = "<Subscription-ID>"
# Set the resource group name and location for your server
$resourceGroupName = "myResourceGroup-$(Get-Random)"
$location = "westeurope"
# Set an admin login and password for your server
$adminSqlLogin = "<admin>"
$password = "<password>"
# Set server name - the logical server name has to be unique in the system
$serverName = "server-$(Get-Random)"
# The sample database name
$databaseName = "myImportedDatabase"
# The storage account name and storage container name
$storageAccountName = "sqlimport$(Get-Random)"
$storageContainerName = "importcontainer$(Get-Random)"
# BACPAC file name
$bacpacFilename = "sample.bacpac"
# The IP address range that you want to allow to access your server
$startIp = "0.0.0.0"
$endIp = "0.0.0.0"

# Set subscription
Set-AzContext -SubscriptionId $subscriptionId

# Create a resource group
$resourceGroup = New-AzResourceGroup -Name $resourceGroupName -Location $location

# Create a storage account
$storageAccountParams = @{
    ResourceGroupName = $resourceGroupName
    Name              = $storageAccountName
    Location          = $location
    SkuName           = "Standard_LRS"
}
$storageAccount = New-AzStorageAccount @storageAccountParams

# Create a storage context for the storage account
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName).Value[0]
$storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey

# Create a storage container
$storageContainer = New-AzStorageContainer -Name $storageContainerName -Context $storageContext

# Download sample database from GitHub
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 #required by GitHub
Invoke-WebRequest -Uri "https://github.com/Microsoft/sql-server-samples/releases/download/wide-world-importers-v1.0/WideWorldImporters-Standard.bacpac" -OutFile $bacpacFilename

# Upload sample database into storage container
$blobContentParams = @{
    Container = $storageContainerName
    File      = $bacpacFilename
    Context   = $storageContext
}
Set-AzStorageBlobContent @blobContentParams

# Create a credential for the server admin
$adminCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $adminSqlLogin, $(ConvertTo-SecureString -String $password -AsPlainText -Force)

# Create a new server with a system-wide unique server name
$serverParams = @{
    ResourceGroupName           = $resourceGroupName
    ServerName                  = $serverName
    Location                    = $location
    SqlAdministratorCredentials = $adminCredential
}
$server = New-AzSqlServer @serverParams

# Create a server firewall rule that allows access from the specified IP range
$firewallParams = @{
    ResourceGroupName = $resourceGroupName
    ServerName        = $serverName
    FirewallRuleName  = "AllowedIPs"
    StartIpAddress    = $startIp
    EndIpAddress      = $endIp
}
$serverFirewallRule = New-AzSqlServerFirewallRule @firewallParams

# Import BACPAC to database with an S3 performance level
$importParams = @{
    ResourceGroupName          = $resourceGroupName
    ServerName                 = $serverName
    DatabaseName               = $databaseName
    DatabaseMaxSizeBytes       = 100GB
    StorageKeyType             = "StorageAccessKey"
    StorageKey                 = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -StorageAccountName $storageAccountName).Value[0]
    StorageUri                 = "https://$storageAccountName.blob.core.windows.net/$storageContainerName/$bacpacFilename"
    Edition                    = "Standard"
    ServiceObjectiveName       = "S3"
    AdministratorLogin         = "$adminSqlLogin"
    AdministratorLoginPassword = $(ConvertTo-SecureString -String $password -AsPlainText -Force)
}
$importRequest = New-AzSqlDatabaseImport @importParams

# Check import status and wait for the import to complete
$importStatus = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $importRequest.OperationStatusLink
[Console]::Write("Importing")
while ($importStatus.Status -eq "InProgress") {
    $importStatus = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $importRequest.OperationStatusLink
    [Console]::Write(".")
    Start-Sleep -s 10
}
[Console]::WriteLine("")
$importStatus

# Scale down to S0 after import is complete
$scaleDownParams = @{
    ResourceGroupName             = $resourceGroupName
    ServerName                    = $serverName
    DatabaseName                  = $databaseName
    Edition                       = "Standard"
    RequestedServiceObjectiveName = "S0"
}
Set-AzSqlDatabase @scaleDownParams

# Clean up deployment
# Remove-AzResourceGroup -ResourceGroupName $resourceGroupName
# </FullScript>
