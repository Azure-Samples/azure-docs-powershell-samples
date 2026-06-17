# <FullScript>
# Set variables for your server and database
$subscriptionId = '<Subscription-ID>'
$randomIdentifier = $(Get-Random)
$resourceGroupName = "myResourceGroup-$randomIdentifier"
$location = "East US"
$adminLogin = "<admin>"
$password = "<password>"
$serverName = "mysqlserver-$randomIdentifier"
$poolName = "myElasticPool"
$databaseName = "mySampleDatabase"
$drLocation = "West US"
$drServerName = "mysqlsecondary-$randomIdentifier"
$failoverGroupName = "failovergrouptutorial-$randomIdentifier"

# The IP address range that you want to allow to access your server
# Leaving at 0.0.0.0 will prevent outside-of-Azure connections
$startIp = "0.0.0.0"
$endIp = "0.0.0.0"

# Show randomized variables
Write-Host "Resource group name is" $resourceGroupName
Write-Host "Password is" $password
Write-Host "Server name is" $serverName
Write-Host "DR Server name is" $drServerName
Write-Host "Failover group name is" $failoverGroupName

# Set subscription ID
Set-AzContext -SubscriptionId $subscriptionId

# Create a resource group
Write-Host "Creating resource group..."
$resourceGroupParams = @{
   Name     = $resourceGroupName
   Location = $location
   Tag      = @{Owner = "SQLDB-Samples" }
}
$resourceGroup = New-AzResourceGroup @resourceGroupParams
$resourceGroup

# Build the SQL administrator credential reused for both servers
$adminCredential = New-Object -TypeName System.Management.Automation.PSCredential `
   -ArgumentList $adminLogin, (ConvertTo-SecureString -String $password -AsPlainText -Force)

# Create a server with a system-wide unique server name
Write-Host "Creating primary logical server..."
$primaryServerParams = @{
   ResourceGroupName           = $resourceGroupName
   ServerName                  = $serverName
   Location                    = $location
   SqlAdministratorCredentials = $adminCredential
}
New-AzSqlServer @primaryServerParams
Write-Host "Primary logical server = " $serverName

# Create a server firewall rule that allows access from the specified IP range
Write-Host "Configuring firewall for primary logical server..."
$primaryFirewallParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $serverName
   FirewallRuleName  = "AllowedIPs"
   StartIpAddress    = $startIp
   EndIpAddress      = $endIp
}
New-AzSqlServerFirewallRule @primaryFirewallParams
Write-Host "Firewall configured"

# Create General Purpose Gen5 database with 2 vCore
Write-Host "Creating a gen5 2 vCore database..."
$databaseParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $serverName
   DatabaseName      = $databaseName
   Edition           = "GeneralPurpose"
   VCore             = 2
   ComputeGeneration = "Gen5"
   MinimumCapacity   = 1
   SampleName        = "AdventureWorksLT"
}
$database = New-AzSqlDatabase @databaseParams
$database

# Create primary Gen5 elastic 2 vCore pool
Write-Host "Creating elastic pool..."
$primaryPoolParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $serverName
   ElasticPoolName   = $poolName
   Edition           = "GeneralPurpose"
   VCore             = 2
   ComputeGeneration = "Gen5"
}
$elasticPool = New-AzSqlElasticPool @primaryPoolParams
$elasticPool

# Add single database into elastic pool
Write-Host "Creating elastic pool..."
$addDatabaseParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $serverName
   DatabaseName      = $databaseName
   ElasticPoolName   = $poolName
}
$addDatabase = Set-AzSqlDatabase @addDatabaseParams
$addDatabase

# Create a secondary server in the failover region
Write-Host "Creating a secondary logical server in the failover region..."
$secondaryServerParams = @{
   ResourceGroupName           = $resourceGroupName
   ServerName                  = $drServerName
   Location                    = $drLocation
   SqlAdministratorCredentials = $adminCredential
}
New-AzSqlServer @secondaryServerParams
Write-Host "Secondary logical server =" $drServerName

# Create a server firewall rule that allows access from the specified IP range
Write-Host "Configuring firewall for secondary logical server..."
$secondaryFirewallParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $drServerName
   FirewallRuleName  = "AllowedIPs"
   StartIpAddress    = $startIp
   EndIpAddress      = $endIp
}
New-AzSqlServerFirewallRule @secondaryFirewallParams
Write-Host "Firewall configured"

# Create secondary Gen5 elastic 2 vCore pool
Write-Host "Creating secondary elastic pool..."
$secondaryPoolParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $drServerName
   ElasticPoolName   = $poolName
   Edition           = "GeneralPurpose"
   VCore             = 2
   ComputeGeneration = "Gen5"
}
$elasticPool = New-AzSqlElasticPool @secondaryPoolParams
$elasticPool

# Create a failover group between the servers
Write-Host "Creating failover group..."
$failoverGroupParams = @{
   ResourceGroupName            = $resourceGroupName
   ServerName                   = $serverName
   PartnerServerName            = $drServerName
   FailoverGroupName            = $failoverGroupName
   FailoverPolicy               = "Automatic"
   GracePeriodWithDataLossHours = 2
}
New-AzSqlDatabaseFailoverGroup @failoverGroupParams
Write-Host "Failover group created successfully."

# Add elastic pool to the failover group
Write-Host "Enumerating databases in elastic pool...."
$getFailoverGroupParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $serverName
   FailoverGroupName = $failoverGroupName
}
$failoverGroup = Get-AzSqlDatabaseFailoverGroup @getFailoverGroupParams
$poolDatabaseParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $serverName
   ElasticPoolName   = $poolName
}
$databases = Get-AzSqlElasticPoolDatabase @poolDatabaseParams
Write-Host "Adding databases to failover group..."
$failoverGroup = $failoverGroup | Add-AzSqlDatabaseToFailoverGroup -Database $databases
$failoverGroup

# Check role of secondary replica
Write-Host "Confirming the secondary server is secondary...."
$secondaryRoleParams = @{
   FailoverGroupName = $failoverGroupName
   ResourceGroupName = $resourceGroupName
   ServerName        = $drServerName
}
(Get-AzSqlDatabaseFailoverGroup @secondaryRoleParams).ReplicationRole

# Failover to secondary server
Write-Host "Failing over failover group to the secondary..."
$switchToSecondaryParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $drServerName
   FailoverGroupName = $failoverGroupName
}
Switch-AzSqlDatabaseFailoverGroup @switchToSecondaryParams
Write-Host "Failover group failed over to" $drServerName

# Check role of secondary replica
Write-Host "Confirming the secondary server is now primary"
(Get-AzSqlDatabaseFailoverGroup @secondaryRoleParams).ReplicationRole

# Revert failover to primary server
Write-Host "Failing over failover group to the primary...."
$switchToPrimaryParams = @{
   ResourceGroupName = $resourceGroupName
   ServerName        = $serverName
   FailoverGroupName = $failoverGroupName
}
Switch-AzSqlDatabaseFailoverGroup @switchToPrimaryParams
Write-Host "Failover group failed over to" $serverName

# Clean up resources by removing the resource group
# Write-Host "Removing resource group..."
# Remove-AzResourceGroup -ResourceGroupName $resourceGroupName
# Write-Host "Resource group removed =" $resourceGroupName
# </FullScript>
