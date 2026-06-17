# <FullScript>
# Connect-AzAccount
# The SubscriptionId in which to create these objects
$subscriptionId = "<Subscription-ID>"
# Set the resource group name and location for your server
$resourceGroupName = "myResourceGroup-$(Get-Random)"
$location = "westus2"
# Set an admin login and password for your server
$adminSqlLogin = "<admin>"
$password = "<password>"
# Set server name - the logical server name has to be unique in the system
$serverName = "server-$(Get-Random)"
# The sample database name
$databaseName = "mySampleDatabase"
# The IP address range that you want to allow to access your server
$startIp = "0.0.0.0"
$endIp = "0.0.0.0"

# Set subscription
Set-AzContext -SubscriptionId $subscriptionId

# Create a resource group
$resourceGroup = New-AzResourceGroup -Name $resourceGroupName -Location $location

# Create a credential for the server admin
$adminCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $adminSqlLogin, $(ConvertTo-SecureString -String $password -AsPlainText -Force)

# Create a server with a system-wide unique server name
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

# Create a blank database with an S0 performance level
$databaseParams = @{
    ResourceGroupName            = $resourceGroupName
    ServerName                   = $serverName
    DatabaseName                 = $databaseName
    RequestedServiceObjectiveName = "S0"
    SampleName                   = "AdventureWorksLT"
}
$database = New-AzSqlDatabase @databaseParams

# Clean up deployment
# Remove-AzResourceGroup -ResourceGroupName $resourceGroupName
# </FullScript>
