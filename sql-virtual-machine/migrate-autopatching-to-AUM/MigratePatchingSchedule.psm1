<#
    .SYNOPSIS
    Script for migrating from Autopatching schedule on SQL VM to Azure Update Manager(AUM) schedule 

    .DESCRIPTION
    This script is for migrating from Autopatching schedule on SQL VM to Azure Update Manager(AUM) schedule
    Before running this script, ensure you have:
    - SQL VM is running
    - Autopatching is enabled

    .PARAMETER ResourceGroupName
    Name of the ResourceGroup whose VMs need to be migrated

    .PARAMETER VmName
    Name of the VM to be migrated

    .EXAMPLE
    import-module -Name ".\MigratePatchingSchedule.psm1"
    MigratePatchingSchedule -ResourceGroupName myrg -VmName myvm-1	
#>

function MigratePatchingSchedule {
    [CmdletBinding()]    
    Param
    (        
        [Parameter(Mandatory = $true)]
        [string]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]
        $VmName)

	$context = Get-AzContext
	if ($context -eq $null) 
	{
		Connect-AzAccount
	}

	#set values
	$configName = "MigratedSchedule-"+$VmName
	$WindowsParameterClassificationToInclude = "Critical", "Security";
	$RebootOption = "IfRequired"
	$scope = "InGuestPatch"

	# Get the VM details
	$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop

	# Get the subscription ID
	$SubscriptionId = $vm.Id.Split('/')[2]
	$location = $vm.Location

	try {
		# get current autopatching settings
		$currentPatchSettings = (Get-AzVMSqlServerExtension -VMName $VmName -ResourceGroupName $ResourceGroupName).AutoPatchingSettings
		if ($currentPatchSettings -eq $null -or $currentPatchSettings.Enable -eq $false) {
			Write-Warning "Auto patching is not enabled on VM."
			return
		}
		Write-Host "current autopatching settings:: "
		Write-Host "   Maintenance schedule: $($currentPatchSettings.DayOfWeek)"
		Write-Host "   Maintenance start hour (local time): $($currentPatchSettings.MaintenanceWindowStartingHour)" 
		Write-Host "   Maintenance window duration (minutes): $($currentPatchSettings.MaintenanceWindowDuration) "	
	}
	catch {
		Write-Error "An error occurred while trying to retrieve the autopatching settings."
		Write-Error "Error message: $_"
		return
	}

	try {
		$convertedSchedule = Convert-Schedule -ResourceGroupName $ResourceGroupName -VmName $VmName `
						-DayOfWeek $currentPatchSettings.DayOfWeek `
						-MaintenanceWindowStartingHour $currentPatchSettings.MaintenanceWindowStartingHour `
						-MaintenanceWindowDuration $currentPatchSettings.MaintenanceWindowDuration		
	}
	catch {
		Write-Error "An error occurred while converting autopatching settings to AUM schedule."
		Write-Error "Error message: $_"
		return
	}
	
	# enable MU
	try {
		$temp = Set-AzVMOperatingSystem -VM $vm -Windows -PatchMode "AutomaticByPlatform"
		$AutomaticByPlatformSettings = $vm.OSProfile.WindowsConfiguration.PatchSettings.AutomaticByPlatformSettings
		 
		if ($null -eq $AutomaticByPlatformSettings) {
		   $vm.OSProfile.WindowsConfiguration.PatchSettings.AutomaticByPlatformSettings = New-Object -TypeName Microsoft.Azure.Management.Compute.Models.WindowsVMGuestPatchAutomaticByPlatformSettings -Property @{BypassPlatformSafetyChecksOnUserSchedule = $true}
		} else {
		   $AutomaticByPlatformSettings.BypassPlatformSafetyChecksOnUserSchedule = $true
		}
		 
		$temp = Update-AzVM -VM $vm -ResourceGroupName $ResourceGroupName
	}
	catch {
		Write-Error "An error occurred while enabling MU on the VM."
		Write-Error "Error message: $_"
		return
	}

	try {
	# create new maintenance config
	$maintConfig = New-AzMaintenanceConfiguration `
		-ResourceGroup $ResourceGroupName `
		-Name $configName `
		-MaintenanceScope $scope `
		-Location $location `
		-StartDateTime $convertedSchedule.scheduleStartOn `
		-TimeZone $convertedSchedule.timezoneId `
		-Duration $convertedSchedule.duration `
		-RecurEvery $convertedSchedule.recurEvery `
		-WindowParameterClassificationToInclude $WindowsParameterClassificationToInclude `
		-InstallPatchRebootSetting $RebootOption `
		-ExtensionProperty @{"InGuestPatchMode"="User"}
	}
	catch {
		Write-Error "An error occurred while creating new maintenance configuration."
		Write-Error "Error message: $_" 
		return
	}
	
	# assign VM to maintenance config
	try {
	$temp = New-AzConfigurationAssignment `
		-ResourceGroupName $ResourceGroupName `
		-Location $location `
		-ResourceName $VmName `
		-ResourceType "VirtualMachines" `
		-ProviderName "Microsoft.Compute" `
		-ConfigurationAssignmentName $configName `
		-MaintenanceConfigurationId $maintConfig.Id
	}
	catch {
		Write-Error "An error occurred while assigning the maintenance configuration to VM."
		Write-Error "Error message: $_"
		return
	}


	Write-Host "Attached new maintenance schedule $configName to VM : $VmName"
	Write-Host "New maintenance schedule:: "
	Write-Host "   Recurrence: $($maintConfig.RecurEvery)"
	Write-Host "   Schedule start time: $($maintConfig.StartDateTime)" 
	Write-Host "   Duration: $($maintConfig.Duration)" 
	Write-Host "   Schedule expiration time: $($maintConfig.ExpirationDateTime)"
	
	try {
		# disable automated patching, this takes upto 1-2 mins
		Write-Host "Disabling Autopatching setting..."
		$temp = Update-AzSqlVM -ResourceGroupName  $ResourceGroupName -Name $VmName -AutoPatchingSettingEnable:$false
	}
	catch {
		Write-Error "An error occurred while disabling Autopatching. Please update manually."
		#Write-Error "Error message: $_" 
	}
}

<#
    .SYNOPSIS
    Function for getting current timezone id on VM. If not found, prompts user to enter timezone id

    .DESCRIPTION
    This function is for getting current timezone id on VM. If not found, prompts user to enter timezone id

    .PARAMETER ResourceGroupName
    Name of the ResourceGroup

    .PARAMETER VmName
    Name of the VM

    .EXAMPLE
    Get-TimezoneId -ResourceGroupName myrg -VmName myvm-1	
#>
function Get-TimezoneId {
    Param
    (        
        [Parameter(Mandatory = $true)]
        [string]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]
        $VmName)
		
	try {
		Write-Host "Reading timezone on VM"
		$rgName = $ResourceGroupName
		$vmName = $VmName
		$output = Invoke-AzVmRunCommand `
		 -ResourceGroupName $rgName `
		 -VMName $vmName `
		 -CommandId "RunPowerShellScript" `
		 -ScriptString "Get-Timezone"

		$timezoneinfo = $output.value[0].message
		$timezoneId = ($timezoneinfo | Select-String -Pattern '^Id\s*:\s*(.*)').Matches.Groups[1].Value

		return $timezoneId
	}
	catch {
		# Write-Error "An error occurred while getting Timezone on Vm: $_"
		# return ""
	}
	
	if ($timezoneId -eq $null -or $timezoneId -eq "") {
        Write-Host "Could not read Timezone from VM"
		$valid = $false
		while (-not $valid) {
		# Prompt user to enter timezone ID
		$timezoneId = Read-Host "Please enter a timezone ID. Refer to https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/default-time-zones?view=windows-11 for valid timezones"
    
		# Validate the entered timezone ID
		$valid = Validate-TimezoneId -TimezoneId $timezoneId
		}
		Write-Host "you entered timezone: $($timezoneId)"
		return $timezoneId
    }	
}

<#
    .SYNOPSIS
    Function for validating timezone id entered by user

    .DESCRIPTION
    This function is for validating timezone id entered by user
	
	.PARAMETER TimezoneId
    time zone id value

    .EXAMPLE
    Validate-TimezoneId -TimezoneId "UTC"
#>
function Validate-TimezoneId {
    Param (
        [string]$TimezoneId
    )
		# Define valid timezone IDs
		$validTimezoneIds = [System.TimeZoneInfo]::GetSystemTimeZones().Id

		if ($validTimezoneIds -contains $TimezoneId) {
			return $true
		} else {
			Write-Host "Invalid timezone ID: $TimezoneId"
			return $false
		}
}

<#
    .SYNOPSIS
    Function for converting current autopatching schedule to AUM schedule

    .DESCRIPTION
    This function is converting current autopatching schedule to AUM schedule

    .PARAMETER ResourceGroupName
    Name of the ResourceGroup

    .PARAMETER VmName
    Name of the VM
	
    .PARAMETER DayOfWeek
    Current DayOfWeek setting

    .PARAMETER MaintenanceWindowStartingHour
    Current MaintenanceWindowStartingHour value
	
    .PARAMETER MaintenanceWindowDuration
    Current MaintenanceWindowDuration value

    .EXAMPLE
    Convert-Schedule -ResourceGroupName myrg -VmName myvm-1 -DayOfWeek "Sunday" -MaintenanceWindowStartingHour 22 -MaintenanceWindowDuration 90
#>
function Convert-Schedule {
    Param
    (        
        [Parameter(Mandatory = $true)]
        [string]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]
        $VmName,
        [Parameter(Mandatory = $true)]
        [string]
        $DayOfWeek,
        [Parameter(Mandatory = $true)]
        [int]
        $MaintenanceWindowStartingHour,
        [Parameter(Mandatory = $true)]
        [int]
        $MaintenanceWindowDuration)
		
	$timezoneId = Get-TimezoneId -ResourceGroupName $ResourceGroupName -VMName $VmName	

	$currentDateTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::Now,$timezoneId)

	$currentDateWithMaintenanceStartTime = [DateTime]($currentDateTime.ToString('yyyy-MM-dd') + " " + "{0:hh\:mm}" -f (New-TimeSpan -Hours $MaintenanceWindowStartingHour))

	# if schedule is daily, then the start time should be today 
	# unless the time has already passed, then it would be the next day
	# else if the schedule is weekly, and the current day matches today, then the start day is today,
	# unless the time has passed, then it would be the next day that matches the day of week
	if($DayOfWeek -eq "Everyday") {
		$recurEvery = "Day"

		if ($currentDateTime -lt $currentDateWithMaintenanceStartTime)
		{
			$scheduleStartOn = $currentDateTime.ToString('yyyy-MM-dd') + " " + "{0:hh\:mm}" -f (New-TimeSpan -Hours $MaintenanceWindowStartingHour)
		}
		else 
		{
			$scheduleStartOn = $currentDateTime.AddDays(1).ToString('yyyy-MM-dd') + " " + "{0:hh\:mm}" -f (New-TimeSpan -Hours $MaintenanceWindowStartingHour)
		}
	}
	else {
		$recurEvery = "Week " + $DayOfWeek 

		if (($currentDateTime -lt $currentDateWithMaintenanceStartTime) -and ($currentDateTime.DayOfWeek -eq $DayOfWeek)) 
		{
			$scheduleStartOn = $currentDateTime.ToString('yyyy-MM-dd') + " " + "{0:hh\:mm}" -f (New-TimeSpan -Hours $MaintenanceWindowStartingHour)
		}
		else {
			for($i=1; $i -le 7; $i++)
			{
				if($currentDateTime.AddDays($i).DayOfWeek -eq $DayOfWeek)
				{
					$scheduleStartOn = $currentDateTime.AddDays($i).ToString('yyyy-MM-dd') + " " + "{0:hh\:mm}" -f (New-TimeSpan -Hours $MaintenanceWindowStartingHour)
					break
				}
			}
		}
	}

	if($MaintenanceWindowDuration -le 90) {
		$duration = "01:30"
	}
	else {
		$duration = "{0:hh\:mm}" -f (New-TimeSpan -Minutes $MaintenanceWindowDuration)
	}

	return @{ 
				recurEvery = $recurEvery 
				scheduleStartOn = $scheduleStartOn
				duration = $duration
				timezoneId = $timezoneId
			}
}

Export-ModuleMember -Function MigratePatchingSchedule