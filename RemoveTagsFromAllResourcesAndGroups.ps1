<#
.SYNOPSIS
This script removes  all specified tags  from  all specified resources 
and resource groups.

.DESCRIPTION
This script removes  all specified tags  from  all specified resources 
and resource groups.

The default values  for some parameters  can be specified  in a config
file named 'Defaults.json'.

Project Link: https://github.com/thgossler/AzSaveMoney
Copyright (c) 2022 Thomas Gossler
License: MIT

.INPUTS
Azure resources/groups across all (or specified) subscriptions.

.NOTES
Warnings are suppressed by $WarningPreference='SilentlyContinue'.
#>

#Requires -Version 7
#Requires -Modules Az.Accounts
#Requires -Modules Az.ResourceGraph
#Requires -Modules Az.Resources
#Requires -Modules PowerShellGet


######################################################################
# Configuration Settings
######################################################################

[CmdletBinding(SupportsShouldProcess)]
param (
    # The ID of the Azure AD tenant. Can be set in defaults config file. Can be set in defaults config file.
    [string]$DirectoryId,
    
    # The Azure environment name (default: AzureCloud, for options call "(Get-AzEnvironment).Name"). Can be set in defaults config file.
    [string]$AzEnvironment,

    # The list of Azure subscription IDs to process. If empty all subscriptions will be processed (default: all). Can be set in defaults config file.
    [System.Array]$SubscriptionIdsToProcess = @(),

    # The list of names of the tags to be removed (default: all 'SubjectForDeletion...' tags). Can be set in defaults config file.
    [System.Array]$TagNamesToRemove = @(
        "SubjectForDeletion"
        "SubjectForDeletion-FindingDate"
        "SubjectForDeletion-Reason"
        "SubjectForDeletion-Hint"
    ),

    # Don't remove the tags from resources.
    [switch]$DontRemoveFromResources = $false,

    # Don't remove the tags from resource groups.
    [switch]$DontRemoveFromResourceGroups = $false
)

# Get configured defaults from config file
$defaultsConfig = (Test-Path -Path $PSScriptRoot/Defaults.json -PathType Leaf) ? (Get-Content -Path $PSScriptRoot/Defaults.json -Raw | ConvertFrom-Json) : @{}

if ([string]::IsNullOrWhiteSpace($DirectoryId) -and ![string]::IsNullOrWhiteSpace($defaultsConfig.DirectoryId)) {
    $DirectoryId = $defaultsConfig.DirectoryId
}
if ([string]::IsNullOrWhiteSpace($AzEnvironment)) {
    if (![string]::IsNullOrWhiteSpace($defaultsConfig.AzEnvironment)) {
        $AzEnvironment = $defaultsConfig.AzEnvironment
    }
    else {
        $AzEnvironment = 'AzureCloud'
    }
}
if ($SubscriptionIdsToProcess.Count -lt 1 -and $defaultsConfig.SubscriptionIdsToProcess -and 
    ($defaultsConfig.SubscriptionIdsToProcess -is [System.Array]) -and $defaultsConfig.SubscriptionIdsToProcess.Count -gt 0) 
{
    $SubscriptionIdsToProcess = $defaultsConfig.SubscriptionIdsToProcess
}

$tab = '    '


######################################################################
# Execution
######################################################################

$WarningPreference = 'SilentlyContinue'

Clear-Host

$WhatIfHint = ""
$IsWhatIfMode = !$PSCmdlet.ShouldProcess("WhatIf mode", "Enable")
if ($IsWhatIfMode) {
    Write-Host ""
    Write-Host " *** WhatIf mode (no changes are made) *** " -BackgroundColor DarkBlue -ForegroundColor White
    $WhatIfHint = "What if: "
}

if (!((Get-AzEnvironment).Name -contains $AzEnvironment)) {
    Write-Error "Invalid Azure environment name '$AzEnvironment'"
    return
}

$loggedIn = $false
if (![string]::IsNullOrWhiteSpace($DirectoryId)) {
    $loggedIn = Connect-AzAccount -Environment $AzEnvironment -TenantId $DirectoryId -WhatIf:$false
}
else {
    $loggedIn = Connect-AzAccount -Environment $AzEnvironment -WhatIf:$false
    $DirectoryId = (Get-AzContext).Tenant.Id
}
if (!$loggedIn) {
    Write-Error "Sign-in failed"
    return
}

Write-Host "$([Environment]::NewLine)Subscriptions to process:"
if ($null -ne $SubscriptionIdsToProcess -and $SubscriptionIdsToProcess.Count -gt 0) {
    foreach ($s in $SubscriptionIdsToProcess) {
        Write-Host "$($tab)$s"
    }
}
else {
    Write-Host "all"
}

Write-Host "$([System.Environment]::NewLine)Tags to remove:"
$TagNamesToRemove | ForEach-Object { Write-Host "$($tab)$_" }

$choice = Read-Host -Prompt "$([Environment]::NewLine)Remove all these tags?  'y' = yes, <Any> = no "
if ($choice -ine "y") {
    Write-Host "Cancelled by user."
    return
}

if (!$DontRemoveFromResources) {
    Write-Host "$([Environment]::NewLine)Searching matching resources..."

    $query = "Resources | where "
    if ($null -ne $SubscriptionIdsToProcess -and $SubscriptionIdsToProcess.Count -gt 0) { 
        $query += "("
        $op = ""
        foreach ($subscriptionId in $SubscriptionIdsToProcess) {
            $query += "$op subscriptionId =~ '$subscriptionId'"
            $op = " or "
        }
        $query += " ) and "
    }
    $op = ""
    foreach ($tagName in $TagNamesToRemove) {
        $query += "$op tags['$tagName'] != ''"
        $op = " or "
    }

    if ($VerbosePreference -eq $true) {
        Write-Host "Query: $query" -ForegroundColor DarkGray
    }
    
    $resources = [System.Collections.ArrayList]@()
    $skipToken = $null;
    $queryResult = $null;
    do {
        if ($null -eq $skipToken) {
            $queryResult = Search-AzGraph -Query $query
        }
        else {
            $queryResult = Search-AzGraph -Query $query -SkipToken $skipToken
        }
        $skipToken = $queryResult.SkipToken;
        $resources.AddRange($queryResult.Data) | Out-Null
    } while ($null -ne $skipToken)
    
    if ($resources.Count -gt 0) {
        Write-Host "$($WhatIfHint)Removing tags from resources (subscriptionId / resourceGroupName / resourceName):"
        $i = 0; $count = $resources.Count
        foreach ($resource in $resources) {
            $i += 1
            Write-Host "$($tab)$($WhatIfHint)($i/$count) $($resource.subscriptionId) / $($resource.resourceGroup) / $($resource.name)..."
            $tags = Get-AzTag -ResourceId $resource.id
            if (!$tags.Properties.TagsProperty) { continue }
            $tagsToRemove = [hashtable]@{}
            foreach ($tagName in $TagNamesToRemove) {
                $tagValue = $tags.Properties.TagsProperty[$tagName]
                if (![string]::IsNullOrWhiteSpace($tagValue)) {
                    $tagsToRemove.Add($tagName, $tags.Properties.TagsProperty[$tagName]) | Out-Null
                }
            }
            if ($tagsToRemove.Keys.Count -gt 0 -and !$IsWhatIfMode) {
                Update-AzTag -ResourceId $resource.id -Tag $tagsToRemove -Operation Delete -WhatIf:$WhatIfPreference | Out-Null
            }
        }    
    }
    else {
        Write-Host "No matching resources found."
    }
}

if (!$DontRemoveFromResourceGroups) {
    Write-Host "$([Environment]::NewLine)Processing resource groups..."

    $subscriptions = @(Get-AzSubscription -TenantId $DirectoryId -ErrorAction Stop | Where-Object -Property State -ne 'Disabled')

    $s_i = 0; $s_count = $subscriptions.Count
    foreach ($sub in $subscriptions) {
        if ($null -ne $SubscriptionIdsToProcess -and $SubscriptionIdsToProcess.Count -gt 0 -and `
            !$SubscriptionIdsToProcess.Contains($sub.Id)) 
        {
            continue
        }
        $s_i += 1
        Write-Host "$([Environment]::NewLine)($s_i/$s_count) Subscription '$($sub.Name)' ($($sub.SubscriptionId))..."
        Set-AzContext -TenantId $DirectoryId -Subscription $sub.SubscriptionId -WhatIf:$false | Out-Null
        $resourceGroups = [hashtable]@{}
        foreach ($tagName in $TagNamesToRemove) {
            Get-AzResourceGroup | Where-Object { $_.Tags.Keys -icontains $tagName } | ForEach-Object {
                $rgName = $_.ResourceGroupName
                $resourceGroups.$rgName = $_
            }
        }
        if ($resourceGroups.Count -eq 0) { continue }
        Write-Host "$($WhatIfHint)Removing tags from resource groups (subscriptionId / resourceGroupName):"
        $r_i = 0; $r_count = $resourceGroups.Keys.Count
        foreach ($rgName in $resourceGroups.Keys) {
            $r_i += 1
            $rg = $resourceGroups[$rgName]
            Write-Host "$($tab)$($WhatIfHint)($r_i/$r_count) $($sub.SubscriptionId) / $($rg.ResourceGroupName)..."
            $tags = Get-AzTag -ResourceId $rg.ResourceId
            if (!$tags.Properties.TagsProperty) { continue }
            $tagsToRemove = [hashtable]@{}
            foreach ($tagName in $TagNamesToRemove) {
                $tagValue = $tags.Properties.TagsProperty[$tagName]
                if ($null -ne $tagValue) {
                    $tagsToRemove.Add($tagName, $tags.Properties.TagsProperty[$tagName]) | Out-Null
                }
            }
            if ($tagsToRemove.Keys.Count -gt 0 -and !$IsWhatIfMode) {
                Update-AzTag -ResourceId $rg.ResourceId -Tag $tagsToRemove -Operation Delete -WhatIf:$WhatIfPreference | Out-Null
            }
        }
    }
}

Write-Host "$([Environment]::NewLine)Finished."
