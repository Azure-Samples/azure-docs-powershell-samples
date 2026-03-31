param(
    [Parameter(Mandatory)]
    [string]$ClusterAddress,

    [Parameter(Mandatory)]
    [string]$VserverName,

    [Parameter(Mandatory)]
    [string]$VolumeName,

    [PSCredential]$Credential
)

if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter ONTAP admin credentials"
}

$pair = "{0}:{1}" -f $Credential.UserName, $Credential.GetNetworkCredential().Password
$authHeader = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
$baseUrl = "https://${ClusterAddress}/api"

function Invoke-OntapApi {
    param([string]$Path)
    Invoke-RestMethod -Uri "${baseUrl}${Path}" -Headers $authHeader -SkipCertificateCheck
}

Write-Host "Connected to $ClusterAddress"

$volResponse = Invoke-OntapApi "/storage/volumes?name=${VolumeName}&svm.name=${VserverName}&fields=space,style,type"
$vol = $volResponse.records | Select-Object -First 1

if (-not $vol) {
    Write-Error "Volume '$VolumeName' not found on vserver '$VserverName'."
    exit 1
}

$s = $vol.space
$totalGB = [math]::Round($s.size / 1GB, 2)
$logicalUsedGB = [math]::Round($s.logical_space.used / 1GB, 2)
$logicalPct = if ($s.size -gt 0) { [math]::Round($s.logical_space.used / $s.size * 100, 2) } else { 0 }
$physicalUsedGB = [math]::Round($s.used / 1GB, 2)
$physicalPct = if ($s.size -gt 0) { [math]::Round($s.used / $s.size * 100, 2) } else { 0 }
$availableGB = [math]::Round($s.available / 1GB, 2)
$logicalAvailableGB = [math]::Round(($s.size - $s.logical_space.used) / 1GB, 2)
$lse = $s.logical_space.enforcement

Write-Host ""
Write-Host "=== FlexGroup: $VolumeName ==="
Write-Host ("  Style:              {0}" -f $vol.style)
Write-Host ("  Size:               {0:N2} GB" -f $totalGB)
Write-Host ("  Logical Used:       {0:N2} GB ({1}%)" -f $logicalUsedGB, $logicalPct)
Write-Host ("  Physical Used:      {0:N2} GB ({1}%)" -f $physicalUsedGB, $physicalPct)
Write-Host ("  Available:          {0:N2} GB" -f $availableGB)
Write-Host ("  Logical Available:  {0:N2} GB" -f $logicalAvailableGB)
Write-Host ("  LSE Enabled:        {0}" -f $lse)
Write-Host ""

$volUuid = $vol.uuid
$constResponse = Invoke-OntapApi "/storage/volumes?is_constituent=true&flexgroup.uuid=${volUuid}&fields=space&max_records=500"
$constituents = $constResponse.records

if (-not $constituents -or $constituents.Count -eq 0) {
    Write-Warning "No constituent volumes found."
    exit 0
}

Write-Host ("=== Constituents ({0}) ===" -f $constituents.Count)
Write-Host ""
Write-Host ("{0,-40} {1,12} {2,14} {3,14} {4,12} {5,10} {6,10} {7,5}" -f `
    "Name", "Size(GB)", "LogUsed(GB)", "PhysUsed(GB)", "Avail(GB)", "Log%", "Phys%", "LSE")
Write-Host ("{0,-40} {1,12} {2,14} {3,14} {4,12} {5,10} {6,10} {7,5}" -f `
    ("─" * 12), ("─" * 12), ("─" * 14), ("─" * 14), ("─" * 12), ("─" * 10), ("─" * 10), ("─" * 5))

foreach ($c in $constituents | Sort-Object { $_.name }) {
    $cs = $c.space
    $cSize = [math]::Round($cs.size / 1GB, 2)
    $cLogUsed = [math]::Round($cs.logical_space.used / 1GB, 2)
    $cPhysUsed = [math]::Round($cs.used / 1GB, 2)
    $cAvail = [math]::Round($cs.available / 1GB, 2)
    $cLogPct = if ($cs.size -gt 0) { [math]::Round($cs.logical_space.used / $cs.size * 100, 1) } else { 0 }
    $cPhysPct = if ($cs.size -gt 0) { [math]::Round($cs.used / $cs.size * 100, 1) } else { 0 }
    $cLse = $cs.logical_space.enforcement

    $color = if ($cLogPct -gt 100) { "Red" } elseif ($cLogPct -gt 90) { "Yellow" } else { "White" }

    Write-Host ("{0,-40} {1,12:N2} {2,14:N2} {3,14:N2} {4,12:N2} {5,10:N1} {6,10:N1} {7,5}" -f `
        $c.name, $cSize, $cLogUsed, $cPhysUsed, $cAvail, $cLogPct, $cPhysPct, $cLse) -ForegroundColor $color
}

Write-Host ""
