# <FullScript>
# Connect-AzAccount
$subscriptionId = "<Subscription-ID>"
# Set the resource group name and location for your server
$primaryResourceGroupName = "myPrimaryResourceGroup-$(Get-Random)"
$secondaryResourceGroupName = "mySecondaryResourceGroup-$(Get-Random)"
$primaryLocation = "westus2"
$secondaryLocation = "eastus"
# The logical server names have to be unique in the system
$primaryServerName = "primary-server-$(Get-Random)"
$secondaryServerName = "secondary-server-$(Get-Random)"
# Set an admin login and password for your servers
$adminSqlLogin = "<admin>"
$password = "<password>"
# The sample database name
$databaseName = "mySampleDatabase"
# The IP address ranges that you want to allow to access your servers
$primaryStartIp = "0.0.0.0"
$primaryEndIp = "0.0.0.0"
$secondaryStartIp = "0.0.0.0"
$secondaryEndIp = "0.0.0.0"
# The elastic pool names
$primaryPoolName = "PrimaryPool"
$secondaryPoolName = "SecondaryPool"

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

# Create a pool in each of the servers
$primaryPoolParams = @{
    ResourceGroupName = $primaryResourceGroupName
    ServerName        = $primaryServerName
    ElasticPoolName   = $primaryPoolName
    Edition           = "Standard"
    Dtu               = 50
    DatabaseDtuMin    = 10
    DatabaseDtuMax    = 50
}
$primaryPool = New-AzSqlElasticPool @primaryPoolParams

$secondaryPoolParams = @{
    ResourceGroupName = $secondaryResourceGroupName
    ServerName        = $secondaryServerName
    ElasticPoolName   = $secondaryPoolName
    Edition           = "Standard"
    Dtu               = 50
    DatabaseDtuMin    = 10
    DatabaseDtuMax    = 50
}
$secondaryPool = New-AzSqlElasticPool @secondaryPoolParams

# Create a blank database in the pool on the primary server
$databaseParams = @{
    ResourceGroupName = $primaryResourceGroupName
    ServerName        = $primaryServerName
    DatabaseName      = $databaseName
    ElasticPoolName   = $primaryPoolName
}
$database = New-AzSqlDatabase @databaseParams

# Establish Active Geo-Replication
$primaryDatabaseParams = @{
    ResourceGroupName = $primaryResourceGroupName
    ServerName        = $primaryServerName
    DatabaseName      = $databaseName
}
$database = Get-AzSqlDatabase @primaryDatabaseParams
$secondaryParams = @{
    PartnerResourceGroupName = $secondaryResourceGroupName
    PartnerServerName        = $secondaryServerName
    SecondaryElasticPoolName = $secondaryPoolName
    AllowConnections         = "All"
}
$database | New-AzSqlDatabaseSecondary @secondaryParams

# Initiate a planned failover
$secondaryDatabaseParams = @{
    ResourceGroupName = $secondaryResourceGroupName
    ServerName        = $secondaryServerName
    DatabaseName      = $databaseName
}
$database = Get-AzSqlDatabase @secondaryDatabaseParams
$database | Set-AzSqlDatabaseSecondary -PartnerResourceGroupName $primaryResourceGroupName -Failover

# Monitor Geo-Replication config and health after failover
$database = Get-AzSqlDatabase @secondaryDatabaseParams
$replicationLinkParams = @{
    PartnerResourceGroupName = $primaryResourceGroupName
    PartnerServerName        = $primaryServerName
}
$database | Get-AzSqlDatabaseReplicationLink @replicationLinkParams

# Clean up deployment
# Remove-AzResourceGroup -ResourceGroupName $primaryResourceGroupName
# Remove-AzResourceGroup -ResourceGroupName $secondaryResourceGroupName
# </FullScript>
