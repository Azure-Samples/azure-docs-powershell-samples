# <FullScript>
# You will need an existing Managed Instance as a prerequisite for completing this script.
# See https://docs.microsoft.com/en-us/azure/sql-database/scripts/sql-database-create-configure-managed-instance-powershell

# Log in to your Azure account:
Connect-AzAccount

# If there are multiple subscriptions, choose the one where AKV is created:
Set-AzContext -SubscriptionId "<Subscription-ID>"

# Install the Az.Sql PowerShell package if you are running this PowerShell locally (uncomment below):
# Install-Module -Name Az.Sql

# 1. Create resource and set up Azure Key Vault (skip if already done)

# Create resource group (name the resource and specify the location)
$location = "westus2" # specify the location
$resourcegroup = "MyRG" # specify a new RG name
New-AzResourceGroup -Name $resourcegroup -Location $location

# Create new Azure Key Vault with a globally unique VaultName and soft-delete option turned on:
$vaultname = "MyKeyVault" # specify a globally unique VaultName
New-AzKeyVault -VaultName $vaultname -ResourceGroupName $resourcegroup -Location $location

# Authorize Managed Instance to use the AKV (wrap/unwrap key and get public part of key, if public part exists):
$assignIdentityParams = @{
    ResourceGroupName = $resourcegroup
    Name              = "MyManagedInstance"
    AssignIdentity    = $true
}
$objectid = (Set-AzSqlInstance @assignIdentityParams).Identity.PrincipalId
$accessPolicyParams = @{
    BypassObjectIdValidation = $true
    VaultName                = $vaultname
    ObjectId                 = $objectid
    PermissionsToKeys        = "get", "wrapKey", "unwrapKey"
}
Set-AzKeyVaultAccessPolicy @accessPolicyParams

# Allow access from trusted Azure services:
Update-AzKeyVaultNetworkRuleSet -VaultName $vaultname -Bypass AzureServices

# Allow access from your client IP address(es) to be able to complete remaining steps:
Update-AzKeyVaultNetworkRuleSet -VaultName $vaultname -IpAddressRange "<IP-address-range>"

# Turn the network rules ON by setting the default action to Deny:
Update-AzKeyVaultNetworkRuleSet -VaultName $vaultname -DefaultAction Deny

# 2. Provide TDE Protector key (skip if already done)

# First, give yourself necessary permissions on the AKV, (specify your account instead of contoso.com):
$selfAccessPolicyParams = @{
    VaultName         = $vaultname
    UserPrincipalName = "myaccount@contoso.com"
    PermissionsToKeys = "create", "import", "get", "list"
}
Set-AzKeyVaultAccessPolicy @selfAccessPolicyParams

# The recommended way is to import an existing key from a .pfx file. Replace "<PFX private key password>" with the actual password below:
$keypath = "c:\some_path\mytdekey.pfx" # Supply your .pfx path and name
$securepfxpwd = ConvertTo-SecureString -String "<PFX private key password>" -AsPlainText -Force
$addKeyParams = @{
    VaultName       = $vaultname
    Name            = "MyTDEKey"
    KeyFilePath     = $keypath
    KeyFilePassword = $securepfxpwd
}
$key = Add-AzKeyVaultKey @addKeyParams

# ...or get an existing key from the vault:
# $key = Get-AzKeyVaultKey -VaultName $vaultname -Name "MyTDEKey"

# Alternatively, generate a new key directly in Azure Key Vault (recommended for test purposes only - uncomment below):
# $key = Add-AzureKeyVaultKey -VaultName $vaultname -Name MyTDEKey -Destination Software -Size 2048

# 3. Set up BYOK TDE on Managed Instance:

# Assign the key to the Managed Instance:
# $key = 'https://contoso.vault.azure.net/keys/contosokey/<key>'
Add-AzSqlInstanceKeyVaultKey -KeyId $key.id -InstanceName "MyManagedInstance" -ResourceGroupName $resourcegroup

# Set TDE operation mode to BYOK:
$tdeProtectorParams = @{
    Type          = "AzureKeyVault"
    InstanceName  = "MyManagedInstance"
    ResourceGroup = $resourcegroup
    KeyId         = $key.id
}
Set-AzSqlInstanceTransparentDataEncryptionProtector @tdeProtectorParams
# </FullScript>
