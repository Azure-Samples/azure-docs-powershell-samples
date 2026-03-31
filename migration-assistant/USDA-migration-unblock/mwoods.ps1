# Analyze FlexGroup volumes for overcommitted constituent volumes
$rootVolumes = Get-Content -Raw .\ontap_volumes_20260325_123000.json | ConvertFrom-Json
$cvMap = Get-Content -Raw .\cv_map_20260325_123000.json | ConvertFrom-Json

function Format-Size([long]$bytes) {
    if ($bytes -ge 1TB) { return "{0:N2} TiB" -f ($bytes / 1TB) }
    if ($bytes -ge 1GB) { return "{0:N2} GiB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MiB" -f ($bytes / 1MB) }
    return "$bytes B"
}

$issuesFound = 0

foreach ($vol in $rootVolumes) {
    $volName = $vol.volume
    $volSize = [long]$vol.size
    $cvs = $cvMap.$volName

    if (-not $cvs) {
        Write-Warning "No CV map entry found for $volName"
        continue
    }

    $totalCvLogicalUsed = ($cvs | Measure-Object -Property logical_used -Sum).Sum
    $overcommittedCVs = $cvs | Where-Object { [long]$_.logical_used -gt [long]$_.size }

    $totalOvercommit = $totalCvLogicalUsed -gt $volSize
    $cvOvercommit = $overcommittedCVs.Count -gt 0

    if ($totalOvercommit -or $cvOvercommit) {
        $issuesFound++
        Write-Host "`n========================================" -ForegroundColor Red
        Write-Host "ISSUE: $volName" -ForegroundColor Red
        Write-Host "  Vserver:    $($vol.vserver)"
        Write-Host "  Vol Size:   $(Format-Size $volSize)"
        Write-Host "  Vol Used:   $(Format-Size $vol.logical_used)"
        Write-Host "  CV Count:   $($cvs.Count)"
        Write-Host "  Total CV logical_used: $(Format-Size $totalCvLogicalUsed)"

        if ($totalOvercommit) {
            $overBy = $totalCvLogicalUsed - $volSize
            Write-Host "  ** Total CV logical_used EXCEEDS vol size by $(Format-Size $overBy) **" -ForegroundColor Yellow
        }

        if ($cvOvercommit) {
            Write-Host "  ** Individual CVs exceeding their own size: **" -ForegroundColor Yellow
            foreach ($cv in $overcommittedCVs) {
                $overBy = [long]$cv.logical_used - [long]$cv.size
                Write-Host "     - $($cv.volume): used $(Format-Size $cv.logical_used) / size $(Format-Size $cv.size) (over by $(Format-Size $overBy))" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host "`n========================================" 
if ($issuesFound -eq 0) {
    Write-Host "No issues found." -ForegroundColor Green
} else {
    Write-Host "$issuesFound volume(s) with issues found." -ForegroundColor Red
}
