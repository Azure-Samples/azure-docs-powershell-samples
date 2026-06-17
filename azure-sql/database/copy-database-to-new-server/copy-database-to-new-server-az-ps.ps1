# <FullScript>
# Connect-AzAccount
# The SubscriptionId in which to create these objects
$subscriptionId = "<Subscription-ID>"
# Set the resource group name and location for your source server
$sourceResourceGroupName = "mySourceResourceGroup-$(Get-Random)"
$sourceResourceGroupLocation = "westus2"
# Set the resource group name and location for your target server
$targetResourceGroupName = "myTargetResourceGroup-$(Get-Random)"
$targetResourceGroupLocation = "eastus"
# Set an admin login and password for your server
$adminSqlLogin = "<admin>"
$password = "<password>"
# The logical server names have to be unique in the system
$sourceServerName = "source-server-$(Get-Random)"
$targetServerName = "target-server-$(Get-Random)"
# The sample database name
$sourceDatabaseName = "mySampleDatabase"
$targetDatabaseName = "CopyOfMySampleDatabase"
# The IP address range that you want to allow to access your servers
$sourceStartIp = "0.0.0.0"
$sourceEndIp = "0.0.0.0"
$targetStartIp = "0.0.0.0"
$targetEndIp = "0.0.0.0"

# Set subscription
Set-AzContext -SubscriptionId $subscriptionId

# Create two new resource groups
$sourceResourceGroup = New-AzResourceGroup -Name $sourceResourceGroupName -Location $sourceResourceGroupLocation
$targetResourceGroup = New-AzResourceGroup -Name $targetResourceGroupName -Location $targetResourceGroupLocation

# Build the SQL administrator credential reused for both servers
$adminCredential = New-Object -TypeName System.Management.Automation.PSCredential `
    -ArgumentList $adminSqlLogin, (ConvertTo-SecureString -String $password -AsPlainText -Force)

# Create a server with a system-wide unique server name
$sourceServerParams = @{
    ResourceGroupName           = $sourceResourceGroupName
    ServerName                  = $sourceServerName
    Location                    = $sourceResourceGroupLocation
    SqlAdministratorCredentials = $adminCredential
}
$sourceResourceGroup = New-AzSqlServer @sourceServerParams
$targetServerParams = @{
    ResourceGroupName           = $targetResourceGroupName
    ServerName                  = $targetServerName
    Location                    = $targetResourceGroupLocation
    SqlAdministratorCredentials = $adminCredential
}
$targetResourceGroup = New-AzSqlServer @targetServerParams

# Create a server firewall rule that allows access from the specified IP range
$sourceFirewallParams = @{
    ResourceGroupName = $sourceResourceGroupName
    ServerName        = $sourceServerName
    FirewallRuleName  = "AllowedIPs"
    StartIpAddress    = $sourceStartIp
    EndIpAddress      = $sourceEndIp
}
$sourceServerFirewallRule = New-AzSqlServerFirewallRule @sourceFirewallParams
$targetFirewallParams = @{
    ResourceGroupName = $targetResourceGroupName
    ServerName        = $targetServerName
    FirewallRuleName  = "AllowedIPs"
    StartIpAddress    = $targetStartIp
    EndIpAddress      = $targetEndIp
}
$targetServerFirewallRule = New-AzSqlServerFirewallRule @targetFirewallParams

# Create a blank database in the source-server with an S0 performance level
$sourceDatabaseParams = @{
    ResourceGroupName             = $sourceResourceGroupName
    ServerName                    = $sourceServerName
    DatabaseName                  = $sourceDatabaseName
    RequestedServiceObjectiveName = "S0"
}
$sourceDatabase = New-AzSqlDatabase @sourceDatabaseParams

# Copy source database to the target server
$databaseCopyParams = @{
    ResourceGroupName     = $sourceResourceGroupName
    ServerName            = $sourceServerName
    DatabaseName          = $sourceDatabaseName
    CopyResourceGroupName = $targetResourceGroupName
    CopyServerName        = $targetServerName
    CopyDatabaseName      = $targetDatabaseName
}
$databaseCopy = New-AzSqlDatabaseCopy @databaseCopyParams

# Clean up deployment
# Remove-AzResourceGroup -ResourceGroupName $sourceResourceGroupName
# Remove-AzResourceGroup -ResourceGroupName $targetResourceGroupName
# </FullScript>
