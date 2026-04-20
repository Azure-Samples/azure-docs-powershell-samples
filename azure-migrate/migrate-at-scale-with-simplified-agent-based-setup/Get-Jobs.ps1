#Azure Migrate/ASR - Get Replication Jobs Script
#requires -Version 7 -module Az.Accounts

param (
    [Parameter(Mandatory=$true)][string]$CsvPath,            # Path to CSV file with vault details.
    [Parameter(Mandatory=$false)][string]$StartTime  = ((Get-Date).AddDays(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")),
    [Parameter(Mandatory=$false)][string]$EndTime    = ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")),
    [Parameter(Mandatory=$false)][string]$OutputCsvPath = ".\jobs_output.csv"
)

# Check if user is logged in to Azure, if not prompt to login.
if (Get-AzContext) {
    Write-Host "`n`rAlready logged in to Azure`n"
    Write-Host (Get-AzContext).Subscription.Name
}
else {
    Write-Host "`nNot logged in to Azure. Please login."
    Connect-AzAccount
}

if (-not (Test-Path $CsvPath)) {
    Write-Host "CSV file not found: $CsvPath" -ForegroundColor Red
    return
}

function getreplicationjobs {
    param(
        [Parameter(Mandatory=$true)][string]$CsvPath,
        [string]$StartTime,
        [string]$EndTime,
        [string]$OutputCsvPath
    )

    $csvRows = Import-Csv -Path $CsvPath
    Write-Host "Loaded $($csvRows.Count) machine(s) from CSV: $CsvPath" -ForegroundColor Cyan

    # Use first row's vault info (same vault assumed for all rows)
    $firstRow = $csvRows[0]
    $subscriptionId = $firstRow.VAULT_SUBSCRIPTION_ID
    $resourceGroup  = $firstRow.VAULT_RESOURCE_GROUP
    $vaultName      = $firstRow.VAULT_NAME

    $filter = "StartTime eq '$StartTime' and EndTime eq '$EndTime'"
    $encodedFilter = [System.Uri]::EscapeDataString($filter)
    $uri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/replicationJobs?`$filter=$encodedFilter&api-version=2025-08-01"

    Write-Host "Fetching replication jobs for vault: $vaultName" -ForegroundColor Cyan
    Write-Host "Time range: $StartTime to $EndTime" -ForegroundColor Cyan

    $res = Invoke-AzRestMethod -Method GET -Path $uri
    if ($res.StatusCode -ne 200) {
        Write-Host "Failed to retrieve replication jobs. Status: $($res.StatusCode)" -ForegroundColor Red
        Write-Host "Response: $($res.Content)" -ForegroundColor Red
        return
    }

    $jobs = ($res.Content | ConvertFrom-Json).value
    if (-not $jobs -or $jobs.Count -eq 0) {
        Write-Host "No replication jobs found for the specified time range." -ForegroundColor Yellow
        return
    }

    Write-Host "Found $($jobs.Count) job(s).`n" -ForegroundColor Green

    $results = @()
    foreach ($job in $jobs) {
        $props = $job.properties

        # Calculate duration
        $duration = ""
        if ($props.startTime -and $props.endTime) {
            $span = [datetime]$props.endTime - [datetime]$props.startTime
            $duration = "{0:D2}:{1:D2}:{2:D2}" -f [int]$span.TotalHours, $span.Minutes, $span.Seconds
        }
        elseif ($props.startTime) {
            $duration = "In Progress"
        }

        $results += [PSCustomObject]@{
            Name         = $props.friendlyName
            Status       = $props.status
            Type         = $props.scenarioName
            Item         = $props.targetObjectName
            "Start Time" = $props.startTime
            Duration     = $duration
        }
    }

    # Display results in console
    $results | Format-Table -AutoSize

    # Export to CSV
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Output CSV written to: $OutputCsvPath" -ForegroundColor Cyan
}

# Run get jobs
getreplicationjobs -CsvPath $CsvPath -StartTime $StartTime -EndTime $EndTime -OutputCsvPath $OutputCsvPath
