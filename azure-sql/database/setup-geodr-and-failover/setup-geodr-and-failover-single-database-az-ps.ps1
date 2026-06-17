# <FullScript>
# Connect-AzAccount
$subscriptionId = "<Subscription-ID>"
# Set the resource group name and location for your primary server
$primaryResourceGroupName = "myPrimaryResourceGroup-$(Get-Random)"
$primaryLocation = "westus2"
# Set the resource group name and location for your secondary server
$secondaryResourceGroupName = "mySecondaryResourceGroup-$(Get-Random)"
$secondaryLocation = "eastus"
# Set an admin login and password for your servers
$adminSqlLogin = "<admin>"
$password = "<password>"
# Set server names - the logical server names have to be unique in the system
$primaryServerName = "primary-server-$(Get-Random)"
$secondaryServerName = "secondary-server-$(Get-Random)"
# The sample database name
$databaseName = "mySampleDatabase"
# The IP address range that you want to allow to access your servers
$primaryStartIp = "0.0.0.0"
$primaryEndIp = "0.0.0.0"
$secondaryStartIp = "0.0.0.0"
$secondaryEndIp = "0.0.0.0"

# Set subscription
Set-AzContext -SubscriptionId $subscriptionId

# Create two new resource groups
$primaryResourceGroup = New-AzResourceGroup -Name $primaryResourceGroupName -Location $primaryLocation
$secondaryResourceGroup = New-AzResourceGroup -Name $secondaryResourceGroupName -Location $secondaryLocation

# Create two new logical servers with a system-wide unique server name
$adminCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $adminSqlLogin, $(ConvertTo-SecureString -String $password -AsPlainText -Force)

$primaryServerParams = @{
    ResourceGroupName           = $primaryResourceGroupName
    ServerName                  = $primaryServerName
    Location                    = $primaryLocation
    SqlAdministratorCredentials = $adminCredential
}
$primaryServer = New-AzSqlServer @primaryServerParams

$secondaryServerParams = @{
    ResourceGroupName           = $secondaryResourceGroupName
    ServerName                  = $secondaryServerName
    Location                    = $secondaryLocation
    SqlAdministratorCredentials = $adminCredential
}
$secondaryServer = New-AzSqlServer @secondaryServerParams

# Create a server firewall rule for each server that allows access from the specified IP range
$primaryFirewallParams = @{
    ResourceGroupName = $primaryResourceGroupName
    ServerName        = $primaryServerName
    FirewallRuleName  = "AllowedIPs"
    StartIpAddress    = $primaryStartIp
    EndIpAddress      = $primaryEndIp
}
$primaryServerFirewallRule = New-AzSqlServerFirewallRule @primaryFirewallParams

$secondaryFirewallParams = @{
    ResourceGroupName = $secondaryResourceGroupName
    ServerName        = $secondaryServerName
    FirewallRuleName  = "AllowedIPs"
    StartIpAddress    = $secondaryStartIp
    EndIpAddress      = $secondaryEndIp
}
$secondaryServerFirewallRule = New-AzSqlServerFirewallRule @secondaryFirewallParams

# Create a blank database with S0 performance level on the primary server
$databaseParams = @{
    ResourceGroupName             = $primaryResourceGroupName
    ServerName                    = $primaryServerName
    DatabaseName                  = $databaseName
    RequestedServiceObjectiveName = "S0"
}
$database = New-AzSqlDatabase @databaseParams

# Establish Active Geo-Replication
$database = Get-AzSqlDatabase -DatabaseName $databaseName -ResourceGroupName $primaryResourceGroupName -ServerName $primaryServerName
$database | New-AzSqlDatabaseSecondary -PartnerResourceGroupName $secondaryResourceGroupName -PartnerServerName $secondaryServerName -AllowConnections "All"

# Initiate a planned failover
$database = Get-AzSqlDatabase -DatabaseName $databaseName -ResourceGroupName $secondaryResourceGroupName -ServerName $secondaryServerName
$database | Set-AzSqlDatabaseSecondary -PartnerResourceGroupName $primaryResourceGroupName -Failover

# Monitor Geo-Replication config and health after failover
$database = Get-AzSqlDatabase -DatabaseName $databaseName -ResourceGroupName $secondaryResourceGroupName -ServerName $secondaryServerName
$database | Get-AzSqlDatabaseReplicationLink -PartnerResourceGroupName $primaryResourceGroupName -PartnerServerName $primaryServerName

# Remove the replication link after the failover
$database = Get-AzSqlDatabase -DatabaseName $databaseName -ResourceGroupName $secondaryResourceGroupName -ServerName $secondaryServerName
$secondaryLink = $database | Get-AzSqlDatabaseReplicationLink -PartnerResourceGroupName $primaryResourceGroupName -PartnerServerName $primaryServerName
$secondaryLink | Remove-AzSqlDatabaseSecondary

# Clean up deployment
#Remove-AzResourceGroup -ResourceGroupName $primaryResourceGroupName
#Remove-AzResourceGroup -ResourceGroupName $secondaryResourceGroupName
# </FullScript>
