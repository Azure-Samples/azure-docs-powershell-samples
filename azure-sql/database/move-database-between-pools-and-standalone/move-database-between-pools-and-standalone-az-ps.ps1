# <FullScript>
# Connect-AzAccount
$subscriptionId = "<Subscription-ID>"
# Set the resource group name and location for your server
$resourceGroupName = "myResourceGroup-$(Get-Random)"
$location = "westus2"
# Set elastic pool names
$firstPoolName = "MyFirstPool"
$secondPoolName = "MySecondPool"
# Set an admin login and password for your server
$adminSqlLogin = "<admin>"
$password = "<password>"
# The logical server name has to be unique in the system
$serverName = "server-$(Get-Random)"
# The sample database names
$firstDatabaseName = "myFirstSampleDatabase"
$secondDatabaseName = "mySecondSampleDatabase"
# The IP address range that you want to allow to access your server
$startIp = "0.0.0.0"
$endIp = "0.0.0.0"

# Set subscription
Set-AzContext -SubscriptionId $subscriptionId

# Create a new resource group
$resourceGroup = New-AzResourceGroup -Name $resourceGroupName -Location $location

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

# Create two elastic database pools
$firstPoolParams = @{
    ResourceGroupName = $resourceGroupName
    ServerName        = $serverName
    ElasticPoolName   = $firstPoolName
    Edition           = "Standard"
    Dtu               = 50
    DatabaseDtuMin    = 10
    DatabaseDtuMax    = 20
}
$firstPool = New-AzSqlElasticPool @firstPoolParams
$secondPoolParams = @{
    ResourceGroupName = $resourceGroupName
    ServerName        = $serverName
    ElasticPoolName   = $secondPoolName
    Edition           = "Standard"
    Dtu               = 50
    DatabaseDtuMin    = 10
    DatabaseDtuMax    = 50
}
$secondPool = New-AzSqlElasticPool @secondPoolParams

# Create two blank databases in the first pool
$firstDatabaseParams = @{
    ResourceGroupName = $resourceGroupName
    ServerName        = $serverName
    DatabaseName      = $firstDatabaseName
    ElasticPoolName   = $firstPoolName
}
$firstDatabase = New-AzSqlDatabase @firstDatabaseParams
$secondDatabaseParams = @{
    ResourceGroupName = $resourceGroupName
    ServerName        = $serverName
    DatabaseName      = $secondDatabaseName
    ElasticPoolName   = $secondPoolName
}
$secondDatabase = New-AzSqlDatabase @secondDatabaseParams

# Move the database to the second pool
$moveToPoolParams = @{
    ResourceGroupName = $resourceGroupName
    ServerName        = $serverName
    DatabaseName      = $firstDatabaseName
    ElasticPoolName   = $secondPoolName
}
$firstDatabase = Set-AzSqlDatabase @moveToPoolParams

# Move the database into a standalone performance level
$moveToStandaloneParams = @{
    ResourceGroupName             = $resourceGroupName
    ServerName                    = $serverName
    DatabaseName                  = $firstDatabaseName
    RequestedServiceObjectiveName = "S0"
}
$firstDatabase = Set-AzSqlDatabase @moveToStandaloneParams

# Clean up deployment
# Remove-AzResourceGroup -ResourceGroupName $resourceGroupName
# </FullScript>
