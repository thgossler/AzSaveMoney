Connect-AzAccount | Out-Null

$resourceTypes = @{}
$totalResources = 0
$retrievedResources = 0
$pageNumber = 0
$skipToken = $null

$countQuery = "resources | summarize count()"
$dataQuery = "resources | project id, type, kind"

$countResult = Search-AzGraph -UseTenantScope -Query $countQuery
$totalResources = $countResult.Data[0].count_

do {
    $pageNumber++
    $queryOptions = @{ Query = $dataQuery }
    if ($skipToken) { $queryOptions['skipToken'] = $skipToken }
    $result = Search-AzGraph @queryOptions -UseTenantScope
    foreach ($resource in $result.Data) {
        $resourceType = $resource.type
        $resourceKind = $resource.kind
        if (![string]::IsNullOrWhiteSpace($resourceKind)) {
            $resourceTypeKind = "$resourceType/$resourceKind".Trim()
        }
        else {
            $resourceTypeKind = $resourceType.Trim()
        }
        $resourceTypes[$resourceTypeKind] = $true  # Add to the hash table to avoid duplicates
        $retrievedResources++
    }
    Write-Progress -Activity "Retrieving resources" -Status "$retrievedResources/$totalResources" -PercentComplete (($retrievedResources / $totalResources) * 100)
    $skipToken = $result.SkipToken
} while ($null -ne $skipToken)

Write-Progress -Activity "Retrieving resources" -Completed -Status "Completed"

Write-Host "Used resource types and kinds across all subscriptions:"
$resourceTypes.Keys | Sort-Object | ForEach-Object { Write-Output $_ }
