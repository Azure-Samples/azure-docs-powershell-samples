param(
    [Parameter(Mandatory)]
    [string]$ClusterAddress,

    [Parameter(Mandatory)]
    [string]$VserverName,

    [Parameter(Mandatory)]
    [string]$VolumeName,

    [Parameter(Mandatory)]
    [string]$AnfDestinationVolumeResourceId,

    [PSCredential]$Credential,

    [switch]$ApplyChanges,

    [string]$AnfApiVersion = "2025-05-01-preview",

    [string]$ArmAccessToken,

    [int]$ArmAsyncTimeoutMinutes = 60,

    [int]$ArmAsyncPollSeconds = 30,

    [int]$ElasticSizingTimeoutMinutes = 30,

    [int]$ElasticSizingPollSeconds = 20,

    [switch]$NonInteractive,

    [ValidateRange(0, 100)]
    [int]$DownsizeHeadroomPercent = 3,

    [ValidateRange(1, 20)]
    [int]$DebloatRounds = 3,

    [int]$DebloatWaitSeconds = 300
)

if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter ONTAP admin credentials"
}

$pair = "{0}:{1}" -f $Credential.UserName, $Credential.GetNetworkCredential().Password
$authHeader = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
$baseUrl = "https://${ClusterAddress}/api"

function Invoke-OntapApi {
    param([string]$Path, [string]$Method = "GET", [object]$Body)
    $params = @{
        Uri                = "${baseUrl}${Path}"
        Headers            = $authHeader
        Method             = $Method
        SkipCertificateCheck = $true
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }
    Invoke-RestMethod @params
}

function Confirm-Step {
    param([string]$Message)
    if ($DryRun) {
        Write-Host "[DryRun] Would prompt: $Message (auto-yes)"
        return $true
    }

    if ($NonInteractive) {
        Write-Host "[NonInteractive] Auto-approving: $Message"
        return $true
    }

    $confirm = Read-Host $Message
    return $confirm -eq "y"
}

function Get-ArmAccessToken {
    if ($ArmAccessToken) {
        return $ArmAccessToken
    }

    if (Get-Command az -ErrorAction SilentlyContinue) {
        $token = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
        if ($LASTEXITCODE -eq 0 -and $token) {
            return $token
        }
    }

    throw "Failed to get ARM access token. Provide -ArmAccessToken or run 'az login' first."
}

function Wait-ArmAsyncOperation {
    param(
        [string]$AsyncUrl,
        [hashtable]$Headers,
        [int]$TimeoutMinutes,
        [int]$PollSeconds
    )

    Write-Host ""
    Write-Host ("Polling Azure-AsyncOperation for up to {0} minutes..." -f $TimeoutMinutes)
    Write-Host ("  URL: {0}" -f $AsyncUrl)

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $statusResponse = Invoke-RestMethod -Method GET -Uri $AsyncUrl -Headers $Headers -SkipCertificateCheck
        $status = $statusResponse.status
        Write-Host ("  Async status: {0}" -f $status)

        if ($status -eq "Succeeded") {
            Write-Host "ANF replication transfer completed." -ForegroundColor Green
            return $true
        }

        if (($status -eq "Failed") -or ($status -eq "Canceled")) {
            $errorJson = $statusResponse.error | ConvertTo-Json -Depth 10 -Compress
            throw "ANF replication transfer ended with status '$status'. Details: $errorJson"
        }
    }

    throw ("Timed out waiting for async completion after {0} minutes." -f $TimeoutMinutes)
}

function Get-AnfReplicationStatus {
    param([object]$VolumeResponse)
    $replication = $VolumeResponse.properties.dataProtection.replication
    if (-not $replication) {
        return $null
    }

    if ($replication.replicationStatus) { return $replication.replicationStatus }
    if ($replication.relationshipStatus) { return $replication.relationshipStatus }
    if ($replication.mirrorState) { return $replication.mirrorState }
    return $null
}

$DryRun = -not $ApplyChanges

Write-Host "Connected to $ClusterAddress"
if ($DryRun) {
    Write-Host "Running in DRY-RUN mode: no changes will be made." -ForegroundColor Yellow
} else {
    Write-Host "Apply mode requested: this run can mutate ONTAP state." -ForegroundColor Yellow
    if ($NonInteractive) {
        Write-Host "[NonInteractive] Skipping upfront apply confirmation." -ForegroundColor Yellow
    } else {
        $finalConfirm = Read-Host "Type yes to continue with APPLY mode"
        if ($finalConfirm -ne "yes") {
            Write-Host "Apply confirmation not provided. Switching to DRY-RUN mode." -ForegroundColor Yellow
            $DryRun = $true
        }
    }
}

# Step 1: Show FlexGroup summary (informational only)
$volResponse = Invoke-OntapApi "/storage/volumes?name=${VolumeName}&svm.name=${VserverName}&fields=space,style"
$vol = $volResponse.records | Select-Object -First 1

if (-not $vol) {
    Write-Error "Volume '$VolumeName' not found on vserver '$VserverName'."
    exit 1
}

if ($vol.style -ne "flexgroup") {
    Write-Warning "Volume '$VolumeName' is not a FlexGroup (style: $($vol.style))."
}

$s = $vol.space
$totalSize = $s.size
$logicalUsed = $s.logical_space.used
$logicalPct = if ($totalSize -gt 0) { [math]::Round($logicalUsed / $totalSize * 100, 2) } else { 0 }

Write-Host ""
Write-Host "Volume:              $VolumeName"
Write-Host "Vserver:             $VserverName"
Write-Host "Style:               $($vol.style)"
Write-Host "Total Size (GB):     $([math]::Round($totalSize / 1GB, 2))"
Write-Host "Logical Used (GB):   $([math]::Round($logicalUsed / 1GB, 2))"
Write-Host "Logical Used (%):    $logicalPct%"
Write-Host ""
Write-Host "Proceeding with constituent-level checks (FlexGroup-level usage is informational)." -ForegroundColor Yellow

# Step 2: Upsize overprovisioned constituents (+10% headroom)
$volUuid = $vol.uuid
$constResponse = Invoke-OntapApi "/storage/volumes?is_constituent=true&flexgroup.uuid=${volUuid}&fields=space&max_records=500"
$constituents = $constResponse.records

if (-not $constituents -or $constituents.Count -eq 0) {
    Write-Error "No constituent volumes found for FlexGroup '$VolumeName'."
    exit 1
}

Write-Host ""
Write-Host "Found $($constituents.Count) constituent(s). Checking each for overprovisioning..."
Write-Host ""

$needsResize = @()
$plannedUpsizeByUuid = @{}
$overprovisionedNames = @{}

foreach ($c in $constituents) {
    $cs = $c.space
    $cTotal = $cs.size
    $cLogical = $cs.logical_space.used
    $cPct = if ($cTotal -gt 0) { [math]::Round($cLogical / $cTotal * 100, 2) } else { 0 }

    $status = if ($cPct -gt 100) { "OVER" } else { "OK" }
    Write-Host ("  {0,-40} Total: {1,10:N2} GB  Logical: {2,10:N2} GB  ({3}%) [{4}]" -f `
        $c.name, ($cTotal / 1GB), ($cLogical / 1GB), $cPct, $status)

    if ($cPct -gt 100) {
        $plannedUpsize = [math]::Ceiling($cLogical / 1GB * 1.1) * 1GB
        $plannedUpsizeByUuid[$c.uuid] = $plannedUpsize
        $overprovisionedNames[$c.name] = $true
        $needsResize += [PSCustomObject]@{
            Uuid         = $c.uuid
            Name         = $c.name
            OriginalSize = $cTotal
            LogicalUsed  = $cLogical
            UsedPct      = $cPct
        }
    }
}

$bloatedCvNames = @()
foreach ($c in $constituents) {
    if (-not $overprovisionedNames.ContainsKey($c.name)) {
        $bloatedCvNames += $c.name
    }
}

Write-Host ""

Write-Host ("Constituents over 100% logical: {0}/{1}" -f $needsResize.Count, $constituents.Count) -ForegroundColor Yellow
Write-Host ""

if ($needsResize.Count -eq 0) {
    Write-Host "No constituents exceed 100% logical usage. No pre-LSE resizing needed." -ForegroundColor Green
    exit 0
}

Write-Host "$($needsResize.Count) constituent(s) need resizing:" -ForegroundColor Yellow
Write-Host ""

foreach ($r in $needsResize) {
    $newSize = $plannedUpsizeByUuid[$r.Uuid]
    Write-Host ("  {0}: {1:N2} GB -> {2:N2} GB (logical used: {3:N2} GB, {4}%)" -f `
        $r.Name, `
        ($r.OriginalSize / 1GB), `
        ($newSize / 1GB), `
        ($r.LogicalUsed / 1GB), `
        $r.UsedPct)
}

Write-Host ""
if (-not (Confirm-Step "Proceed with resizing? (y/N)")) {
    Write-Host "Aborted."
    exit 0
}

foreach ($r in $needsResize) {
    $newSize = $plannedUpsizeByUuid[$r.Uuid]
    Write-Host "Resizing $($r.Name) to $([math]::Round($newSize / 1GB, 2)) GB..."
    if ($DryRun) {
        Write-Host "  [DryRun] Would PATCH /storage/volumes/$($r.Uuid) with space.size=$newSize"
    } else {
        Invoke-OntapApi "/storage/volumes/$($r.Uuid)" -Method PATCH -Body @{ space = @{ size = $newSize } }
    }
    Write-Host "  Done." -ForegroundColor Green
}

Write-Host ""
Write-Host "All overprovisioned constituents have been resized." -ForegroundColor Green

# Step 3: Enable Logical Space Enforcement (LSE) on the FlexGroup volume
Write-Host ""
Write-Host "Checking Logical Space Enforcement (LSE) on '$VolumeName'..."

$volResponse = Invoke-OntapApi "/storage/volumes?name=${VolumeName}&svm.name=${VserverName}&fields=space"
$vol = $volResponse.records | Select-Object -First 1
$lseEnabled = $vol.space.logical_space.enforcement

if ($lseEnabled) {
    Write-Host "LSE is already enabled on '$VolumeName'." -ForegroundColor Green
} else {
    Write-Host "LSE is currently disabled on '$VolumeName'."
    if (-not (Confirm-Step "Enable Logical Space Enforcement? (y/N)")) {
        Write-Host "Skipped enabling LSE."
    } else {
        Write-Host "Enabling LSE on '$VolumeName'..."
        if ($DryRun) {
            Write-Host "  [DryRun] Would PATCH /storage/volumes/$($vol.uuid) with logical_space.enforcement=true"
        } else {
            Invoke-OntapApi "/storage/volumes/$($vol.uuid)" -Method PATCH -Body @{ space = @{ logical_space = @{ enforcement = $true } } }
        }
        Write-Host "LSE enabled on '$VolumeName'." -ForegroundColor Green
    }
}

# Step 4: Wait for elastic sizing to be complete on affected constituents
Write-Host ""
Write-Host "Waiting for elastic sizing to complete on affected constituents..."
if ($DryRun) {
    Write-Host "[DryRun] Would poll constituent sizes/logical usage until sizing settles."
} else {
    $elasticDeadline = (Get-Date).AddMinutes($ElasticSizingTimeoutMinutes)
    $elasticDone = $false
    while ((Get-Date) -lt $elasticDeadline) {
        Start-Sleep -Seconds $ElasticSizingPollSeconds
        $currentConst = Invoke-OntapApi "/storage/volumes?is_constituent=true&flexgroup.uuid=${volUuid}&fields=space&max_records=500"
        $recordsByUuid = @{}
        foreach ($item in $currentConst.records) { $recordsByUuid[$item.uuid] = $item }

        $pending = @()
        foreach ($r in $needsResize) {
            $cur = $recordsByUuid[$r.Uuid]
            if (-not $cur) {
                $pending += $r.Name
                continue
            }
            $curSize = $cur.space.size
            $curLogical = $cur.space.logical_space.used
            $curPct = if ($curSize -gt 0) { [math]::Round($curLogical / $curSize * 100, 2) } else { 0 }
            $targetSize = $plannedUpsizeByUuid[$r.Uuid]
            $sized = $curSize -ge $targetSize
            if (-not $sized -or $curPct -gt 100) {
                $pending += $r.Name
            }
        }

        if ($pending.Count -eq 0) {
            Write-Host "Elastic sizing completed for all affected constituents." -ForegroundColor Green
            $elasticDone = $true
            break
        }

        Write-Host ("Still waiting on: {0}" -f ($pending -join ", "))
    }

    if (-not $elasticDone) {
        throw "Elastic sizing did not complete within ${ElasticSizingTimeoutMinutes} minutes."
    }
}

# Step 5: PerformReplicationTransfer to ANF
Write-Host ""
Write-Host "Preparing ANF replication transfer request..."

$performTransferUri = "https://management.azure.com${AnfDestinationVolumeResourceId}/performReplicationTransfer?api-version=${AnfApiVersion}"
Write-Host ("  Target ANF volume: {0}" -f $AnfDestinationVolumeResourceId)
Write-Host ("  API version:       {0}" -f $AnfApiVersion)
Write-Host ""

$transferTriggered = $false
if (-not (Confirm-Step "Trigger ANF PerformReplicationTransfer? (y/N)")) {
    Write-Host "Skipped ANF replication transfer."
} else {
    Write-Host "Starting ANF PerformReplicationTransfer..."
    if ($DryRun) {
        Write-Host "  [DryRun] Would POST $performTransferUri"
        Write-Host "ANF replication transfer simulated." -ForegroundColor Green
        $transferTriggered = $true
    } else {
        $armToken = Get-ArmAccessToken
        $armHeaders = @{
            Authorization = "Bearer $armToken"
            "Content-Type" = "application/json"
        }
        $response = Invoke-WebRequest -Method POST -Uri $performTransferUri -Headers $armHeaders -Body "{}"
        Write-Host ("ANF PerformReplicationTransfer submitted. HTTP {0}" -f $response.StatusCode) -ForegroundColor Green
        if ($response.Headers["Azure-AsyncOperation"]) {
            $asyncUrl = $response.Headers["Azure-AsyncOperation"]
            Write-Host ("  Azure-AsyncOperation: {0}" -f $asyncUrl)
            Wait-ArmAsyncOperation -AsyncUrl $asyncUrl -Headers $armHeaders -TimeoutMinutes $ArmAsyncTimeoutMinutes -PollSeconds $ArmAsyncPollSeconds | Out-Null
        }
        if ($response.Headers["Location"]) {
            Write-Host ("  Location:            {0}" -f $response.Headers["Location"])
        }
        $transferTriggered = $true
    }
}

# Step 6: Break replication
Write-Host ""
$breakReplicationUri = "https://management.azure.com${AnfDestinationVolumeResourceId}/breakReplication?api-version=${AnfApiVersion}"
Write-Host ("Preparing ANF breakReplication request for: {0}" -f $AnfDestinationVolumeResourceId)
$breakTriggered = $false
if (-not $transferTriggered) {
    Write-Host "Skipping break replication because transfer was not triggered." -ForegroundColor Yellow
} elseif (-not (Confirm-Step "Trigger ANF breakReplication? (y/N)")) {
    Write-Host "Skipped break replication."
} else {
    if ($DryRun) {
        Write-Host ("  [DryRun] Would POST {0}" -f $breakReplicationUri)
        $breakTriggered = $true
    } else {
        $armToken = Get-ArmAccessToken
        $armHeaders = @{
            Authorization = "Bearer $armToken"
            "Content-Type" = "application/json"
        }
        $breakResponse = Invoke-WebRequest -Method POST -Uri $breakReplicationUri -Headers $armHeaders -Body "{}"
        Write-Host ("ANF breakReplication submitted. HTTP {0}" -f $breakResponse.StatusCode) -ForegroundColor Green
        if ($breakResponse.Headers["Azure-AsyncOperation"]) {
            $breakAsyncUrl = $breakResponse.Headers["Azure-AsyncOperation"]
            Write-Host ("  Azure-AsyncOperation: {0}" -f $breakAsyncUrl)
            Wait-ArmAsyncOperation -AsyncUrl $breakAsyncUrl -Headers $armHeaders -TimeoutMinutes $ArmAsyncTimeoutMinutes -PollSeconds $ArmAsyncPollSeconds | Out-Null
        }
        $breakTriggered = $true
    }
}

# Step 7: Wait for replication status to be broken off
Write-Host ""
Write-Host "Waiting for replication status to reach broken state..."
if (-not $breakTriggered) {
    Write-Host "Skipping broken-state wait because breakReplication was not executed." -ForegroundColor Yellow
} elseif ($DryRun) {
    Write-Host "[DryRun] Would poll destination volume replication status until broken."
} else {
    $armToken = Get-ArmAccessToken
    $armHeaders = @{
        Authorization = "Bearer $armToken"
        "Content-Type" = "application/json"
    }
    $volumeUri = "https://management.azure.com${AnfDestinationVolumeResourceId}?api-version=${AnfApiVersion}"
    $statusDeadline = (Get-Date).AddMinutes($ArmAsyncTimeoutMinutes)
    $broken = $false
    while ((Get-Date) -lt $statusDeadline) {
        Start-Sleep -Seconds $ArmAsyncPollSeconds
        $anfVolume = Invoke-RestMethod -Method GET -Uri $volumeUri -Headers $armHeaders -SkipCertificateCheck
        $replicationStatus = Get-AnfReplicationStatus -VolumeResponse $anfVolume
        Write-Host ("  Replication status: {0}" -f $replicationStatus)
        if ($replicationStatus -and ($replicationStatus -match "(?i)broken")) {
            Write-Host "Replication is now broken off." -ForegroundColor Green
            $broken = $true
            break
        }
    }
    if (-not $broken) {
        throw "Replication status did not reach broken state within timeout."
    }
}

# Step 8: Disable LSE
Write-Host ""
Write-Host "Disabling Logical Space Enforcement (LSE) on '$VolumeName'..."

$volResponse = Invoke-OntapApi "/storage/volumes?name=${VolumeName}&svm.name=${VserverName}&fields=space"
$vol = $volResponse.records | Select-Object -First 1
$lseEnabled = $vol.space.logical_space.enforcement

if (-not $lseEnabled) {
    Write-Host "LSE is already disabled on '$VolumeName'." -ForegroundColor Green
} else {
    if ($DryRun) {
        Write-Host "  [DryRun] Would PATCH /storage/volumes/$($vol.uuid) with logical_space.enforcement=false"
    } else {
        Invoke-OntapApi "/storage/volumes/$($vol.uuid)" -Method PATCH -Body @{ space = @{ logical_space = @{ enforcement = $false } } }
    }
    Write-Host "LSE disabled on '$VolumeName'." -ForegroundColor Green
}

# Step 9: Debloat robin-hood CVs (non-overprovisioned constituents that got inflated)
Write-Host ""
Write-Host "=== Debloating robin-hood constituents ===" -ForegroundColor Yellow
Write-Host ""

if ($bloatedCvNames.Count -eq 0) {
    Write-Host "No non-overprovisioned constituents to debloat." -ForegroundColor Green
} else {
    Write-Host ("Bloated constituents to shrink: {0}" -f ($bloatedCvNames -join ", "))
    Write-Host ("Strategy: resize to 1 GB, wait {0}s for ONTAP elastic rebalance, check sizes, repeat." -f $DebloatWaitSeconds)
    Write-Host ""

    $maxRounds = if ($NonInteractive) { $DebloatRounds } else { 999 }
    $round = 0

    while ($round -lt $maxRounds) {
        $round++
        Write-Host ("--- Debloat round {0} ---" -f $round)

        $currentConst = Invoke-OntapApi "/storage/volumes?is_constituent=true&flexgroup.uuid=${volUuid}&fields=space&max_records=500"
        $recordsByName = @{}
        foreach ($item in $currentConst.records) { $recordsByName[$item.name] = $item }

        $debloatTargets = @()
        foreach ($name in $bloatedCvNames) {
            $cv = $recordsByName[$name]
            if (-not $cv) {
                Write-Warning "Could not find constituent: $name"
                continue
            }
            $cvSize = $cv.space.size
            $cvLogical = $cv.space.logical_space.used
            $cvPct = if ($cvSize -gt 0) { [math]::Round($cvLogical / $cvSize * 100, 2) } else { 0 }
            Write-Host ("  {0}: size={1:N2} GB, logical={2:N2} GB ({3}%)" -f $name, ($cvSize / 1GB), ($cvLogical / 1GB), $cvPct)

            if ($cvSize -gt 1GB) {
                $debloatTargets += [PSCustomObject]@{
                    Uuid = $cv.uuid
                    Name = $name
                    CurrentSize = $cvSize
                }
            }
        }

        if ($debloatTargets.Count -eq 0) {
            Write-Host "All bloated constituents are already at 1 GB or smaller." -ForegroundColor Green
            break
        }

        if (-not (Confirm-Step "Shrink $($debloatTargets.Count) constituent(s) to 1 GB? (y/N)")) {
            Write-Host "Debloat skipped by user."
            break
        }

        foreach ($t in $debloatTargets) {
            Write-Host ("  Shrinking {0}: {1:N2} GB -> 1.00 GB..." -f $t.Name, ($t.CurrentSize / 1GB))
            if ($DryRun) {
                Write-Host "    [DryRun] Would PATCH /storage/volumes/$($t.Uuid) with space.size=1073741824"
            } else {
                Invoke-OntapApi "/storage/volumes/$($t.Uuid)" -Method PATCH -Body @{ space = @{ size = 1073741824 } }
            }
            Write-Host "    Done." -ForegroundColor Green
        }

        Write-Host ""
        Write-Host ("Waiting {0} seconds for ONTAP elastic rebalance..." -f $DebloatWaitSeconds)
        if (-not $DryRun) {
            Start-Sleep -Seconds $DebloatWaitSeconds
        } else {
            Write-Host "[DryRun] Would wait $DebloatWaitSeconds seconds."
        }

        Write-Host ""
        Write-Host "Re-checking constituent sizes after rebalance..."
        $postConst = Invoke-OntapApi "/storage/volumes?is_constituent=true&flexgroup.uuid=${volUuid}&fields=space&max_records=500"
        $postByName = @{}
        foreach ($item in $postConst.records) { $postByName[$item.name] = $item }

        $allSettled = $true
        foreach ($name in $bloatedCvNames) {
            $cv = $postByName[$name]
            if (-not $cv) { continue }
            $cvSize = $cv.space.size
            $cvLogical = $cv.space.logical_space.used
            $cvPct = if ($cvSize -gt 0) { [math]::Round($cvLogical / $cvSize * 100, 2) } else { 0 }
            Write-Host ("  {0}: size={1:N2} GB, logical={2:N2} GB ({3}%)" -f $name, ($cvSize / 1GB), ($cvLogical / 1GB), $cvPct)
            if ($cvSize -gt 2GB) { $allSettled = $false }
        }

        if ($allSettled) {
            Write-Host "Bloated constituents have settled to reasonable sizes." -ForegroundColor Green
            break
        }

        if ($NonInteractive) {
            if ($round -ge $maxRounds) {
                Write-Warning ("Reached max debloat rounds ({0}). Constituents may still be larger than expected." -f $maxRounds)
            } else {
                Write-Host "Non-interactive: proceeding to next round..."
            }
        } else {
            if (-not (Confirm-Step "Run another debloat round? (y/N)")) {
                Write-Host "Debloat stopped by user."
                break
            }
        }
    }
}

Write-Host ""
Write-Host "Debloat phase complete." -ForegroundColor Green

# Step 10: Downsize overprovisioned constituents back to reasonable sizes (interactively repeatable)
Write-Host ""
Write-Host "=== Downsizing previously-overprovisioned constituents ===" -ForegroundColor Yellow
Write-Host ""

$repeatDownsize = $true
while ($repeatDownsize) {
    $headroomPercent = $DownsizeHeadroomPercent
    if ((-not $DryRun) -and (-not $NonInteractive)) {
        $headroomInput = Read-Host "Enter desired logical headroom percent for downsizing (default 3)"
        if ($headroomInput -and ($headroomInput -as [int]) -ge 0) {
            $headroomPercent = [int]$headroomInput
        }
    }

    $downsizePlan = @()
    $currentConst = Invoke-OntapApi "/storage/volumes?is_constituent=true&flexgroup.uuid=${volUuid}&fields=space&max_records=500"
    $recordsByName = @{}
    foreach ($item in $currentConst.records) {
        $recordsByName[$item.name] = $item
    }

    foreach ($r in $needsResize) {
        $current = $recordsByName[$r.Name]
        if (-not $current) {
            Write-Warning ("Could not find constituent by name during downsize planning: {0}" -f $r.Name)
            continue
        }

        $currentUuid = $current.uuid
        $curSize = $current.space.size
        $curLogical = $current.space.logical_space.used
        $minReasonable = [math]::Ceiling($curLogical / 1GB * (1 + ($headroomPercent / 100.0))) * 1GB
        $target = [Math]::Max($minReasonable, $r.OriginalSize)
        if ($target -lt $curSize) {
            $downsizePlan += [PSCustomObject]@{
                Uuid = $currentUuid
                Name = $r.Name
                CurrentSize = $curSize
                TargetSize = $target
            }
        } else {
            Write-Host ("  {0}: current size already <= reasonable target; skipping" -f $r.Name)
        }
    }

    if ($downsizePlan.Count -eq 0) {
        Write-Host "No constituents require downsizing for the selected headroom." -ForegroundColor Green
        break
    }

    Write-Host ""
    Write-Host ("Downsize plan (headroom {0}%):" -f $headroomPercent)
    foreach ($d in $downsizePlan) {
        Write-Host ("  {0}: {1:N2} GB -> {2:N2} GB" -f $d.Name, ($d.CurrentSize / 1GB), ($d.TargetSize / 1GB))
    }

    if (-not (Confirm-Step "Proceed with downsizing pass? (y/N)")) {
        Write-Host "Skipped downsizing pass."
        break
    }

    foreach ($d in $downsizePlan) {
        Write-Host "Downsizing $($d.Name) to $([math]::Round($d.TargetSize / 1GB, 2)) GB..."
        if ($DryRun) {
            Write-Host "  [DryRun] Would PATCH /storage/volumes/$($d.Uuid) with space.size=$($d.TargetSize)"
        } else {
            Invoke-OntapApi "/storage/volumes/$($d.Uuid)" -Method PATCH -Body @{ space = @{ size = $d.TargetSize } }
        }
        Write-Host "  Done." -ForegroundColor Green
    }

    if ($DryRun) {
        $repeatDownsize = $false
    } elseif ($NonInteractive) {
        $repeatDownsize = $false
    } else {
        $repeatDownsize = Confirm-Step "Run another downsizing pass with a different headroom? (y/N)"
    }
}

Write-Host ""
Write-Host "Downsizing phase complete." -ForegroundColor Green

if ($DryRun) {
    $plannedResizeCount = $needsResize.Count
    $totalUpDeltaBytes = 0
    $totalDownDeltaBytes = 0

    foreach ($r in $needsResize) {
        $plannedUpsize = [math]::Ceiling($r.LogicalUsed / 1GB * 1.1) * 1GB
        $upDelta = $plannedUpsize - $r.OriginalSize
        if ($upDelta -gt 0) {
            $totalUpDeltaBytes += $upDelta
            $totalDownDeltaBytes += $upDelta
        }
    }

    Write-Host ""
    Write-Host "=== Dry-Run Planned Actions Summary ===" -ForegroundColor Yellow
    Write-Host ("Constituents to upsize:      {0}" -f $plannedResizeCount)
    Write-Host ("Total planned increase (GB): {0:N2}" -f ($totalUpDeltaBytes / 1GB))
    Write-Host ("Total planned decrease (GB): {0:N2}" -f ($totalDownDeltaBytes / 1GB))
    Write-Host ("LSE enable requested:        {0}" -f $true)
    Write-Host ("ANF transfer requested:      {0}" -f $true)
    Write-Host ("Break replication requested: {0}" -f $true)
    Write-Host ("LSE disable requested:       {0}" -f $true)
    Write-Host ("Bloated CVs to debloat:      {0}" -f $bloatedCvNames.Count)
    Write-Host ("Debloat rounds (max):        {0}" -f $(if ($NonInteractive) { $DebloatRounds } else { "interactive" }))
}
