#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the service-tag -> IPv4 allowlist logic in
    ps-account-setup-cosmos-pe-mirroring.ps1 (Get-FabricMirroringFirewallIPs).

    These tests validate the pure aggregation/filter/dedupe behavior against a
    small, checked-in service-tags fixture (ServiceTags.fixture.json) so the
    logic can be verified without live Azure resources. This is the "test
    fixture" that lets us reason about exactly which IPs each service tag
    contributes (see GitHub issue #62) and keep the firewall footprint minimal.

    Run:  Invoke-Pester -Path .\azure-cosmosdb\common\tests
#>

BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ps-account-setup-cosmos-pe-mirroring.ps1'
    # Dot-source to load helpers; the script's guard returns before the interactive flow.
    . $scriptPath

    $fixturePath = Join-Path $PSScriptRoot 'ServiceTags.fixture.json'
    $script:ServiceTags = Get-Content -Path $fixturePath -Raw | ConvertFrom-Json
}

Describe 'Get-FabricMirroringFirewallIPs' {

    It "loads the Get-FabricMirroringFirewallIPs helper without running the interactive flow" {
        Get-Command Get-FabricMirroringFirewallIPs -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context "Region-scoped tags" {
        It "returns only the exact regional tag and drops IPv6" {
            $config = @([pscustomobject]@{ Name = 'DataFactory'; Scope = 'Region' })
            $result = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig $config -Quiet

            $result | Should -Be @('20.0.0.0/28', '20.0.1.0/28')
            $result | Should -Not -Contain '40.0.0.0/28'      # DataFactory.eastus excluded
            $result | Should -Not -Contain '2603:1000::/48'   # IPv6 excluded
        }

        It "honors the region parameter" {
            $config = @([pscustomobject]@{ Name = 'DataFactory'; Scope = 'Region' })
            $result = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'eastus' -TagConfig $config -Quiet
            $result | Should -Be @('40.0.0.0/28')
        }
    }

    Context "AllRegions-scoped tags" {
        It "aggregates the global tag and every regional variant" {
            $config = @([pscustomobject]@{ Name = 'PowerQueryOnline'; Scope = 'AllRegions' })
            $result = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig $config -Quiet

            $result | Should -Contain '172.208.172.80/28'   # global
            $result | Should -Contain '172.208.173.0/28'    # .westus
            $result | Should -Not -Contain '2603:2000::/48'  # IPv6 excluded
            $result.Count | Should -Be 2
        }

        It "anchors the tag name so unrelated tags with the same prefix are not matched" {
            $config = @([pscustomobject]@{ Name = 'PowerBI'; Scope = 'AllRegions' })
            $result = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig $config -Quiet

            # PowerBIGateway must NOT be swept in by the PowerBI pattern.
            $result | Should -Not -Contain '99.99.99.0/28'
            $result | Should -Contain '51.0.0.0/28'
            $result | Should -Contain '51.0.1.0/28'
        }
    }

    Context "Multi-tag aggregation" {
        BeforeAll {
            $script:FullConfig = @(
                [pscustomobject]@{ Name = 'DataFactory';        Scope = 'Region'     }
                [pscustomobject]@{ Name = 'PowerQueryOnline';   Scope = 'AllRegions' }
                [pscustomobject]@{ Name = 'PowerBI';            Scope = 'AllRegions' }
                [pscustomobject]@{ Name = 'PowerPlatformInfra'; Scope = 'AllRegions' }
            )
            $script:FullResult = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig $script:FullConfig -Quiet
        }

        It "de-duplicates IPs shared across tags (20.0.0.0/28 in both DataFactory and PowerBI)" {
            ($script:FullResult | Where-Object { $_ -eq '20.0.0.0/28' }).Count | Should -Be 1
        }

        It "produces the exact expected unique IPv4 union" {
            $expected = @(
                '13.0.0.0/28', '13.0.1.0/28',
                '172.208.172.80/28', '172.208.173.0/28',
                '20.0.0.0/28', '20.0.1.0/28',
                '51.0.0.0/28', '51.0.1.0/28'
            ) | Sort-Object
            ($script:FullResult | Sort-Object) | Should -Be $expected
        }

        It "returns no IPv6 addresses" {
            ($script:FullResult | Where-Object { $_ -match ':' }).Count | Should -Be 0
        }

        It "adding a tag never reduces coverage (monotonic union)" {
            $twoTags = @(
                [pscustomobject]@{ Name = 'DataFactory';      Scope = 'Region'     }
                [pscustomobject]@{ Name = 'PowerQueryOnline'; Scope = 'AllRegions' }
            )
            $subset = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig $twoTags -Quiet
            foreach ($ip in $subset) { $script:FullResult | Should -Contain $ip }
        }
    }

    Context "Isolating a minimal tag set (issue #62 workflow)" {
        It "reports each tag's marginal IPv4 contribution so the smallest working set can be chosen" {
            # Baseline: DataFactory + PowerQueryOnline (the pre-fix set).
            $baselineConfig = @(
                [pscustomobject]@{ Name = 'DataFactory';      Scope = 'Region'     }
                [pscustomobject]@{ Name = 'PowerQueryOnline'; Scope = 'AllRegions' }
            )
            $baseline = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig $baselineConfig -Quiet

            $withPowerBi = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig (
                $baselineConfig + [pscustomobject]@{ Name = 'PowerBI'; Scope = 'AllRegions' }) -Quiet
            $withInfra = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig (
                $baselineConfig + [pscustomobject]@{ Name = 'PowerPlatformInfra'; Scope = 'AllRegions' }) -Quiet

            # Each candidate tag adds real, distinct coverage over the baseline.
            ($withPowerBi.Count - $baseline.Count) | Should -BeGreaterThan 0
            ($withInfra.Count - $baseline.Count)   | Should -BeGreaterThan 0
        }
    }

    Context "Input validation" {
        It "throws on an unknown scope" {
            $config = @([pscustomobject]@{ Name = 'PowerBI'; Scope = 'Galaxy' })
            { Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig $config -Quiet } |
                Should -Throw -ExpectedMessage "*Unknown scope 'Galaxy'*"
        }

        It "returns an empty array when a configured tag matches nothing" {
            $config = @([pscustomobject]@{ Name = 'DoesNotExist'; Scope = 'AllRegions' })
            $result = Get-FabricMirroringFirewallIPs -ServiceTagJson $script:ServiceTags -Region 'westus' -TagConfig $config -Quiet
            @($result).Count | Should -Be 0
        }
    }
}
