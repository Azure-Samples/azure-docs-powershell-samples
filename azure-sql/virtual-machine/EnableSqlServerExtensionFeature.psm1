#Requires -Module Az.Compute
#Requires -Module Az.Accounts
#Requires -Module Az.SqlVirtualMachine
#Requires -Module Az.Resources
#Requires -Module Microsoft.PowerShell.Security
#Requires -Module Microsoft.PowerShell.Utility

<#
    .SYNOPSIS
    Enable or disable SQL IaaS extension features for Azure VMs running SQL Server.

    .DESCRIPTION
    Identify and enable or disable SQL IaaS extension features for all Azure VMs 
    running SQL Server on Windows in a list of subscriptions, resource group list,
    particular resource group or a particular VM.
    
    The cmdlet configures features supported by the SQL IaaS extension and 
    generates a report and a log file at the end of the execution. The report is 
    generated as a txt file named SqlExtensionFeatureReport<Timestamp>.txt. Errors 
    are logged in the log file named SqlExtensionFeatureError<Timestamp>.log. 
    Timestamp is the time when the cmdlet was started. A summary is displayed at 
    the end of the script run.
    
    The Output summary contains the number of VMs that successfully configured the 
    feature, failed or were skipped because of various reasons. The detailed list
    of VMs can be found in the report and the details of error can be found in the 
    log.

    Prerequisites:
    - Run 'Connect-AzAccount' to first connect the powershell session to the azure 
      account.
    - The Client credentials must have one of the following RBAC levels of access 
      over the virtual machine being registered: Virtual Machine Contributor,
      Contributor or Owner
    - The script requires Az powershell module to be installed. Details 
      on how to install Az module can be found here: 
      https://docs.microsoft.com/powershell/azure/install-az-ps
      It specifically requires Az.Compute and Az.Accounts modules which come as 
      part of the Az module installation.

    .PARAMETER SubscriptionList
    List of Subscriptions whose VMs need to be registered

    .PARAMETER Subscription
    Single subscription whose VMs will be registered

    .PARAMETER ResourceGroupList
    List of Resource Groups in a single subscription whose VMs need to be registered

    .PARAMETER ResourceGroupName
    Name of the ResourceGroup whose VMs need to be registered

    .PARAMETER VmList
    List of VMs in a single resource group that needs to be registered

    .PARAMETER Name
    Name of the VM to be registered

    .PARAMETER FeatureName
    Name of the SQL IaaS extension feature to enable or disable. 
    Example feature names include:
    - "SqlInstanceInventoryUploadForAzureVM" - Enables inventory upload for SQL VMs

    .PARAMETER EnableFeature
    Specify $true to enable the feature or $false to disable the feature

    .EXAMPLE
    # To enable SQL IaaS extension feature on all VMs in a list of subscriptions
    Enable-SqlServerExtensionFeature -SubscriptionList SubscriptionId1,SubscriptionId2 `
        -FeatureName "SqlInstanceInventoryUploadForAzureVM" -EnableFeature $true
    -------------------------------------------------------------------------------
    Summary
    -------------------------------------------------------------------------------
    Number of Subscriptions failed for because you do not have access or 
    credentials are wrong: 1
    Total VMs Found: 10
    VMs Already configured: 1
    Number of VMs configured feature successfully: 4
    Number of VMs failed to configure feature due to error: 1
    Number of VMs skipped as VM or the guest agent on VM is not running: 3
    Number of VMs skipped as they are not running SQL Server On Windows: 1
    
    Please find the detailed report in file SqlExtensionFeatureReport1571314821.txt
    Please find the error details in file SqlExtensionFeatureError1571314821.log
    -------------------------------------------------------------------------------

    .EXAMPLE
    # To disable a specific feature on all VMs in a subscription
    Enable-SqlServerExtensionFeature -Subscription SubscriptionId1 `
        -FeatureName "SqlInstanceInventoryUploadForAzureVM" -EnableFeature $false
    -------------------------------------------------------------------------------
    Summary
    -------------------------------------------------------------------------------
    Total VMs Found: 10
    VMs Already configured: 1
    Number of VMs configured feature successfully: 5
    Number of VMs failed to configure feature due to error: 1
    Number of VMs skipped as VM or the guest agent on VM is not running: 2
    Number of VMs skipped as they are not running SQL Server On Windows: 1
    
    Please find the detailed report in file SqlExtensionFeatureReport1571314821.txt
    Please find the error details in file SqlExtensionFeatureError1571314821.log
    -------------------------------------------------------------------------------

    .EXAMPLE
    # To enable a custom feature on all VMs in a single subscription
    Enable-SqlServerExtensionFeature -Subscription SubscriptionId1 `
        -FeatureName "CustomSqlFeature" -EnableFeature $true
    -------------------------------------------------------------------------------
    Summary
    -------------------------------------------------------------------------------
    Total VMs Found: 10
    VMs Already configured: 1
    Number of VMs configured feature successfully: 5
    Number of VMs failed to configure feature due to error: 1
    Number of VMs skipped as VM or the guest agent on VM is not running: 2
    Number of VMs skipped as they are not running SQL Server On Windows: 1
    
    Please find the detailed report in file SqlExtensionFeatureReport1571314821.txt
    Please find the error details in file SqlExtensionFeatureError1571314821.log
    -------------------------------------------------------------------------------

    .EXAMPLE
    # To enable SQL IaaS extension feature on all VMs in a single subscription 
    # and multiple resource groups
    Enable-SqlServerExtensionFeature -Subscription SubscriptionId1 `
        -ResourceGroupList ResourceGroup1,ResourceGroup2 `
        -FeatureName "SqlInstanceInventoryUploadForAzureVM" -EnableFeature $true
    -------------------------------------------------------------------------------
    Summary
    -------------------------------------------------------------------------------
    Total VMs Found: 4
    VMs Already configured: 1
    Number of VMs configured feature successfully: 1
    Number of VMs failed to configure feature due to error: 1
    Number of VMs skipped as they are not running SQL Server On Windows: 1
    
    Please find the detailed report in file SqlExtensionFeatureReport1571314821.txt
    Please find the error details in file SqlExtensionFeatureError1571314821.log
    -------------------------------------------------------------------------------

    .EXAMPLE
    # To enable SQL IaaS extension feature on all VMs in a resource group
    Enable-SqlServerExtensionFeature -Subscription SubscriptionId1 `
        -ResourceGroupName ResourceGroup1 `
        -FeatureName "SqlInstanceInventoryUploadForAzureVM" -EnableFeature $true
    -------------------------------------------------------------------------------
    Summary
    -------------------------------------------------------------------------------
    Total VMs Found: 4
    VMs Already configured: 1
    Number of VMs configured feature successfully: 1
    Number of VMs failed to configure feature due to error: 1
    Number of VMs skipped as VM or the guest agent on VM is not running: 1
    
    Please find the detailed report in file SqlExtensionFeatureReport1571314821.txt
    Please find the error details in file SqlExtensionFeatureError1571314821.log
    -------------------------------------------------------------------------------

    .EXAMPLE
    # To disable a feature on multiple VMs in a single subscription and resource group
    Enable-SqlServerExtensionFeature -Subscription SubscriptionId1 `
        -ResourceGroupName ResourceGroup1 -VmList VM1,VM2,VM3 `
        -FeatureName "SqlInstanceInventoryUploadForAzureVM" -EnableFeature $false
    -------------------------------------------------------------------------------
    Summary
    -------------------------------------------------------------------------------
    Total VMs Found: 3
    VMs Already configured: 0
    Number of VMs configured feature successfully: 1
    Number of VMs skipped as VM or the guest agent on VM is not running: 1
    Number of VMs skipped as they are not running SQL Server On Windows: 1
    
    Please find the detailed report in file SqlExtensionFeatureReport1571314821.txt
    Please find the error details in file SqlExtensionFeatureError1571314821.log
    -------------------------------------------------------------------------------

    .EXAMPLE
    # To enable SQL IaaS extension feature on a particular VM
    Enable-SqlServerExtensionFeature -Subscription SubscriptionId1 `
        -ResourceGroupName ResourceGroup1 -Name VM1 `
        -FeatureName "SqlInstanceInventoryUploadForAzureVM" -EnableFeature $true
    -------------------------------------------------------------------------------
    Summary
    -------------------------------------------------------------------------------
    Total VMs Found: 1
    VMs Already configured: 0
    Number of VMs configured feature successfully: 1
    
    Please find the detailed report in file SqlExtensionFeatureReport1571314821.txt
    -------------------------------------------------------------------------------

    .LINK
    https://aka.ms/RegisterSqlVMs

    .LINK
    https://www.powershellgallery.com/packages/Az.SqlVirtualMachine/0.1.0
#>
function Enable-SqlServerExtensionFeature {
    [CmdletBinding(DefaultParameterSetName = 'SubscriptionList', SupportsShouldProcess=$true)]
    Param
    (
        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionList')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $SubscriptionList,
        [Parameter(Mandatory = $true, ParameterSetName = 'SingleSubscription')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ResourceGroupList')]
        [Parameter(Mandatory = $true, ParameterSetName = 'VmList')]
        [ValidateNotNullOrEmpty()]
        [string]
        $Subscription,
        [Parameter(Mandatory = $true, ParameterSetName = 'ResourceGroupList')]
        [string[]]
        $ResourceGroupList,
        [Parameter(Mandatory = $true, ParameterSetName = 'VmList')]
        [Parameter(ParameterSetName = 'SingleSubscription')]
        [string]
        $ResourceGroupName,
        [Parameter(Mandatory = $true, ParameterSetName = 'VmList')]
        [string[]]
        $VmList,
        [Parameter(ParameterSetName = 'SingleSubscription')]
        [string]
        $Name,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $FeatureName,
        [Parameter(Mandatory = $true)]
        [bool]
        $EnableFeature,
        [Parameter()]
        [switch]
        $Force)

    #Update Globals
    update-Globals
    
    # Add description for what's happening
    $featureAction = Get-FeatureAction -EnableFeature $EnableFeature
    Write-Verbose "Starting script to $featureAction SQL Server extension feature '$FeatureName'"

    if ($PsCmdlet.ParameterSetName -eq 'SubscriptionList') {
        $subsCompleted = 0
        #loop over all subscriptions to enable feature on VMs
        foreach ($SubscriptionName in $SubscriptionList) {
            [int]$percent = ($subsCompleted * 100) / $SubscriptionList.Count
            Write-Progress -Activity "Configure SQL Extension Feature in $($SubscriptionName) $($subsCompleted+1)/$($SubscriptionList.Count)" `
                -Status "$percent% Complete:" -PercentComplete $percent -CurrentOperation "ConfigureFeatureInSub" -Id 1;
            if (assert-Subscription -Subscription $SubscriptionName) {
                enable-FeatureForSubscription -Subscription $SubscriptionName -FeatureName $FeatureName -EnableFeature $EnableFeature
            }
            $subsCompleted++
        }
        Write-Progress -Activity "Configure SQL Extension Feature" -Status "100% Complete:" -PercentComplete 100 -CurrentOperation "ConfigureFeatureInSub" -Id 1 -Completed;
    }
    elseif (assert-Subscription -Subscription $Subscription) {
        if ($PsCmdlet.ParameterSetName -eq 'ResourceGroupList') {
            $rgsCompleted = 0
            foreach ($RgName in $ResourceGroupList) {
                [int]$percent = ($rgsCompleted * 100) / $ResourceGroupList.Count
                Write-Progress -Activity "Configure SQL Extension Feature in $($RgName) $($rgsCompleted+1)/$($ResourceGroupList.Count)" -Status "$percent% Complete:" -PercentComplete $percent -CurrentOperation "ConfigureFeatureInRG" -Id 1;
                enable-FeatureForSubscription -Subscription $Subscription -ResourceGroup $RgName -FeatureName $FeatureName -EnableFeature $EnableFeature
                $rgsCompleted++
            }
            Write-Progress -Activity "Configure SQL Extension Feature" -Status "100% Complete:" -PercentComplete 100 -CurrentOperation "ConfigureFeatureInRG" -Id 1 -Completed;
        }
        elseif ($PsCmdlet.ParameterSetName -eq 'VmList') {
            $vmsCompleted = 0
            foreach ($VmName in $VmList) {
                [int]$percent = ($vmsCompleted * 100) / $VmList.Count
                Write-Progress -Activity "Configure SQL Extension Feature $($vmsCompleted+1)/$($VmList.Count)" -Status "$percent% Complete:" -PercentComplete $percent -CurrentOperation "ConfigureFeatureInList" -Id 1;
                enable-FeatureForSubscription -Subscription $Subscription `
                    -ResourceGroupName $ResourceGroupName -Name $VmName -FeatureName $FeatureName -EnableFeature $EnableFeature
                $vmsCompleted++
            }
            Write-Progress -Activity "Configure SQL Extension Feature in List" -Status "100% Complete:" -PercentComplete 100 -CurrentOperation "ConfigureFeatureInList" -Id 1 -Completed;
        }
        else {
            enable-FeatureForSubscription -Subscription $Subscription `
                -ResourceGroupName $ResourceGroupName -Name $Name -FeatureName $FeatureName -EnableFeature $EnableFeature
        }
    }

    #Report 
    new-Report
}

#Globals for reporting and logging
$Global:TotalVMs = 0
$Global:AlreadyRegistered = 0
$Global:SubscriptionsFailedToRegister = 0
$Global:SubscriptionsFailedToConnect = [System.Collections.ArrayList]@()
$Global:SubscriptionsFailedToRegister = [System.Collections.ArrayList]@()
$Global:RegisteredVMs = [System.Collections.ArrayList]@()
$Global:FailedVMs = [System.Collections.ArrayList]@()
$Global:SkippedVMs = [System.Collections.ArrayList]@()
$Global:UntriedVMs = [System.Collections.ArrayList]@()
$Global:LogFile = $null
$Global:ReportFile = $null

<#
    .SYNOPSIS
    Reset Global Variables
#>
function update-Globals() {
    [int]$timestamp = Get-Date (Get-Date)  -UFormat %s
    $Global:TotalVMs = 0
    $Global:AlreadyRegistered = 0
    $Global:SubscriptionsFailedToRegister = 0
    $Global:SubscriptionsFailedToConnect = [System.Collections.ArrayList]@()
    $Global:SubscriptionsFailedToRegister = [System.Collections.ArrayList]@()
    $Global:RegisteredVMs = [System.Collections.ArrayList]@()
    $Global:FailedVMs = [System.Collections.ArrayList]@()
    $Global:SkippedVMs = [System.Collections.ArrayList]@()
    $Global:UntriedVMs = [System.Collections.ArrayList]@()
    $Global:LogFile = "SqlExtensionFeatureError" + $timestamp + ".log"
    $Global:ReportFile = "SqlExtensionFeatureReport" + $timestamp + ".txt"
    Remove-Item $Global:LogFile -ErrorAction Ignore
    Remove-Item $Global:ReportFile -ErrorAction Ignore
    $txtLogHeader = "Timestamp,Subscription,[Resource Group],[VM Name],[ErrorCode],Error Message"
    Write-Output $txtLogHeader | Out-File $Global:LogFile -Append
}

<#
    .SYNOPSIS
    Get list of VM in a subscription or resourcegroup

    .PARAMETER ResourceGroupName
    Resource Group whose VMs need to be returned

    .PARAMETER Name
    Name of the VM to be returned

    .OUTPUTS
    System.Collections.ArrayList list of VMs
#>
function getListOfVMswithSqlServerExtension(
    [string] $ResourceGroupName,
    [string] $Name
) {
    $vmList = getVmList -ResourceGroupName $ResourceGroupName -Name $Name
    $vmswithextension = [System.Collections.ArrayList]@()

    # Filter VMs that have the SQL Server extension installed    
    foreach ($vm in $vmList) {
        $extensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name
        if ($extensions | Where-Object -Property ExtensionType -CEQ SqlIaaSAgent) {
            $vmswithextension.Add($vm) | Out-Null
        }
    }
    
    Write-Verbose "Found $($vmswithextension.Count) VMs in with SQL Server extension installed"

    # Return the ArrayList without wrapping in an array
    return $vmswithextension
}


<#
    .SYNOPSIS
    Get list of VM in a subscription or resourcegroup

    .PARAMETER ResourceGroupName
    Resource Group whose VMs need to be returned

    .PARAMETER Name
    Name of the VM to be returned

    .OUTPUTS
    System.Collections.ArrayList list of VMs
#>
function getVmList(
    [string] $ResourceGroupName,
    [string] $Name
) {
    $vmList = [System.Collections.ArrayList]@()
    #if resource group is passed, look inside the group only
    if ($ResourceGroupName) {
        if ($Name) {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
            if ($vm) {
                $vmList.Add($vm) | Out-Null
                Write-Verbose "Found VM: $Name in resource group $ResourceGroupName"
            }
            else {
                Write-Warning "VM '$Name' not found in resource group '$ResourceGroupName'"
            }
        }
        else {
            $vmsInRg = Get-AzVM -ResourceGroupName $ResourceGroupName
            foreach ($vm in $vmsInRg) {
                $vmList.Add($vm) | Out-Null
            }
            Write-Verbose "Found $($vmsInRg.Count) VMs in resource group $ResourceGroupName"
        }
    }
    else {
        $vmsInSub = Get-AzVM
        foreach ($vm in $vmsInSub) {
            $vmList.Add($vm) | Out-Null
        }
        Write-Verbose "Found $($vmsInSub.Count) VMs in subscription"
    }
    
    # Return the ArrayList without wrapping in an array
    return $vmList
}

<#
    .SYNOPSIS
    Logs error and removes dangling SQL VM resources

    .PARAMETER ErrorObject
    Error Object

    .PARAMETER VmObject
    VM for which the error occured
#>
function handleError(
    [Parameter(Mandatory = $true)]
    $ErrorObject,
    $VmObject) {
    # Only log errors for extension configuration
    # Add null checks to prevent errors with null objects
    if ($null -eq $VmObject) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $errorMessage = $ErrorObject.Exception.Message
        $errorCode = if ($ErrorObject.Exception.HResult) { 
            "0x" + [Convert]::ToString($ErrorObject.Exception.HResult, 16) 
        } else { 
            "Unknown" 
        }
        
        # Log with details available
        Write-Output "$($timestamp), Unknown, Unknown, Unknown, $($errorCode), $($errorMessage)" | 
            Out-File $Global:LogFile -Append
        Write-Verbose "Failed to configure feature. Error: $($errorMessage)"
        return
    }
    
    $subID = $VmObject.Id.Split("/")[2]
    $errorMessage = $ErrorObject.Exception.Message
    $errorCode = if ($ErrorObject.Exception.HResult) { 
        "0x" + [Convert]::ToString($ErrorObject.Exception.HResult, 16) 
    } else { 
        "Unknown" 
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Log with more details
    Write-Output "$($timestamp), $($subID), $($VmObject.ResourceGroupName), $($VmObject.Name), $($errorCode), $($errorMessage)" | 
        Out-File $Global:LogFile -Append
    
    # Add to failed VMs and write to console
    $Global:FailedVMs.Add($VmObject) | Out-Null
    Write-Verbose "Failed to configure feature on VM: $($VmObject.Name) in $($VmObject.ResourceGroupName). Error: $($errorMessage)"
}

<#
    .SYNOPSIS
    Creates a new line dashed separator
#>
function new-DashSeperator() {
    Write-Host
    Write-Host "-------------------------------------------------------------------------------"
}

<#
    .SYNOPSIS
    Generates the report
#>
function new-Report() {
    new-DashSeperator
    Write-Host "Summary"
    new-DashSeperator

    if ($Global:SubscriptionsFailedToConnect.count -gt 0) {
        $errorMessage = "Number of Subscriptions failed for because you do not have access or credentials are incorrect: $($Global:SubscriptionsFailedToConnect.count)"
        show-SubscriptionListForError -ErrorMessage $errorMessage -FailedSubList $Global:SubscriptionsFailedToConnect
    }

    if ($Global:SubscriptionsFailedToRegister.count -gt 0) {
        $errorMessage = "Number of Subscriptions that could not be tried because they are not registered to RP: $($Global:SubscriptionsFailedToRegister.count)"
        show-SubscriptionListForError -ErrorMessage $errorMessage -FailedSubList $Global:SubscriptionsFailedToRegister
    }

    $txtTotalVMsFound = "Total VMs Found: $($Global:TotalVMs)" 
    Write-Output $txtTotalVMsFound | Out-File $Global:ReportFile -Append
    Write-Output $txtTotalVMsFound

    $txtAlreadyRegistered = "VMs Already enabled: $($Global:AlreadyRegistered)"
    Write-Output $txtAlreadyRegistered | Out-File $Global:ReportFile -Append
    Write-Output $txtAlreadyRegistered

    #display success
    $txtSuccessful = "Number of VMs configured feature successfully: $($Global:RegisteredVMs.Count)"
    show-VMDetailsInReport -Message $txtSuccessful -VMList $Global:RegisteredVMs

    #display failure
    if ($Global:FailedVMs.Count -gt 0) {
        $txtFailed = "Number of VMs failed to configure feature due to error: $($Global:FailedVMs.Count)"
        show-VMDetailsInReport -Message $txtFailed -VMList $Global:FailedVMs
    }

    #display VMs not tried
    if ($Global:UntriedVMs.Count -gt 0) {
        $txtNotRunning = "Number of VMs skipped as VM or the guest agent on VM is not running: $($Global:UntriedVMs.Count)"
        show-VMDetailsInReport -Message $txtNotRunning -VMList $Global:UntriedVMs
    }

    #display VMs skipped
    if ($Global:SkippedVMs.Count -gt 0) {
        $txtNotSql = "Number of VMs skipped as they are not running SQL Server On Windows: $($Global:SkippedVMs.Count)"
        show-VMDetailsInReport -Message $txtNotSql -VMList $Global:SkippedVMs
    }

    Write-Host
    Write-Host "Please find the detailed report in file $($Global:ReportFile)"
    if (($Global:FailedVMs.count -gt 0) -or ($Global:UntriedVMs.count -gt 0) -or ($Global:SubscriptionsFailedToRegister.count -gt 0) -or ($Global:SubscriptionsFailedToConnect.count -gt 0)) {
        Write-Host "Please find the error details in file $($Global:LogFile)"
    }
    new-DashSeperator
}

<#
    .SYNOPSIS
    Write Details of VM to the report file

    .PARAMETER Message
    Message to be written

    .PARAMETER VMList
    List of VMs
#>
function show-VMDetailsInReport(
    [string]
    $Message,
    [System.Collections.ArrayList]
    $VMList
) {
    Write-Output $Message | Out-File $Global:ReportFile -Append
    Write-Output $Message
    new-ReportHelper -VmArray $VMList | Out-File $Global:ReportFile -Append
}

<#
    .SYNOPSIS
    Registers VMs in a given subscription

    .PARAMETER ErrorMessage
    Description of error

    .PARAMETER FailedSubList
    List of subscriptions
#>
function show-SubscriptionListForError(
    [string]
    $ErrorMessage,
    [System.Collections.ArrayList]
    $FailedSubList
) {
    $txtSubscription = "Subscription"
    $txtSubSeparator = "------------"
    Write-Output $ErrorMessage | Out-File $Global:ReportFile -Append
    Write-Output $ErrorMessage
    Write-Output $txtSubscription | Out-File $Global:ReportFile -Append
    Write-Output $txtSubSeparator | Out-File $Global:ReportFile -Append
    Write-Output $FailedSubList | Out-File $Global:ReportFile -Append
    Write-Output `n | Out-File $Global:ReportFile -Append
}

<#
    .SYNOPSIS
    Helper to Generate the report
#>
function new-ReportHelper(
    [System.Collections.ArrayList]
    $VmArray
) {
    $outputObjectTemplate = New-Object -TypeName psobject
    $outputObjectTemplate | Add-Member -MemberType NoteProperty -Name Subscription -Value $null
    $outputObjectTemplate | Add-Member -MemberType NoteProperty -Name ResourceGroup -Value $null
    $outputObjectTemplate | Add-Member -MemberType NoteProperty -Name VmName -Value $null

    $outputObjectList = [System.Collections.ArrayList]@()

    foreach ($vm in $VmArray) {
        $outputObject = $outputObjectTemplate | Select-Object *
        $outputObject.Subscription = $vm.Id.Split("/")[2]
        $outputObject.ResourceGroup = $vm.ResourceGroupName
        $outputObject.VmName = $vm.Name
        $outputObjectList.Add($outputObject) | Out-Null
    }

    $outputObjectList | Format-Table -AutoSize
}

<#
    .SYNOPSIS
    Successfully connect to subscription

    .PARAMETER Subscription
    Subscription for searching the VM

    .OUTPUTS
    System.Boolean true if successfully connected and RP is registered, else false
#>
function assert-Subscription(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Subscription
) {
    #connect to the subscription using interactive login (MFA compatible)
    $Global:Error.clear()
    Connect-AzAccount -Subscription $Subscription -ErrorAction SilentlyContinue | Out-Null
    if ($Global:Error) {
        $connectionError = $Global:Error[0]
        $errorMessage = "$($Subscription), $($connectionError[0].Exception.Message)"
        Write-Output $errorMessage | Out-File $Global:LogFile -Append
        $Global:SubscriptionsFailedToConnect.Add($Subscription) | Out-Null
        return $false
    }
    
    return $true
}

<#
    .SYNOPSIS
    Registers VMs in a given subscription

    .PARAMETER Subscription
    Subscription for searching the VM

    .PARAMETER ResourceGroupName
    Name of the resourceGroup which needs to be searched for VMs

    .PARAMETER Name
    Name of the VM which is to be registered

    .PARAMETER FeatureName
    Name of the SQL IaaS extension feature to configure

    .PARAMETER EnableFeature
    Boolean value to enable or disable the feature
#>
function enable-FeatureForSubscription (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Subscription,
    [string] $ResourceGroupName,
    [string] $Name,
    [string] $FeatureName,
    [bool] $EnableFeature) {
    $vmList = getListOfVMswithSqlServerExtension -ResourceGroupName $ResourceGroupName -Name $Name
    #update vm count
    $Global:TotalVMs += $vmList.Count
    Write-Verbose "Processing $($vmList.Count) VMs for feature configuration"

    #Retry options
    Set-Variable MAX_RETRIES -option ReadOnly -value 3
    $retryCount = 0
    $retryIfRequired = $true

    # Try enabling feature and retry if required
    while (($retryCount -le $MAX_RETRIES) -and ($vmList.Count -gt 0)) {
        if ($retryCount -gt 0) {
            [int]$percent = ($retryCount * 100) / $MAX_RETRIES
            Write-Progress -Activity "Retrying feature enablement" -Status "$percent% Complete:" `
                -PercentComplete $percent -CurrentOperation "Retrying" -Id 2;
        }
        $retryCount++
        if ($retryCount -eq $MAX_RETRIES) {
            $retryIfRequired = $false 
        }
        
        # Call enableFeatureOnVmList but don't cast the return value to System.Collections.ArrayList
        # since we've changed it to return a simple array
        $vmList = enableFeatureOnVmList -VMList $vmList -RetryIfRequired $retryIfRequired `
            -FeatureName $FeatureName -EnableFeature $EnableFeature
        
        # Safety check - if $vmList is null, create an empty array
        if ($null -eq $vmList) {
            $vmList = @()
            Write-Verbose "No VMs to retry"
        }
        
        if (($vmList.Count -eq 0) -or ($retryCount -eq $MAX_RETRIES )) {
            Write-Progress -Activity "Retrying feature enablement" -Status "100% Complete:" `
                -PercentComplete 100 -CurrentOperation "Retrying" -Completed -Id 2;
        }
    }
}

<#
    .SYNOPSIS
    Given a list of VMs, configure SQL IaaS extension features

    .PARAMETER VMList
    List of Compute VMs for which SQL VM is to be created

    .PARAMETER RetryIfRequired
    Flag to specify if resource creation needs to be retried

    .OUTPUTS
    System.Collections.ArrayList List of VMs whose creation failed with retryable errors
#>
function enableFeatureOnVmList(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [array]
    $VMList,
    [bool]
    $RetryIfRequired = $false,
    [string]
    $FeatureName,
    [bool]
    $EnableFeature) {
    $retryableVMs = [System.Collections.ArrayList]@()
    
    # Handle empty VM list gracefully
    if ($null -eq $VMList -or $VMList.Count -eq 0) {
        Write-Verbose "No VMs to process"
        return $retryableVMs
    }
    
    [Int32]$numberOfVMs = $VMList.Count
    $completed = 0
    
    # Show more detailed information about what feature is being configured
    $featureAction = Get-FeatureAction -EnableFeature $EnableFeature -Capitalize $true
    Write-Progress -Activity "$featureAction feature '$FeatureName'" -Status "0% Complete:" `
        -PercentComplete 0 -CurrentOperation "ConfiguringFeature" -Id 3
    Write-Verbose "Starting to $($featureAction.ToLower()) feature '$FeatureName' for $numberOfVMs VMs"

    foreach ($vm in $VMList) {
        [int]$percent = ($completed * 100) / $numberOfVMs
        $featureAction = Get-FeatureAction -EnableFeature $EnableFeature -Capitalize $true
        $vmInfo = "$($vm.Name) ($($completed+1)/$($VMList.count))"
        Write-Progress -Activity "$featureAction feature '$FeatureName'" -Status "$percent% Complete:" `
            -PercentComplete $percent -CurrentOperation $vmInfo -Id 3
        Write-Verbose "Processing VM $vmInfo"

        $name = $vm.Name
        $resourceGroupName = $vm.ResourceGroupName
        $location = $vm.Location
        $publisher = 'Microsoft.SqlServer.Management'
        $extensionType = 'SqlIaaSAgent'
        $typeHandlerVersion = '2.0'
        $extensionName = 'SqlIaasExtension'

        $Global:Error.Clear()
        try {
            $settingstring = get-SqlFeatureSettingString -FeatureName $FeatureName -EnableFeature $EnableFeature
            $jobScript = {
                param($resourceGroupName, $location, $name, $extensionName, $publisher, 
                      $extensionType, $typeHandlerVersion, $settingstring)
                
                Set-AzVMExtension -ResourceGroupName $resourceGroupName -Location $location -VMName $name `
                                 -Name $extensionName -Publisher $publisher -Type $extensionType `
                                 -TypeHandlerVersion $typeHandlerVersion -SettingString $settingstring `
                                 -ErrorAction Stop
            }

            # 10 minute timeout (adjust as needed)
            $job = Start-Job -ScriptBlock $jobScript -ArgumentList $resourceGroupName, $location, $name, `
                $extensionName, $publisher, $extensionType, $typeHandlerVersion, $settingstring
            $jobResult = $job | Wait-Job -Timeout 600
            
            if ($jobResult.State -eq 'Completed') {
                # Discard the result but check for errors - we don't need the PSAzureOperationResponse
                Receive-Job -Job $job -ErrorAction Stop | Out-Null
                Remove-Job -Job $job -Force
                $Global:RegisteredVMs.Add($vm) | Out-Null
                Write-Verbose "Successfully configured feature on VM $($vm.Name)"
            }
            elseif ($jobResult.State -eq 'Failed') {
                $jobError = Receive-Job -Job $job -ErrorVariable jobErr -ErrorAction SilentlyContinue
                Remove-Job -Job $job -Force
                if ($jobErr.Count -gt 0) {
                    throw $jobErr[0]
                } else {
                    throw "Job failed but no error details were returned"
                }
            }
            else {
                Stop-Job -Job $job
                Remove-Job -Job $job -Force
                throw "Operation timed out after 10 minutes for VM $($vm.Name)"
            }
        } catch {
            $LastError = $_
            handleError -ErrorObject $LastError -VmObject $vm
        }
        $completed++
    }
    Write-Progress -Activity "Configure SQL Extension Feature" -Completed -CurrentOperation "ConfiguringFeature" -Id 3
    
    # Return an array of VMs that need retry (could be empty)
    if ($retryableVMs.Count -gt 0) {
        Write-Verbose "Returning $($retryableVMs.Count) VMs for retry"
        return $retryableVMs.ToArray()
    } else {
        Write-Verbose "No VMs need retry"
        return @()
    }
}

<#
    .SYNOPSIS
    Generate the settings string for the SQL IaaS extension configuration

    .PARAMETER FeatureName
    Name of the SQL IaaS extension feature to configure

    .PARAMETER EnableFeature
    Boolean value to enable or disable the feature

    .OUTPUTS
    System.String JSON configuration string for the SQL IaaS extension
#>
function get-SqlFeatureSettingString(
    [Parameter(Mandatory = $true)]
    [string]
    $FeatureName,
    [Parameter(Mandatory = $true)]
    [bool]
    $EnableFeature) {
    
    # Conditionally include SqlManagement setting only when enabling a feature
    if ($EnableFeature) {
        return @"
{
    "FeatureFlags": [{"Enable":$($EnableFeature.ToString().ToLower()), "Name":"$FeatureName"}],
    "SqlManagement": {"IsEnabled": true}
}
"@
    } else {
        return @"
{
    "FeatureFlags": [{"Enable":$($EnableFeature.ToString().ToLower()), "Name":"$FeatureName"}]
}
"@
    }
}

<#
    .SYNOPSIS
    Returns the appropriate action text based on the EnableFeature flag

    .PARAMETER EnableFeature
    Boolean flag indicating whether the feature is being enabled or disabled

    .PARAMETER Capitalize
    When true, returns "Enabling"/"Disabling", otherwise returns "enable"/"disable"

    .OUTPUTS
    System.String Action text ("enable", "disable", "Enabling", or "Disabling")
#>
function Get-FeatureAction(
    [Parameter(Mandatory = $true)]
    [bool]
    $EnableFeature,
    [Parameter()]
    [bool]
    $Capitalize = $false) {
    
    if ($Capitalize) {
        if ($EnableFeature) {
            return "Enabling"
        } else {
            return "Disabling"
        }
    } else {
        if ($EnableFeature) { 
            return "enable"
        } else {
            return "disable"
        }
    }
}
