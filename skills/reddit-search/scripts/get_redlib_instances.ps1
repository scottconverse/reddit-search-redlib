[CmdletBinding()]
param([switch]$IncludeNonHttps)

$ErrorActionPreference = 'Stop'
$RegistryUrl = 'https://raw.githubusercontent.com/redlib-org/redlib-instances/main/instances.json'
$registry = Invoke-RestMethod -Uri $RegistryUrl -Headers @{'User-Agent'='reddit-search-redlib-registry/1.0'} -TimeoutSec 20
$instances = @($registry.instances | Where-Object {
    $IncludeNonHttps -or ([string]$_.url).StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)
})
[ordered]@{
    source = $RegistryUrl
    updated = $registry.updated
    count = $instances.Count
    instances = $instances
} | ConvertTo-Json -Depth 8
