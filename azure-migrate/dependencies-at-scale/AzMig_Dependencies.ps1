New-Variable -Name vmWareMaxLimit -Value 3000 -Option Constant
New-Variable -Name hypervAndServerMaxLimit -Value 1000 -Option Constant

function GetRequestProperties() {

    $ErrorActionPreference = 'Stop'
    
    if(-not (Get-Module -Name Az.Accounts)) {
        Import-Module -Name Az.Accounts
    }
    
    if ((Get-Module -Name Az.Accounts).Version -lt "2.2.0") {
        throw "At least Az.Accounts 2.2.0 is required, please update before continuing."
    }
    
    $CurrentContext = Get-AzContext
    if (-not $CurrentContext) {
        throw "Not logged in. Use Connect-AzAccount to log in"
    }    
  
    $TenantId = $CurrentContext.Tenant.Id
    $UserId = $CurrentContext.Account.Id
    if ((-not $TenantId) -or (-not $UserId)) {
        throw "Tenant not selected. Use Set-AzContext to select a subscription"
    }

	$Environment = $CurrentContext.Environment.Name
	
    $SubscriptionId = $CurrentContext.Subscription.Id
    if (-not $SubscriptionId) {
        throw "Tenant not selected. Use Set-AzContext to select a subscription"
    }
	
	if($Environment -eq "AzureUSGovernment") {
		New-Variable -Name ResourceURL -Value "https://management.core.usgovcloudapi.net/" -Option Constant
	}
	else {
		New-Variable -Name ResourceURL -Value "https://management.core.windows.net/" -Option Constant
	}

    $Token = (Get-AzAccessToken -ResourceUrl $ResourceURL -TenantId $TenantId).Token
    if (-not $Token) {
        throw "Missing token, please make sure you are signed in."
    }

    $AuthorizationHeader = "Bearer " + $Token
    $Headers = [ordered]@{Accept = "application/json"; Authorization = $AuthorizationHeader} 
	
	if($Environment -eq "AzureUSGovernment") {
		$baseurl = "https://management.usgovcloudapi.net"
	}
	else {
		$baseurl = "https://management.azure.com" 
	}
    
    return [ordered]@{
        SubscriptionId = $SubscriptionId
        Headers = $Headers
		baseurl = $baseurl
    }   
}

function Get-AzMigProject {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )
    #Get Project Id
    $query = "resources | where type == 'microsoft.migrate/migrateprojects' and resourceGroup == '$ResourceGroupName' and name == '$ProjectName'"
    $result = $null
    $result = Search-AzGraph -Query $query
    if (-not $result) {
        throw "Project not found"
    }
    return $result.Id
}

function Get-AzMigAppliances {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )
    #Get Appliance Details
    $query = "resources| where type == 'microsoft.offazure/vmwaresites' or type == 'microsoft.offazure/hypervsites' or type == 'microsoft.offazure/serversites'| where resourceGroup == '$ResourceGroupName' and properties.discoverySolutionId has '$ProjectName'| project properties.applianceName, id"
    $response = $null
    $response = Search-AzGraph -Query $query
    if (-not $response) {
        throw "Appliances not found"
    }
    return $response
}

function Get-AzMigDiscoveredMachines {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)][string]$SiteId,
        [Parameter()][string]$appliancename = $null,
        [Parameter()][Hashtable]$Filter
    )

    #Converting Filter to KQL Query
    $filterQuery=""
    if($Filter){   
        foreach($key in $Filter.Keys){
           $val=$Filter[$key]

           #Filter for IPAddress or IPAddressrange
            if ($key -ieq "IPAddresses") {
                $ipRange = "$val"
                function CheckIPAddress($address) {
                    try {
                        $ip = [System.Net.IPAddress]::Parse($address.Split('/')[0])
                        if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                           return "IPv4"
                        }
                        elseif ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                           return "IPv6"
                        }
                        else {
                           return "Invalid"
                        }
                    }
                    catch {
                        return "Invalid"
                    }
                }
         
                $ipType = CheckIPAddress($ipRange)
             
                if ($ipType -ieq "IPv4" -or $ipType -ieq "IPv6") {
                    $filterQuery += "| mv-expand IPAddress=IPAddresses | extend Iprange = '$ipRange' | extend result = " + $ipType.ToLower() + "_compare(tostring(IPAddress),tostring(Iprange)) | where result == '0' | project-away result,Iprange | summarize make_list(IPAddress) by tostring(ServerName),tostring(IPAddresses),tostring(Source),tostring(DependencyStatus),tostring(DependencyErrors),tostring(ErrorTimeStamp),tostring(DependencyStartTime),tostring(OperatingSystem),tostring(PowerStatus),tostring(Appliance),tostring(FriendlyNameOfCredentials),tostring(Tags),tostring(ARMID) | project-away list_IPAddress"
                } 
                else {
                    throw "The IP range is not valid"
                }
            }
            #Filter for Operating System Details
            elseif ($key -ieq "osType" -or $key -ieq "osName" -or $key -ieq "osArchitecture" -or $key -ieq "osVersion") {
                $filterQuery += "| where "
                $filterQuery += "OperatingSystem.$key == '$val'"
            }
            #Filter for servername, dependencystatus, powerstatus
            elseif($key -ieq "ServerName" -or $key -ieq "Source" -or $key -ieq "DependencyStatus" -or $key -ieq "PowerStatus") {
                $filterQuery += "| where "
                $filterQuery += "$key == '$val'"
            }
            #Filter for tags
            else{
                $filterQuery += "| where "
                $filterQuery += "Tags.$key == '$val'"
            }
        }
    }
    $query = " migrateresources
               | where id has '$SiteId' and type in ('microsoft.offazure/serversites/machines', 'microsoft.offazure/hypervsites/machines', 'microsoft.offazure/vmwaresites/machines')
               | extend ServerName = properties.displayName,
               DependencyStatus = iff(array_length(properties.dependencyMapDiscovery.errors) == 0, properties.dependencyMapping, 'ValidationFailed'),
               Source = properties.vCenterFQDN,
               ErrorTimeStamp = properties.updatedTimestamp,
               DependencyStartTime = properties.dependencyMappingStartTime,
               PowerStatus = properties.powerStatus,
               Appliance = '$appliancename',
               FriendlyNameOfCredentials = properties.dependencyMapDiscovery.hydratedRunAsAccountId,
               ARMID = id
               | mv-expand properties.networkAdapters
               | extend IPAddressList = properties_networkAdapters.ipAddressList
               | summarize IPAddresses = make_list(IPAddressList) by name,tostring(ServerName),tostring(DependencyStatus),tostring(Source),tostring(ErrorTimeStamp),tostring(DependencyStartTime),tostring(PowerStatus),tostring(Appliance),tostring(FriendlyNameOfCredentials),tostring(tags),tostring(ARMID),tostring(properties.dependencyMapDiscovery),tostring(properties.guestOSDetails)
               |join kind=leftouter (
               migrateresources
               | mv-expand properties.dependencyMapDiscovery.errors
               | extend ErrorDetails = strcat('ID:', properties_dependencyMapDiscovery_errors.id, ', Code:', properties_dependencyMapDiscovery_errors.code, ', Message:', properties_dependencyMapDiscovery_errors.message)
               | summarize Error = make_list(ErrorDetails) by name
               ) on name
               |extend DependencyErrors = strcat('DependencyScopeStatus:', todynamic(properties_dependencyMapDiscovery).discoveryScopeStatus, ' Errors:', Error),OperatingSystem = todynamic(properties_guestOSDetails),Tags = todynamic(tags)" + "$filterquery" +
               "| project ServerName, Source, DependencyStatus, DependencyErrors, ErrorTimeStamp, DependencyStartTime, OperatingSystem, PowerStatus, Appliance, FriendlyNameOfCredentials, Tags, ARMID"

    Write-Host "Downloading machines for appliance " $appliancename ". This can take 1-2 minutes..."
    $batchSize = 100
    $skipResult = 0
    $kqlResult = @()

    while ($true) {
        try {
            if ($skipResult -gt 0) {
                $graphResult = Search-AzGraph -Query $query -First $batchSize -SkipToken $graphResult.SkipToken
            }
            else {
                $graphResult = Search-AzGraph -Query $query -First $batchSize
            }
        }
        catch {
            throw "Filter passed is invalid"
        }

        foreach ($entry in $graphResult.data) {
            $machine = [PSCustomObject]($entry | Select-Object ServerName, Source, DependencyStatus, OperatingSystem, PowerStatus, Appliance, FriendlyNameOfCredentials, Tags, ARMID)
            $kqlResult += $machine  
        }

        if ($graphResult.data.Count -lt $batchSize) {
            break
        }

        $skipResult += $skipResult + $batchSize
    }
    return $kqlResult
}

function Get-AzMigDiscoveredVMwareVMs {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][string]$OutputCsvFile = "VMwareVMs.csv",
        [Parameter()][HashTable]$Filter = $null,
	    [Parameter()][string]$ApplianceName = $null
    )

    if(-not (Test-Path -IsValid -Path $OutputCsvFile)) {
        throw "Output CSV file path is not valid"
    }

    if (Test-path -Path $OutputCsvFile) {
        throw "File $OutputCsvFile already exists. Specify a different name or path"
    }
	
	if (-not ($OutputCsvFile -match ".*\.csv$")) {
        throw "Output file specified is not CSV."    
    }

    #Fetching the Project Id
    $projectId = Get-AzMigProject -ResourceGroupName $ResourceGroupName -ProjectName $ProjectName

    if(-not $projectId) {
        throw "Project ID is invalid"
    }
    
    #Get Appliance Details
    $applianceDetails = Get-AzMigAppliances -ResourceGroupName $ResourceGroupName -ProjectName $ProjectName

    if(-not $applianceDetails) {
        throw "Server Discovery Solution missing Appliance Details. Invalid Solution"
    }

    $appMap = @{}

    foreach($row in $applianceDetails){    
        $appMap[$row.properties_applianceName] = $row.id
    }

    $vmwareappliancemap = @{}
    #Discard non-VMware appliances
    #If Appliance name is passed get data only for that appliance
    #If Appliance name is not passed , get data for all appliances in that project
    if (-not $ApplianceName) {
	    $appMap.GetEnumerator() | foreach {if($_.Value -match "VMwareSites|HyperVSites|ServerSites") {$vmwareappliancemap[$_.Key] = $_.Value}}
    }
    else { 
	    $appMap.GetEnumerator() | foreach {if($_.Value -match "VMwareSites|HyperVSites|ServerSites" -and $_.Key -eq $ApplianceName) {$vmwareappliancemap[$_.Key] = $_.Value}}
    }

    Write-Debug -Message "Appliance count : $vmwareappliancemap.count"

    if($vmwareappliancemap) {$vmwareappliancemap | Out-String | Write-Debug};
    if (-not $vmwareappliancemap.count) {
        throw "No VMware VMs discovered in project"
    }
    Write-Host "Please wait while the list of discovered machines is downloaded..."
    
    foreach ($item in $vmwareappliancemap.GetEnumerator()) {
        $SiteId = $item.Value
        $appliancename = $item.Key
        Write-Debug -Message "Get machines for Site $SiteId"
        $kqlResult =  Get-AzMigDiscoveredMachines -SiteId $SiteId -appliancename $appliancename -Filter $Filter

        if ($kqlResult) {
            $appliancename = $item.Key
            Write-Host "Machines discovered for $appliancename"
            $headers = $kqlResult[0].PSObject.Properties | Select-Object -ExpandProperty Name
            $csvData = @()
            foreach ($machine in $kqlResult) {
                $row = [ordered]@{}       
                foreach ($header in $headers) {
                    $row[$header] = $($machine.$header)
                }
                $csvData += New-Object PSObject -Property $row
            }
            $csvData | Export-Csv -Path $OutputCsvFile -NoTypeInformation -Append
            Write-Host "List of machines saved to" $OutputCsvFile
        } 
        else {
           Write-Host "No machines discovered in the appliance $appliancename"
        }            
    }         
} 

function Set-AzMigDependencyMappingAgentless {
    [CmdletBinding()]
    Param(
        [Parameter(ParameterSetName = 'Enable', Mandatory = $true)]
        [Parameter(ParameterSetName = 'Disable', Mandatory = $true)]
        [string]$InputCsvFile,

        [Parameter(ParameterSetName = 'Enable', Mandatory = $true)]
        [switch]$Enable,

        [Parameter(ParameterSetName = 'Disable', Mandatory = $true)]
        [switch]$Disable
    )

    if (-not (Test-path -Path $InputCsvFile)) {
        throw "File $InputCsvFile not found"
    }
    
	if (-not ($InputCsvFile -imatch ".*\.csv$")) {
        throw "Input file is not CSV."    
    }
	
    $VMDetails = Import-CSV $InputCsvFile
	
	if(-not ($VMDetails[0].psobject.Properties.Name.ToLower().contains("armid")) ) {
		throw "Input CSV file does not contain required column 'ARMID'"
	}

    if($Enable){ 
        $ActionVerb = "Enabled";
		$EnableDependencyMapping = $true
    } 
    elseif ($Disable) {
        $ActionVerb = "Disabled";
		$EnableDependencyMapping = $false
    } 
    else {
        throw "Error: Action to update dependency mapping is invalid. Please specify either Enable or Disable."
    }

    #Check if the number of machines exceed the maximum limit
    if ($ActionVerb -eq "Enabled") {
        $machinesInfo = @{}
        foreach ($machine in $VMDetails) {
            $machineId = $machine.ARMID
            $splitId = $machineId -split '/'
            $siteTypeIndex = ($splitId.IndexOf('VMwareSites'), $splitId.IndexOf('HyperVSites'), $splitId.IndexOf('ServerSites') | Where-Object { $_ -ne -1 })[0]

            if ($siteTypeIndex -ne -1 -and $siteTypeIndex -lt ($splitId.Count - 1)) {
                $siteId = ($splitId[0..($siteTypeIndex + 1)] -join '/')
            } 
            else {
                throw "Site ID not found in the arm ID."
            }

            #storing the count of machines present in csv
            if (-not $machinesInfo.ContainsKey($siteId)) {
                $machinesInfo[$siteId] = @{
                        'type' = $null
                        'countOfMachinesToBeEnabled' = 0
                }
                if ($siteId -match "/subscriptions/.*/VMwareSites/([^/]*)\w{4}site") {
                    $machinesInfo[$siteId]['type'] = 'vmware'
                } 
                elseif ($siteId -match "/subscriptions/.*/HyperVSites/([^/]*)\w{4}site") {
                    $machinesInfo[$siteId]['type']= 'hyperv'
                } 
                elseif ($siteId -match "/subscriptions/.*/ServerSites/([^/]*)\w{4}site") {
                    $machinesInfo[$siteId]['type'] = 'server'
                }
            }
            $machinesInfo[$siteId]['countOfMachinesToBeEnabled']++
        }
        
        foreach ($key in $machinesInfo.Keys) {
            $type = $machinesinfo[$key]['type']
            [System.Collections.Generic.List[string]]$machinesAlreadyEnabled = Get-AzMigDiscoveredMachines -SiteId $Key -Filter @{"DependencyStatus" = "Enabled"}
            $machinesAlreadyEnabledCount = $machinesAlreadyEnabled.Count
            $maxLimit
            if ($type -eq 'vmware') {
                $maxLimit = $vmWareMaxLimit
            } 
            else {
                $maxLimit = $hypervAndServerMaxLimit
            }

            if ($machinesInfo[$key]['countOfMachinesToBeEnabled'] -gt ($maxLimit - $machinesAlreadyEnabledCount)) {
                throw "Maximum limit exceeded for $type machines. Count of machines to be enabled: $($machinesInfo[$key]['countOfMachinesToBeEnabled']). Count of machines that can be enabled: $($maxLimit - $machinesAlreadyEnabledCount)"
            }
        }
    }
    $Properties = GetRequestProperties
    $VMs = ($VMDetails | Select-Object -ExpandProperty "ARMID")
    $VMs = $VMs | sort
    $jsonPayload = @"
    {
        "machines": []
    }
"@
    $jsonPayload = $jsonPayload | ConvertFrom-Json
    $currentsite = $null
    foreach ($machine in $VMs) {
        if (-not ($machine -match "(/subscriptions/.*\/VMwareSites/([^\/]*)\w{4}site)")) {
            continue
        }

        $sitename = $Matches[1];
        Write-Debug "Site: $sitename Machine: $machine"

        if((-not $currentsite) -or ($sitename -eq $currentsite)) {
            $currentsite = $sitename
            $tempobj= [PSCustomObject]@{
                                        machineArmId = $machine
                                        dependencyMapping = $ActionVerb 
                                       }
            $jsonPayload.machines += $tempobj
            continue
        }

        #different site. Send update request for previous site and start building request for the new site
        if ($sitename -ne $currentsite) {
            if ($jsonPayload.machines.count) {
                $requestbody = $jsonPayload | ConvertTo-Json
                $requestbody | Write-Debug
                $requesturi = $Properties['baseurl'] + ${currentsite} + "/UpdateProperties" + "?api-version=2020-01-01";
                Write-Debug $requesturi
                $response = $null
                $response = Invoke-RestMethod -Method Post -Headers $Properties['Headers'] -Body $requestbody  $requesturi -ContentType "application/json"
                if ($response) {
					$temp = $currentsite -match "\/([^\/]*)\w{4}site$" # Extract the appliance name
					$appliancename = $Matches[1]
					Write-Output "Updated dependency mapping status for input VMs on appliance: $appliancename"
                }
				else {
					throw "Could not update dependency mapping status"
				}
            }

            #Reset jsonpayload
            $jsonPayload.machines = @()
            $tempobj= [PSCustomObject]@{
                                        machineArmId = $machine
                                        dependencyMapping = $ActionVerb 
                                       }
            $jsonPayload.machines += $tempobj
            $currentsite = $sitename #update current site name
        }
    }

    #Enable/Disable dependency for unprocessed sites
    if ($jsonPayload.machines.count) {
       $requestbody = $jsonPayload | ConvertTo-Json
       $requestbody | Write-Debug
       $requesturi = $Properties['baseurl'] + ${currentsite} + "/UpdateProperties" + "?api-version=2020-01-01";
       Write-Debug $requesturi
       $response = $null
       $response = Invoke-RestMethod -Method Post -Headers $Properties['Headers'] -Body $requestbody  $requesturi -ContentType "application/json"
	   $temp = $currentsite -match "\/([^\/]*)\w{4}site$" # Extract the appliance name
	   $appliancename = $Matches[1]
       if ($response) {
			Write-Output "Updating dependency mapping status for input VMs on appliance: $appliancename"
       }
	   else {
			throw "Could not update dependency mapping status for input VMs on appliance: $appliancename"
		}
	}

    #Reset jsonpayload and loop through the same machines , this time for hyperV and server fabric
    $jsonPayload.machines = @()

    $currentsite = $null
    foreach ($machine in $VMs) {
        if (-not ($machine -match "(/subscriptions/.*\/HyperVSites/([^\/]*)\w{4}site)" -or $machine -match "(/subscriptions/.*\/ServerSites/([^\/]*)\w{4}site)" )) {
            continue    
        }

        $sitename = $Matches[1]
        Write-Debug "Site: $sitename Machine: $machine"

        if((-not $currentsite) -or ($sitename -eq $currentsite)) {
            $currentsite = $sitename
            $tempobj= [PSCustomObject]@{
                                        machineId = $machine
                                        isDependencyMapToBeEnabled = $EnableDependencyMapping 
                                       }
            $jsonPayload.machines += $tempobj
            continue;
        }

        #different site. Send update request for previous site and start building request for the new site
        if ($sitename -ne $currentsite) {
            if ($jsonPayload.machines.count) {
                $requestbody = $jsonPayload | ConvertTo-Json
                $requestbody | Write-Debug
                $requesturi = $Properties['baseurl'] + ${currentsite} + "/UpdateDependencyMapStatus" + "?api-version=2020-08-01-preview";
                Write-Debug "request uri is : $requesturi"
                $response = $null
                $response = Invoke-RestMethod -Method Post -Headers $Properties['Headers'] -Body $requestbody  $requesturi -ContentType "application/json"
                if ($response) {
					$temp = $currentsite -match "\/([^\/]*)\w{4}site$" # Extract the appliance name
					$appliancename = $Matches[1]
					Write-Output "Updated dependency mapping status for input VMs on appliance: $appliancename"
                }
				else {
					throw "Could not update dependency mapping status"
				}
            }

            #Reset jsonpayload
            $jsonPayload.machines = @()
            $tempobj= [PSCustomObject]@{
                                        machineId = $machine
                                        isDependencyMapToBeEnabled = $EnableDependencyMapping 
                                       }
            $jsonPayload.machines += $tempobj
            $currentsite = $sitename #update current site name
        }
    }


    #Enable/Disable dependency for unprocessed sites
    if ($jsonPayload.machines.count) {
       $requestbody = $jsonPayload | ConvertTo-Json
       $requestbody | Write-Debug
       $requesturi = $Properties['baseurl'] + ${currentsite} + "/UpdateDependencyMapStatus" + "?api-version=2020-08-01-preview";
       Write-Debug $requesturi
       $response = $null
       $response = Invoke-RestMethod -Method Post -Headers $Properties['Headers'] -Body $requestbody  $requesturi -ContentType "application/json"
	   $temp = $currentsite -match "\/([^\/]*)\w{4}site$" # Extract the appliance name
	   $appliancename = $Matches[1]
       if ($response) {
					Write-Output "Updating dependency mapping status for input VMs on appliance: $appliancename"
       }
	   else {
					throw "Could not update dependency mapping status for input VMs on appliance: $appliancename"
		}
	}

    # Pointing out all the incorrect ARM IDs
    foreach ($machine in $VMs) {
        if (-not ($machine -match "(/subscriptions/.*\/HyperVSites/([^\/]*)\w{4}site)" -or $machine -match "(/subscriptions/.*\/ServerSites/([^\/]*)\w{4}site)" -or $machine -match "(/subscriptions/.*\/VmwareSites/([^\/]*)\w{4}site)" )) {
            Write-Output "Skipping the machine : $machine . Please check the ARM ID"    
        }
	}
	
}

function Get-AzMigDependenciesAgentless {
    [CmdletBinding()]
    Param(
	#	[Parameter(Mandatory = $true)][string]$SubscriptionID,
		[Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ProjectName,
		[Parameter(Mandatory = $true)][string]$Appliance,
		[Parameter(Mandatory = $false)][string]$OutputCsvFile = "AzMig_dependencies.csv"
    )

    #$obj = @()
	
	if (-not ($OutputCsvFile -imatch ".*\.csv$")) {
        throw "Output file is not CSV."    
    }
	
	if(-not (Test-Path -IsValid -Path $OutputCsvFile)) {
        throw "Output CSV File path not valid"
    }
	
    if (Test-path -Path $OutputCsvFile) {
        throw "File $OutputCsvFile already exists. Specify a different name or path"
    }
	
	$Properties = GetRequestProperties
	
	$ProjectID = Get-AzMigProject -ResourceGroup $ResourceGroupName -ProjectName $ProjectName
	
	$listsitesurl = $Properties['baseurl'] + $ProjectID + "/Solutions/Servers-Discovery-ServerDiscovery?api-version=2019-06-01"
	$siteresponse = Invoke-RestMethod -Uri $listsitesurl -Headers $Properties['Headers'] -ContentType "application/json" -Method "GET" # -Debug -Verbose
	
	if (-not $siteresponse) {
			throw "Could not retrieve the site for appliance $appliancename"
    }
	
	$VMwareSiteID = ""

    if ($null -ne $siteresponse.properties.details.extendedDetails.applianceNameToSiteIdMapV2) {
        $appMapV2 = $siteresponse.properties.details.extendedDetails.applianceNameToSiteIdMapV2 | ConvertFrom-Json
        # Fetch all appliance from V2 map first. Then these can be updated if found again in V3 map.
        foreach ($site in $appMapV2) {
            $appliancename = $site.ApplianceName
            if ($Appliance -ne $appliancename) {continue}
            $VMwareSiteID =  $site.SiteId
        }
    }

    if ($null -ne $siteresponse.properties.details.extendedDetails.applianceNameToSiteIdMapV3) {
        $appMapV3 = $siteresponse.properties.details.extendedDetails.applianceNameToSiteIdMapV3 | ConvertFrom-Json
        foreach ($site in $appMapV3) {
            $siteProps = $site.psobject.properties
            $appliancename = $siteProps.Value.ApplianceName
            if ($Appliance -ne $appliancename) {continue}
            $VMwareSiteID =  $siteProps.Value.SiteId
        }
    }

    if ($null -eq $siteresponse.properties.details.extendedDetails.applianceNameToSiteIdMapV2 -And
         $null -eq $siteresponse.properties.details.extendedDetails.applianceNameToSiteIdMapV3 ) {
        throw "Server Discovery Solution missing Appliance Details. Invalid Solution."           
    }
			
	if($VMwareSiteID -eq "") {
		Write-Host "Appliance name is not valid."
		return
	}
	
	Write-Output $VMWareSiteID

	if($VMWareSiteID -match "(/subscriptions/.*\/VmwareSites/([^\/]*)\w{4}site)"){
	$url = $Properties['baseurl'] + $VMWareSiteID + "/exportDependencies?api-version=2020-01-01-preview" }

	if($VMWareSiteID -match "(/subscriptions/.*\/HyperVSites/([^\/]*)\w{4}site)" -or $VMWareSiteID -match "(/subscriptions/.*\/ServerSites/([^\/]*)\w{4}site)"){
	$url = $Properties['baseurl'] + $VMWareSiteID + "/exportDependencies?api-version=2020-08-01-preview" }
	
	$StartTime = Get-Date
	
	$StartTime = $StartTime.AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")
	
	$EndTime = Get-Date
	
	$EndTime = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")

$jsonPayload = @"
{
   "startTime": "$StartTime", 
   "endTime": "$EndTime"
   }
"@
	# Make the export dependencies call to get the SAS URI from which to download the dependencies
	# Write-Host $url
    $response = Invoke-RestMethod -Uri $url -Headers $Properties['Headers'] -ContentType "application/json" -Method "POST" -Body $jsonPayload # -Debug -Verbose
    
	if (-not $response) {
			throw "Could not retrieve the site for appliance $appliancename"
    }

	if($VMWareSiteID -match "(/subscriptions/.*\/VmwareSites/([^\/]*)\w{4}site)"){	
	$url = $Properties['baseurl'] + $response.id + "?api-version=2020-01-01-preview"}

	if($VMWareSiteID -match "(/subscriptions/.*\/HyperVSites/([^\/]*)\w{4}site)" -or $VMWareSiteID -match "(/subscriptions/.*\/ServerSites/([^\/]*)\w{4}site)"){
	$url = $Properties['baseurl'] + $response.id + "?api-version=2020-08-01-preview"}
	
	Write-Host "Please wait while the dependency data is downloaded..."
	
	# Poll until SAS URI is available
	Do
	{
		try {
			$uriresponse = Invoke-RestMethod -Uri $url -Headers $Properties['Headers'] -ContentType "application/json" -Method "GET" # -Debug -Verbose
		}
		catch {
			Write-Host $_
			Write-Host "Retrying..."
		}
		if($uriresponse.status -ne "Succeeded") {
			Start-Sleep -s 2
		}
	}
	while($uriresponse.status -ne "Succeeded")
	
	$Result = $uriresponse.properties.result | ConvertFrom-Json # Extract SAS URI
	
	$filename = $OutputCsvFile
	$temp_filename = "Temp_" + $filename
	
	Invoke-WebRequest -Uri $Result.SASUri -OutFile $temp_filename
	
	Write-Host "Please wait while the downloaded data is processed for PowerBI..."
	
	Import-Csv -Path $temp_filename | Select-Object -Property "Source server name", "Source IP", "Source application", "Source process", "Destination server name", "Destination IP", "Destination application", "Destination process", "Destination port" | Sort-Object -Property * -Unique -Descending | Export-Csv -NoTypeInformation -Path $filename
	
	Write-Host "Dependencies data for appliance " $Appliance " saved in " $filename 
	
	Remove-Item $temp_filename
}
