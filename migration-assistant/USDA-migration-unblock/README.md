# USDA Migration Unblock Script

This folder contains `USDA_migration_unblock.ps1`, a guided script to unblock Azure NetApp Files migration transfer workflows when FlexGroup constituent volumes are over 100% logical usage and Logical Space Enforcement (LSE) cannot be enabled.

The script is **safe by default**:

- Default mode is **dry-run** (read-only planning, no changes).
- It only performs changes when `-ApplyChanges` is provided.

## Quick Start

### 1) Dry-run first (recommended)

macOS / Linux:

```bash
pwsh ./USDA_migration_unblock.ps1 \
  -ClusterAddress "52.236.137.11" \
  -VserverName "svm_xxx" \
  -VolumeName "vol_xxx" \
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..."
```

Windows:

```powershell
pwsh .\USDA_migration_unblock.ps1 `
  -ClusterAddress "52.236.137.11" `
  -VserverName "svm_xxx" `
  -VolumeName "vol_xxx" `
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..."
```

### 2) Apply changes (interactive)

macOS / Linux:

```bash
pwsh ./USDA_migration_unblock.ps1 \
  -ClusterAddress "52.236.137.11" \
  -VserverName "svm_xxx" \
  -VolumeName "vol_xxx" \
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..." \
  -ApplyChanges
```

Windows:

```powershell
pwsh .\USDA_migration_unblock.ps1 `
  -ClusterAddress "52.236.137.11" `
  -VserverName "svm_xxx" `
  -VolumeName "vol_xxx" `
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..." `
  -ApplyChanges
```

### 3) Apply changes (non-interactive automation)

macOS / Linux:

```bash
pwsh ./USDA_migration_unblock.ps1 \
  -ClusterAddress "52.236.137.11" \
  -VserverName "svm_xxx" \
  -VolumeName "vol_xxx" \
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..." \
  -ApplyChanges \
  -NonInteractive \
  -DownsizeHeadroomPercent 3
```

Windows:

```powershell
pwsh .\USDA_migration_unblock.ps1 `
  -ClusterAddress "52.236.137.11" `
  -VserverName "svm_xxx" `
  -VolumeName "vol_xxx" `
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..." `
  -ApplyChanges `
  -NonInteractive `
  -DownsizeHeadroomPercent 3
```

## What the Script Does

The script runs this sequence:

1. Check FlexGroup logical usage (informational)
2. Find overprovisioned constituents (>100% logical used)
3. Upsize only those constituents (+10% headroom)
4. Enable LSE
5. Wait for elastic sizing to complete
6. Call ANF `performReplicationTransfer`
7. Wait for transfer to complete
8. Call ANF `breakReplication`
9. Wait for replication status to become broken
10. Disable LSE
11. Downsize constituents to reasonable sizes (interactive/repeatable or fixed in non-interactive mode)

## Prerequisites

- PowerShell 7 (`pwsh`) installed
- Access to ONTAP management endpoint (cluster IP/FQDN)
- Azure CLI installed and authenticated (`az login`) for ANF ARM operations  
  (or provide `-ArmAccessToken`)
- Permissions to:
  - modify ONTAP FlexGroup constituent sizes and LSE settings
  - call ANF volume actions (`performReplicationTransfer`, `breakReplication`)

### Install Prerequisites by OS

#### macOS

```bash
brew install powershell/tap/powershell
brew install azure-cli
az login
```

#### Windows

```powershell
winget install Microsoft.PowerShell
winget install Microsoft.AzureCLI
az login
```

#### Linux (Ubuntu example)

```bash
sudo apt-get update
sudo apt-get install -y powershell
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az login
```

## Required Inputs

- `-ClusterAddress`: ONTAP management IP/FQDN
- `-VserverName`: ONTAP SVM name
- `-VolumeName`: source FlexGroup volume name
- `-AnfDestinationVolumeResourceId`: full ARM resource ID of the destination ANF volume

Example resource ID:

`/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.NetApp/netAppAccounts/<account>/capacityPools/<pool>/volumes/<volume>`

## Recommended First Run (Dry-Run)

```bash
pwsh ./USDA_migration_unblock.ps1 \
  -ClusterAddress "52.236.137.11" \
  -VserverName "svm_xxx" \
  -VolumeName "vol_xxx" \
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..."
```

Dry-run shows:

- which constituents are over 100%
- planned upsize/downsize values
- ANF calls that would be made
- summary totals

## Apply Changes (Interactive)

```bash
pwsh ./USDA_migration_unblock.ps1 \
  -ClusterAddress "52.236.137.11" \
  -VserverName "svm_xxx" \
  -VolumeName "vol_xxx" \
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..." \
  -ApplyChanges
```

In apply mode, the script asks for confirmation (including an upfront `yes` prompt) before mutating state.

## Apply Changes (Non-Interactive / Automation)

```bash
pwsh ./USDA_migration_unblock.ps1 \
  -ClusterAddress "52.236.137.11" \
  -VserverName "svm_xxx" \
  -VolumeName "vol_xxx" \
  -AnfDestinationVolumeResourceId "/subscriptions/.../volumes/..." \
  -ApplyChanges \
  -NonInteractive \
  -DownsizeHeadroomPercent 3
```

Use this mode for automation only when you are confident inputs are correct.

## Optional Parameters

- `-AnfApiVersion` (default: `2025-05-01-preview`)
- `-ArmAccessToken` (optional; otherwise token is fetched with `az`)
- `-ArmAsyncTimeoutMinutes` (default: `60`)
- `-ArmAsyncPollSeconds` (default: `30`)
- `-ElasticSizingTimeoutMinutes` (default: `30`)
- `-ElasticSizingPollSeconds` (default: `20`)
- `-DownsizeHeadroomPercent` (default: `3`)

## Troubleshooting

- **`entry doesn't exist` for constituent UUID**
  - The script re-resolves constituent records before downsizing. Re-run if transient state changed.

- **ANF ARM call authentication errors**
  - Run `az login` and ensure correct subscription context, or provide `-ArmAccessToken`.

- **No overprovisioned constituents found**
  - The script exits safely without changes.

- **Async operation timeout**
  - Increase `-ArmAsyncTimeoutMinutes` and retry.

## Validation Tips

Before and after running apply mode, validate from ONTAP:

- constituent logical used %
- LSE state on FlexGroup

And from ANF:

- transfer action completed
- replication status changed to broken after break step

## Safety Notes

- Always run dry-run first.
- Validate target volume and destination resource ID carefully.
- Use non-interactive mode only in controlled automation environments.
