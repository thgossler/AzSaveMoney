<#
.SYNOPSIS
This script checks each Azure resource (group) across all subscriptions and
eventually tags it as subject for deletion or (in some cases) deletes it
automatically (after confirmation, configurable). Based on the tag's value
suspect resources can be confirmed or rejected as subject for deletion and will
be considered accordingly in subsequent runs.

.DESCRIPTION
___
__    ███████╗ █████╗ ██╗   ██╗███████╗
      ██╔════╝██╔══██╗██║   ██║██╔════╝
      ███████╗███████║██║   ██║█████╗
      ╚════██║██╔══██║╚██╗ ██╔╝██╔══╝
      ███████║██║  ██║ ╚████╔╝ ███████╗
      ╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝

              ███╗   ███╗ ██████╗ ███╗   ██╗███████╗██╗   ██╗
              ████╗ ████║██╔═══██╗████╗  ██║██╔════╝╚██╗ ██╔╝
              ██╔████╔██║██║   ██║██╔██╗ ██║█████╗   ╚████╔╝
              ██║╚██╔╝██║██║   ██║██║╚██╗██║██╔══╝    ╚██╔╝   __
              ██║ ╚═╝ ██║╚██████╔╝██║ ╚████║███████╗   ██║     ____
              ╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝   ╚═╝   ___
              and clean-up...

This script was primarily written to clean-up large Azure environments and
potentially save money along the way. It was inspired by the project
'itoleck/AzureSaveMoney'.

This script was deliberately written in a single file to ensure ease of use.
The log output is written to the host with colors to improve human readability.

The default values for some parameters can be specified in a config file named
'Defaults.json'.

The script implements function hooks named for each supported resource
type/kind. Function hooks determine for a specific resource which action shall
be taken. The naming convention for hooks is
"Test-ResourceActionHook-<resourceType>[-<resourceKind>]". New hooks can easily
be added by implementing a new function and will be discovered and called
automatically. New hooks should be inserted after the marker [ADD NEW HOOKS
HERE].

There are multiple tags which are set when a resource is marked as subject for
deletion (tag names are configurable):

- "SubjectForDeletion",
- "SubjectForDeletion-FindingDate",
- "SubjectForDeletion-Reason" and
- "SubjectForDeletion-Hint" (optional).

The "SubjectForDeletion" tag has one of the following values after the script
ran and the tag was created:

- "suspected": resource marked as subject for deletion
- "suspectedSubResources": at least one sub resource is subject for deletion

As long as the tag `SubjectForDeletion` has a value starting with
`suspected...` the resource is reevaluated in every run and the tag value is
updated (overwritten). You can update the tag value to one of the following
values in order to influence the script behavior in subsequent runs (see below).

The following example process is suggested to for large organizations:

1. RUN script regularly
2. ALERT `suspected` or `suspectedSubResources` resources to owners
3. MANUAL RESOLUTION by owners by reviewing and changing the tag value of
   `SubjectForDeletion` to one of the following values (case-sensitive!):
  - `rejected`: Resource is needed and shall NOT be deleted (this status will 
    not be overwritten in subsequent runs for 6 months after
    `SubjectForDeletion-FindingDate`).
  - `confirmed`: Resource shall be deleted (will be automatically deleted in 
    the next run).
4. AUTO-DELETION/REEVALUATION: Subsequent script runs will check all resources
again with the following special handling for status:
  - `confirmed`: resource will be deleted.
  - `suspected`: if `SubjectForDeletion-FindingDate` is older that 30 days 
    (e.g. resource was not reviewed in time), the resource will be 
    automatically deleted.

Project Link: https://github.com/thgossler/AzSaveMoney
Copyright (c) 2022 Thomas Gossler
License: MIT
Tags: Azure, cost, optimization, PowerShell

.PARAMETER DirectoryId
The ID of the Azure AD tenant. Can be set in defaults config file.

.PARAMETER AzEnvironment
The Azure environment name (for options call "(Get-AzEnvironment).Name"). Can be set in defaults config file.

.PARAMETER SubscriptionIdsToProcess
The list of Azure subscription IDs to process. If empty all subscriptions will be processed. Can be set in defaults config file.

.PARAMETER DontDeleteEmptyResourceGroups
Prevents that empty resource groups are processed.

.PARAMETER AlwaysOnlyMarkForDeletion
Prevent any automatic deletions, only tag as subject for deletion.

.PARAMETER TryMakingUserContributorTemporarily
Add a Contributor role assignment temporarily for each subscription.

.PARAMETER CentralAuditLogAnalyticsWorkspaceId
Also use this LogAnalytics workspace for querying LogAnalytics diagnostic 'Audit' logs.

.PARAMETER CheckForUnusedResourceGroups
Checks for old resources groups with no deployments for a long time and no write/action activities in last 90 days.

.PARAMETER MinimumResourceAgeInDaysForChecking
Minimum number of days resources must exist to be considered (default: 4, lower or equal 0 will always check). Can be set in defaults config file.

.PARAMETER DisableTimeoutForDeleteConfirmationPrompt
Disable the timeout for all delete confirmation prompts (wait forever)

.PARAMETER DeleteSuspectedResourcesAndGroupsAfterDays
Delete resources and groups which have been and are still marked 'suspected' for longer than the defined period. (default: -1, i.e. don't delete). Can be set in defaults config file.

.PARAMETER EnableRegularResetOfRejectedState
Specifies that a 'rejected' status shall be reset to 'suspected' after the specified period of time to avoid that unused resources are remaining undetected forever.

.PARAMETER ResetOfRejectedStatePeriodInDays
Specifies the period of time in days after which a 'rejected' status is reset to 'suspected'. (default: 6 months)

.PARAMETER DocumentationUrl
An optional URL pointing to documentation about the context-specific use of this script. Can be set in defaults config file.

.PARAMETER UseDeviceAuthentication
Use device authentication.

.PARAMETER AutomationAccountResourceId
Use the system-assigned managed identity of this Azure Automation account for authentication (full resource ID).

.PARAMETER ServicePrincipalCredential
Use these service principal credentials for authentication.

.PARAMETER EnforceStdout
Redirect all displayed text (Write-HostOrOutput) to standard output.

.INPUTS
Azure resources/groups across all (or specified) subscriptions.

.OUTPUTS
Resource/group tags "SubjectForDeletion", "SubjectForDeletion-Reason",
"SubjectForDeletion-FindingDate", "SubjectForDeletion-Hint", deleted empty
resource groups eventually.

.NOTES
Warnings are suppressed by $WarningPreference='SilentlyContinue'.
#>

#Requires -Version 7
#Requires -Modules Az.Accounts
#Requires -Modules Az.Batch
#Requires -Modules Az.DataProtection
#Requires -Modules Az.Monitor
#Requires -Modules Az.ResourceGraph
#Requires -Modules Az.Resources
#Requires -Modules Az.ServiceBus
#Requires -Modules PowerShellGet


######################################################################
# Configuration Settings
######################################################################

[CmdletBinding(SupportsShouldProcess)]
param (
    # The ID of the Azure AD tenant. Can be set in defaults config file.
    [string]$DirectoryId,

    # The Azure environment name (for options call "(Get-AzEnvironment).Name").
    # Can be set in defaults config file.
    [string]$AzEnvironment,

    # The list of Azure subscription IDs to process. If empty all subscriptions
    # will be processed. Can be set in defaults config file.
    [string[]]$SubscriptionIdsToProcess = @(),

    # Prevents that empty resource groups are processed.
    [switch]$DontDeleteEmptyResourceGroups = $false,

    # Prevent any automatic deletions, only tag as subject for deletion.
    [switch]$AlwaysOnlyMarkForDeletion = $false,

    # Add a Contributor role assignment temporarily for each subscription.
    [switch]$TryMakingUserContributorTemporarily = $false,

    # Also use this LogAnalytics workspace for querying LogAnalytics diagnostic
    # 'Audit' logs.
    [string]$CentralAuditLogAnalyticsWorkspaceId = $null,

    # Checks for old resources groups with no deployments for a long time and
    # no write/action activities in last 90 days.
    [switch]$CheckForUnusedResourceGroups = $false,

    # Minimum number of days resources must exist to be considered (default: 4,
    # lower or equal 0 will always check). Can be set in defaults config file.
    [int]$MinimumResourceAgeInDaysForChecking = 1,

    # Disable the timeout for all delete confirmation prompts (wait forever)
    [switch]$DisableTimeoutForDeleteConfirmationPrompt = $false,

    # Delete resources and groups which have been and are still marked 
    # 'suspected' for longer than the defined period. (default: -1, i.e. don't
    # delete). Can be set in defaults config file.
    [int]$DeleteSuspectedResourcesAndGroupsAfterDays = -1,

    # Specifies that a 'rejected' status shall be reset to 'suspected' after the specified period of time to avoid that unused resources are remaining undetected forever.
    [switch]$EnableRegularResetOfRejectedState = $false,

    # Specifies the duration in days after which a 'rejected' status is reset to 'suspected'. (default: 6 months)
    [int]$ResetOfRejectedStatePeriodInDays = -1,

    # An optional URL pointing to documentation about the context-specific
    # use of this script. Can be set in defaults config file.
    [string]$DocumentationUrl = $null,

    # Use device authentication.
    [switch]$UseDeviceAuthentication,

    # Use the system-assigned managed identity of this Azure Automation account for authentication (full resource ID).
    [string]$AutomationAccountResourceId = $null,

    # Use these service principal credentials for authentication.
    [PSCredential]$ServicePrincipalCredential = $null,

    # Redirect all displayed text (Write-HostOrOutput) to standard output.
    [switch]$EnforceStdout
)

function Write-HostOrOutput {
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Message = "",
        [Parameter(Mandatory = $false, Position = 1)]
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
        [Parameter(Mandatory = $false, Position = 2)]
        [System.ConsoleColor]$BackgroundColor = [System.ConsoleColor]::Black,
        [Parameter(Mandatory = $false, Position = 3)]
        [switch]$NoNewline = $false
    )
    if ($EnforceStdout.IsPresent) {
        Write-Output $Message
    }
    else {
        Write-Host $Message -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor -NoNewline:$NoNewline
    }
}

# Get configured defaults from config file
$defaultsConfig = (Test-Path -Path $PSScriptRoot/Defaults.json -PathType Leaf) ? 
    (Get-Content -Path $PSScriptRoot/Defaults.json -Raw | ConvertFrom-Json) : @{}

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
if ($defaultsConfig.PSobject.Properties.name -match "DontDeleteEmptyResourceGroups") {
    try { $DontDeleteEmptyResourceGroups = [System.Convert]::ToBoolean($defaultsConfig.DontDeleteEmptyResourceGroups) } catch {}
}
if ($defaultsConfig.PSobject.Properties.name -match "AlwaysOnlyMarkForDeletion") {
    try { $AlwaysOnlyMarkForDeletion = [System.Convert]::ToBoolean($defaultsConfig.AlwaysOnlyMarkForDeletion) } catch {}
}
if ($defaultsConfig.PSobject.Properties.name -match "EnableRegularResetOfRejectedState") {
    try { $EnableRegularResetOfRejectedState = [System.Convert]::ToBoolean($defaultsConfig.EnableRegularResetOfRejectedState) } catch {}
}
if ($EnableRegularResetOfRejectedState -and $ResetOfRejectedStatePeriodInDays -lt 1) {
    if ($defaultsConfig.ResetOfRejectedStatePeriodInDays -ge 1) {
        $ResetOfRejectedStatePeriodInDays = $defaultsConfig.ResetOfRejectedStatePeriodInDays
    }
    else {
        $ResetOfRejectedStatePeriodInDays = 180
    }
}
if ($defaultsConfig.PSobject.Properties.name -match "TryMakingUserContributorTemporarily") {
    try { $TryMakingUserContributorTemporarily = [System.Convert]::ToBoolean($defaultsConfig.TryMakingUserContributorTemporarily) } catch {}
}
if ($defaultsConfig.PSobject.Properties.name -match "CheckForUnusedResourceGroups") {
    try { $CheckForUnusedResourceGroups = [System.Convert]::ToBoolean($defaultsConfig.CheckForUnusedResourceGroups) } catch {}
}
if ($defaultsConfig.PSobject.Properties.name -match "EnforceStdout") {
    try { $EnforceStdout = [System.Convert]::ToBoolean($defaultsConfig.EnforceStdout) } catch {}
}
if ([string]::IsNullOrWhiteSpace($CentralAuditLogAnalyticsWorkspaceId) -and 
    ![string]::IsNullOrWhiteSpace($defaultsConfig.CentralAuditLogAnalyticsWorkspaceId)) 
{
    $CentralAuditLogAnalyticsWorkspaceId = $defaultsConfig.CentralAuditLogAnalyticsWorkspaceId
}
if ($MinimumResourceAgeInDaysForChecking -lt 1 -and $defaultsConfig.MinimumResourceAgeInDaysForChecking -ge 1) {
    $MinimumResourceAgeInDaysForChecking = $defaultsConfig.MinimumResourceAgeInDaysForChecking
}
if ($DeleteSuspectedResourcesAndGroupsAfterDays -lt 0 -and $defaultsConfig.DeleteSuspectedResourcesAndGroupsAfterDays -ge 0) {
    $DeleteSuspectedResourcesAndGroupsAfterDays = $defaultsConfig.DeleteSuspectedResourcesAndGroupsAfterDays
}
if ($SubscriptionIdsToProcess.Count -lt 1 -and $defaultsConfig.SubscriptionIdsToProcess -and 
    ($defaultsConfig.SubscriptionIdsToProcess -is [System.Array]) -and 
    $defaultsConfig.SubscriptionIdsToProcess.Count -gt 0) 
{
    $SubscriptionIdsToProcess = $defaultsConfig.SubscriptionIdsToProcess
}
if ([string]::IsNullOrWhiteSpace($AutomationAccountResourceId) -and 
    ![string]::IsNullOrWhiteSpace($defaultsConfig.AutomationAccountResourceId)) {
    $AutomationAccountResourceId = $defaultsConfig.AutomationAccountResourceId
}

# Alert invalid parameter combinations
if ($null -ne $ServicePrincipalCredential -and $UseSystemAssignedIdentity.IsPresent) {
    throw [System.ApplicationException]::new("Parameters 'ServicePrincipalCredential' and 'UseSystemAssignedIdentity' cannot be used together")
    return
}
if ($null -ne $ServicePrincipalCredential -and $UseDeviceAuthentication.IsPresent) {
    throw [System.ApplicationException]::new("Parameters 'ServicePrincipalCredential' and 'UseDeviceAuthentication' cannot be used together")
    return
}
if ($UseDeviceAuthentication.IsPresent -and $UseSystemAssignedIdentity.IsPresent) {
    throw [System.ApplicationException]::new("Parameters 'UseDeviceAuthentication' and 'UseSystemAssignedIdentity' cannot be used together")
    return
}
if ($null -ne $ServicePrincipalCredential -and [string]::IsNullOrEmpty($DirectoryId)) {
    throw [System.ApplicationException]::new("Parameter 'ServicePrincipalCredential' requires 'DirectoryId' to be specified")
    return
}

# Initialize static settings (non-parameterized)
$performDeletionWithoutConfirmation = $false  # defensive default of $false (intentionally not made available as param)

$enableOperationalInsightsWorkspaceHook = $false  # enable only when at least 30 days of Audit logs are available

$subjectForDeletionTagName = "SubjectForDeletion"
$subjectForDeletionFindingDateTagName = "SubjectForDeletion-FindingDate"
$subjectForDeletionReasonTagName = "SubjectForDeletion-Reason"

$resourceGroupOldAfterDays = 365  # resource groups with no deployments for that long and no write/action activities for 90 days

enum SubjectForDeletionStatus {  # Supported values for the SubjectForDeletion tag
    suspected
    suspectedSubResources
    rejected
    confirmed
}

# General explanatory and constant tag/value applied to all tagged resource if value is not empty (e.g. URL to docs for the approach)
$subjectForDeletionHintTagName = "SubjectForDeletion-Hint"
$subjectForDeletionHintTagValue = "Update the '$subjectForDeletionTagName' tag value to '$([SubjectForDeletionStatus]::rejected.ToString())' if still needed!"
if ([string]::IsNullOrWhiteSpace($DocumentationUrl) -and ![string]::IsNullOrWhiteSpace($defaultsConfig.DocumentationUrl)) {
    $DocumentationUrl = $defaultsConfig.DocumentationUrl
}
if (![string]::IsNullOrWhiteSpace($DocumentationUrl)) {
    $subjectForDeletionHintTagValue += " See also: $DocumentationUrl"
}

$tab = '    '

######################################################################
# Resource Type Hooks
######################################################################

# Actions decided upon by hooks
enum ResourceAction {
    none
    markForDeletion
    markForSuspectSubResourceCheck
    delete
}

# Resource type-specific hooks for determining the action to perform

function Test-ResourceActionHook-microsoft-batch-batchaccounts($Resource) {
    $apps = Get-AzBatchApplication -ResourceGroupName $Resource.ResourceGroup -AccountName $Resource.Name -WarningAction Ignore
    if ($apps.Id.Length -lt 1) {
        return [ResourceAction]::markForDeletion, "The batch account has no apps."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-cache-redis($Resource) {
    $periodInDays = 35
    $totalGetCount = Get-Metric -ResourceId $Resource.Id -MetricName 'allgetcommands' -AggregationType Total -PeriodInDays $periodInDays
    if ($null -ne $totalGetCount -and $totalGetCount.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The Redis cache had no read access for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-compute-disks($Resource) {
    if ($Resource.Properties.diskState -ieq "Unattached" -or $Resource.ManagedBy.Length -lt 1)
    {
        return [ResourceAction]::markForDeletion, "The disk is not attached to any virtual machine."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-compute-images($Resource) {
    try {
        $sourceVm = Get-AzResource -ResourceId $Resource.Properties.sourceVirtualMachine.Id -ErrorAction Ignore -WarningAction Ignore
        if ($sourceVm) {
            Write-HostOrOutput "$($tab)$($tab)Source VM of a usually generalized image is still existing" -ForegroundColor DarkGray
            return [ResourceAction]::markForDeletion, "The source VM (usually generalized) of the image still exists."
        }
    }
    catch {}
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-compute-snapshots($Resource) {
    $periodInDays = 180
    if ($Resource.Properties.timeCreated -lt (Get-Date -AsUTC).AddDays(-$periodInDays)) {
        return [ResourceAction]::markForDeletion, "The snapshot is older than $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-containerregistry-registries($Resource) {
    $periodInDays = 90
    $totalPullCount = Get-Metric -ResourceId $Resource.Id -MetricName 'TotalPullCount' -AggregationType Average -PeriodInDays $periodInDays
    if ($null -ne $totalPullCount -and $totalPullCount.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The container registry had no pull requests for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-datafactory-factories($Resource) {
    $periodInDays = 35
    $totalSucceededActivityRuns = Get-Metric -ResourceId $Resource.Id -MetricName 'ActivitySucceededRuns' -AggregationType Total -PeriodInDays $periodInDays
    if ($null -ne $totalSucceededActivityRuns -and $totalSucceededActivityRuns.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The data factory has no successful activity runs for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-dataprotection-backupvaults($Resource) {
    $backupInstances = Get-AzDataProtectionBackupInstance -ResourceGroupName $Resource.ResourceGroup -VaultName $Resource.Name
    if ($backupInstances.Count -lt 1) {
        return [ResourceAction]::markForDeletion, "The backup vault has no backup instances."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-dbformysql-servers($Resource) {
    $periodInDays = 35
    $totalNetworkBytesEgress = Get-Metric -ResourceId $Resource.Id -MetricName 'network_bytes_egress' -AggregationType Total -PeriodInDays $periodInDays
    if ($null -ne $totalNetworkBytesEgress -and $totalNetworkBytesEgress.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The MySql database had no egress for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-documentdb-databaseaccounts($Resource) {
    $periodInDays = 35
    $totalRequestCount = Get-Metric -ResourceId $Resource.Id -MetricName 'TotalRequests' -AggregationType Count -PeriodInDays $periodInDays
    if ($null -ne $totalRequestCount -and $totalRequestCount.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The Document DB had no requests account for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-eventgrid-topics($Resource) {
    $periodInDays = 35
    $totalSuccessfulDeliveredEvents = Get-Metric -ResourceId $Resource.Id -MetricName 'DeliverySuccessCount' -AggregationType Total -PeriodInDays $periodInDays
    if ($null -ne $totalSuccessfulDeliveredEvents -and $totalSuccessfulDeliveredEvents.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The event grid topic had no successfully delivered events for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-insights-activitylogalerts($Resource) {
    if ($Resource.Properties.enabled -eq $false) {
        return [ResourceAction]::markForDeletion, "The activity log alert is disabled."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-insights-components($Resource) {
    $access = Get-AzAccessToken -ResourceTypeName "OperationalInsights"
    $headers = @{"Authorization" = "Bearer " + $access.Token}
    $body = @{ "timespan" = "P30D"; "query" = "requests | summarize totalCount=sum(itemCount)"} | ConvertTo-Json
    $result = Invoke-RestMethod "https://api.applicationinsights.io/v1/apps/$($Resource.Properties.AppId)/query" -Method 'POST' -Headers $headers -Body $body -ContentType "application/json"
    $totalRequestCount = $result.tables[0].rows[0][0]
    if ($totalRequestCount -lt 1) {
        return [ResourceAction]::markForDeletion, "The application insights resource had no read requests for 30 days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-insights-metricalerts($Resource) {
    if ($Resource.Properties.enabled -eq $false) {
        return [ResourceAction]::markForDeletion, "The metric alert is disabled."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-insights-scheduledqueryrules($Resource) {
    if ($Resource.Properties.enabled -eq $false) {
        return [ResourceAction]::markForDeletion, "The scheduled query rule is disabled."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-keyvault-vaults($Resource) {
    $periodInDays = 35
    $totalApiHits = Get-Metric -ResourceId $Resource.Id -MetricName 'ServiceApiHit' -AggregationType Count -PeriodInDays $periodInDays
    if ($null -ne $totalApiHits -and $totalApiHits.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The key vault had no API hits for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-kusto-clusters($Resource) {
    $periodInDays = 35
    $totalReceivedBytesAverage = Get-Metric -ResourceId $Resource.Id -MetricName 'ReceivedDataSizeBytes' -AggregationType Average -PeriodInDays $periodInDays
    if ($null -ne $totalReceivedBytesAverage -and $totalReceivedBytesAverage.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The Kusto cluster had no egress for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-logic-workflows($Resource) {
    $periodInDays = 35
    if ($Resource.Properties.state -ine 'Enabled') {
        return [ResourceAction]::markForDeletion, "The logic apps workflow disabled."
    }
    $totalRunsSucceeded = Get-Metric -ResourceId $Resource.Id -MetricName 'RunsSucceeded' -AggregationType 'Total' -PeriodInDays $periodInDays
    if ($null -ne $totalRunsSucceeded -and $totalRunsSucceeded.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The logic apps workflow had no successful runs for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-bastionhosts($Resource) {
    $periodInDays = 35
    $totalNumberOfSessions = Get-Metric -ResourceId $Resource.Id -MetricName 'sessions' -AggregationType Total -PeriodInDays $periodInDays
    if ($null -ne $totalNumberOfSessions -and $totalNumberOfSessions.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The Bastion host had no sessions for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-connections($Resource) {
    if ($Resource.Properties.connectionStatus -ine 'Connected') {
        return [ResourceAction]::markForDeletion, "The network connection is disconnected."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-loadbalancers($Resource) {
    $periodInDays = 35
    if ($Resource.Properties.loadBalancingRules.Count -lt 1) {
        return [ResourceAction]::markForDeletion, "The load balancer has no load blanancing rules."
    }
    if ($Resource.Sku.name -ine 'Basic') {  # metrics not available in Basic SKU
        $totalByteCount = Get-Metric -ResourceId $Resource.Id -MetricName 'ByteCount' -AggregationType Total -PeriodInDays $periodInDays
        if ($null -ne $totalByteCount -and $totalByteCount.Sum -lt 1) {
            return [ResourceAction]::markForDeletion, "The load balancer had no transmitted bytes for $periodInDays days."
        }
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-networkinterfaces($Resource) {
    if (!$Resource.Properties.virtualMachine -and !$Resource.Properties.privateEndpoint) {
        return [ResourceAction]::markForDeletion, "The network interface is unassigned."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-networksecuritygroups($Resource) {
    if (!$Resource.Properties.networkInterfaces -and !$Resource.Properties.subnets) {
        return [ResourceAction]::markForDeletion, "The network security group is unassigned."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-publicipaddresses($Resource) {
    if ($null -eq $Resource.Properties.ipConfiguration.id)
    {
        return [ResourceAction]::markForDeletion, "The public IP address is unassigned."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-routetables($Resource) {
    $atLeastOneUsedRoute = $false
    foreach ($route in $Resource) {
        if ($route.properties.subnets.Count -gt 0) {
            $atLeastOneUsedRoute = $true
        }
    }
    if (!$atLeastOneUsedRoute) {
        return [ResourceAction]::markForDeletion, "The network route table has no used routed."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-trafficmanagerprofiles($Resource) {
    if ($Resource.Properties.profileStatus -ine 'Enabled') {
        return [ResourceAction]::markForDeletion, "The traffic manager profile is disabled."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-network-virtualnetworks($Resource) {
    if ($Resource.Properties.subnets.Count -lt 1) {
        return [ResourceAction]::markForDeletion, "The virtual network has no subnets."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-notificationhubs-namespaces($Resource) {
    $parameters = @{
        ResourceType      = 'Microsoft.NotificationHubs/namespaces/notificationHubs'
        ResourceGroupName = $Resource.ResourceGroup
        ResourceName      = $Resource.Name
        ApiVersion        = '2017-04-01'
        ErrorAction       = 'SilentlyContinue'
    }
    $notificationHub = Get-AzResource @parameters
    if (!$notificationHub) {
        return [ResourceAction]::markForDeletion, "The notification hub has no hubs."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-operationalinsights-workspaces($Resource) {
    #
    # NOTE: This hook is only working for LogAnalytics workspaces which have diagnostic 
    # 'Audit' logs enabled and written into either the workspace itself or another single 
    # workspace specified in $CentralAuditLogAnalyticsWorkspaceId. Therefore, to enable 
    # this hook, the following setting must be made: 
    # $enableOperationalInsightsWorkspaceHook = $true
    #
    $periodInDays = 35  # data retention in the LogAnalytics workspaces needs to be configured correspondingly
    if ($enableOperationalInsightsWorkspaceHook -eq $true) {
        $query = "LAQueryLogs | where TimeGenerated >= now() - $($periodInDays)d | where RequestTarget == '$($Resource.Id)' | count"
        $numberOfUserOrClientRequests = 0
        if (![string]::IsNullOrWhiteSpace($CentralAuditLogAnalyticsWorkspaceId)) {
            $results = Invoke-AzOperationalInsightsQuery -Query $query -WorkspaceId $CentralAuditLogAnalyticsWorkspaceId | Select-Object -ExpandProperty Results
            $numberOfUserOrClientRequests = [int]$results[0].Count
        }
        if ($numberOfUserOrClientRequests -lt 1) {
            $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $Resource.ResourceGroup -Name $Resource.Name
            $results = Invoke-AzOperationalInsightsQuery -Query $query -WorkspaceId $workspace.CustomerId | Select-Object -ExpandProperty Results
            $numberOfUserOrClientRequests = [int]$results[0].Count
        }
        if ($numberOfUserOrClientRequests -lt 1) {
            return [ResourceAction]::markForDeletion, "The log analytics workspace had no read requests for $periodInDays days."
        }
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-servicebus-namespaces($Resource) {
    $queues = Get-AzServiceBusQueue -ResourceGroupName $Resource.ResourceGroup -NamespaceName $Resource.Name
    $result = [ResourceAction]::none
    foreach ($queue in $queues) {
        if ($queue.Status -ine "Active") {
            Write-HostOrOutput "$($tab)$($tab)Queue '$($queue.name)' is in status '$($queue.Status)'" -ForegroundColor DarkGray
            $result = [ResourceAction]::markForSuspectSubResourceCheck, "The service bus namespace has at least one inactive queue."
        }
    }
    return $result, ""
}
function Test-ResourceActionHook-microsoft-web-serverfarms($Resource) {
    if ($Resource.Properties.numberOfSites -lt 1) {
        return [ResourceAction]::markForDeletion, "The app service plan has no apps."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-web-sites-functionapp($Resource) {
    if ($Resource.Properties.state -ieq 'Running') {  # we can't see functions in stopped apps, so we ignore them
        $GetAzResourceParameters = @{
            ResourceType      = 'Microsoft.Web/sites/functions'
            ResourceGroupName = $Resource.ResourceGroup
            ResourceName      = $Resource.Name
            ApiVersion        = '2022-03-01'
            ErrorAction       = 'SilentlyContinue'
        }
        $functions = Get-AzResource @GetAzResourceParameters
        if (!$functions) {
            Write-HostOrOutput "$($tab)$($tab)Function app has no functions" -ForegroundColor DarkGray
            return [ResourceAction]::markForDeletion, "The function app has no functions."
        }
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-web-sites-functionapp-linux($Resource) {
    return Test-ResourceActionHook-microsoft-web-sites-functionapp($Resource)
}
function Test-ResourceActionHook-microsoft-web-sites-functionapp-linux-container($Resource) {
    return Test-ResourceActionHook-microsoft-web-sites-functionapp($Resource)
}
function Test-ResourceActionHook-microsoft-web-sites-app($Resource) {
    $periodInDays = 35
    $webApp = Get-AzWebApp -ResourceGroupName $Resource.ResourceGroup -Name $Resource.Name
    if ($null -eq $webApp) {
        return [ResourceAction]::none, "Web App does not exist."
    }
    if ($webApp.State -eq 'Stopped') {
        $lastModifiedTime = $webApp.SiteConfig.LastModifiedTimeUtc
        $currentTime = (Get-Date).ToUniversalTime()
        $timeDiff = $currentTime - $lastModifiedTime
        if ($timeDiff.Days -gt $periodInDays) {
            return [ResourceAction]::markForDeletion, "Web App has been stopped for more than $periodInDays days."
        }
    }
    $cpuUtilization = Get-Metric -ResourceId $Resource.Id -MetricName 'CpuTime' -AggregationType 'Total' -PeriodInDays $periodInDays
    if ($null -ne $cpuUtilization -and $cpuUtilization.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The web app had no CPU utilization for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-web-sites-app-linux($Resource) {
    return Test-ResourceActionHook-microsoft-web-sites-app($Resource)
}
function Test-ResourceActionHook-microsoft-web-sites-app-linux-container($Resource) {
    return Test-ResourceActionHook-microsoft-web-sites-app($Resource)
}
function Test-ResourceActionHook-microsoft-storage-storageaccounts($Resource) {
    $periodInDays = 35
    $totalNumOfTransactions = Get-Metric -ResourceId $Resource.Id -MetricName "Transactions" -AggregationType "Total" -PeriodInDays $periodInDays
    if ($null -ne $totalNumOfTransactions -and $totalNumOfTransactions.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The storage account had no transactions for $periodInDays days."
    }
    $usedCapacity = Get-Metric -ResourceId $Resource.Id -MetricName "UsedCapacity" -AggregationType "Average" -PeriodInDays $periodInDays -TimeGrainInHours 1
    if ($null -ne $usedCapacity -and $usedCapacity.Maximum -lt 1) {
        return [ResourceAction]::markForDeletion, "The storage account had no data for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}
function Test-ResourceActionHook-microsoft-apimanagement-service($Resource) {
    $periodInDays = 35
    $apimContext = New-AzApiManagementContext -ResourceGroupName $Resource.ResourceGroup -ServiceName $Resource.Name
    $apis = Get-AzApiManagementApi -Context $apimContext
    if ($apis.Count -eq 0) {
        return [ResourceAction]::markForDeletion, "API Management service has no APIs deployed."
    }
    $numberOfTotalRequests = Get-Metric -ResourceId $Resource.Id -MetricName "TotalRequests" -AggregationType "Total" -PeriodInDays $periodInDays
    if ($numberOfTotalRequests.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "API Management service has had no traffic in the last $periodInDays days."
    }
    return [ResourceAction]::none, ""
}

function Test-ResourceActionHook-microsoft-compute-virtualmachines($Resource) {
    $periodInDays = 35
    $timeCreated = $Resource.Properties.TimeCreated
    if ($Resource.Properties.ProvisioningState -ine 'Succeeded' -and $timeCreated -lt (Get-Date).AddDays(-$periodInDays)) {
        return [ResourceAction]::markForDeletion, "The VM is not in a succeeded state for $periodInDays days."
    }
    $vmStatus = Get-AzVM -Status -ResourceGroupName $Resource.ResourceGroup -VMName $Resource.Name
    if ($vmStatus.Statuses[1].Code -eq 'PowerState/deallocated' -or $vmStatus.Statuses[1].Code -eq 'PowerState/stopped') {
        $lastStatusChange = $vmStatus.Statuses[1].Time
        if ($null -ne $lastStatusChange) {
            $currentTime = Get-Date
            $timeDiff = $currentTime - $lastStatusChange
            if ($timeDiff.Days -gt $periodInDays) {
                return [ResourceAction]::markForDeletion, "VM has been stopped for more than $periodInDays days."
            }
        }
    }
    $cpuUtilization = Get-Metric -ResourceId $Resource.Id -MetricName 'Percentage CPU' -AggregationType 'Average' -PeriodInDays $periodInDays
    if ($null -ne $cpuUtilization -and $cpuUtilization.Average -lt 1) {
        return [ResourceAction]::markForDeletion, "The VM had no CPU utilization for $periodInDays days."
    }
    $networkUtilization = Get-Metric -ResourceId $Resource.Id -MetricName 'Network In' -AggregationType 'Total' -PeriodInDays $periodInDays
    if ($null -ne $networkUtilization -and $networkUtilization.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The VM had no network traffic for $periodInDays days."
    }
    $diskUtilization = Get-Metric -ResourceId $Resource.Id -MetricName 'Disk Read Bytes' -AggregationType 'Total' -PeriodInDays $periodInDays
    if ($null -ne $diskUtilization -and $diskUtilization.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "The VM had no disk read activity for $periodInDays days."
    }
    return [ResourceAction]::none, "" 
}

function Test-ResourceActionHook-microsoft-compute-virtualmachinescalesets($Resource) {
    $periodInDays = 30
    if ($Resource.Sku.Capacity -eq 0) {
        return [ResourceAction]::markForDeletion, "VMSS has no instances."
    }
    $vmssInstances = Get-AzVmssVM -ResourceGroupName $Resource.ResourceGroup -VMScaleSetName $Resource.Name
    $allStopped = $true
    $message = "All instances in VMSS have been stopped."
    $currentTime = Get-Date
    foreach ($instance in $vmssInstances) {
        $instanceView = Get-AzVmssVM -ResourceGroupName $Resource.ResourceGroup -VMScaleSetName $Resource.Name -InstanceId $instance.InstanceId -InstanceView
        $powerState = $instanceView.Statuses | Where-Object { $_.Code -match 'PowerState/' } | Select-Object -ExpandProperty Code
        if ($powerState -ne 'PowerState/deallocated' -and $powerState -ne 'PowerState/stopped') {
            $allStopped = $false
            break
        }
        $lastStatusChange = $instanceView.Statuses | Where-Object { $_.Code -match 'PowerState/' } | Select-Object -ExpandProperty Time
        if ($null -ne $lastStatusChange) {
            $timeDiff = $currentTime - $lastStatusChange
            if ($timeDiff.Days -le $periodInDays) {
                $allStopped = $false
                break
            }
            $message = "All instances in VMSS have been stopped for more than $periodInDays days."
        }
    }
    if ($allStopped) {
        return [ResourceAction]::markForDeletion, $message
    }
    return [ResourceAction]::none, "" 
}

function Test-ResourceActionHook-microsoft-virtualmachineimages-imagetemplates($Resource) {
    $failedPeriodInDays = 35
    $updatePeriodInDays = 365
    if ($Resource.Properties.source.type -eq 'PlatformImage') {
        if ($Resource.Properties.lastRunStatus.runState -eq "Failed" -and $Resource.Properties.lastRunStatus.endTime -lt (Get-Date).AddDays(-$failedPeriodInDays)) {
            return [ResourceAction]::markForDeletion, "The image template build failed and was more than $failedPeriodInDays days ago."
        }
        if ($Resource.Properties.lastRunStatus.runState -ne "Failed" -and $Resource.Properties.lastRunStatus.endTime -lt (Get-Date).AddDays(-$updatePeriodInDays)) {
            return [ResourceAction]::markForDeletion, "The image template was not updated for more than $updatePeriodInDays days."
        }
        if ($Resource.Properties.distribute.Count -lt 1 -or ($null -eq $Resource.Properties.distribute[0].galleryImageId)) {
            return [ResourceAction]::markForDeletion, "The image template has no image to distribute."
        }
    }
    return [ResourceAction]::none, "" 
}

function Test-ResourceActionHook-microsoft-containerinstance-containergroups($Resource) {
    $periodInDays = 35
    $currentTime = Get-Date
    if ($Resource.Properties.InstanceView.State -eq 'Stopped') {
        $lastInstanceViewEvent = $Resource.Properties.InstanceView.Events | Sort-Object -Property LastTimestamp -Descending | Select-Object -First 1
        if ($null -ne $lastInstanceViewEvent -and $lastInstanceViewEvent.Name -eq 'DeploymentFailed') {
            $timeDiff = $currentTime - $lastInstanceViewEvent.LastTimestamp
            if ($timeDiff.Days -gt $periodInDays) {
                return [ResourceAction]::markForDeletion, "Container Group deployment failed more than $periodInDays days ago."
            }
        }
        $Resource.Properties.Containers | ForEach-Object {
            $lastContainerInstanceViewEvent = $_.Properties.InstanceView.Events | Sort-Object -Property LastTimestamp -Descending | Select-Object -First 1
            if ($null -ne $lastContainerInstanceViewEvent) {
                if ($lastContainerInstanceViewEvent.Name -eq 'Killing' -or $lastContainerInstanceViewEvent.Name -eq 'Failed') {
                    $timeDiff = $currentTime - $lastContainerInstanceViewEvent.LastTimestamp
                    if ($timeDiff.Days -gt $periodInDays) {
                        return [ResourceAction]::markForDeletion, "All containers failed or killed more than $periodInDays days ago."
                    }
                }
            }
        }
    }
    return [ResourceAction]::none, ""
}

function Test-ResourceActionHook-microsoft-network-applicationgateways($Resource) {
    $periodInDays = 35
    $hasBackendPools = $Resource.Properties.BackendAddressPools.Count -gt 0
    if (-not $hasBackendPools) {
        return [ResourceAction]::markForDeletion, "Application Gateway has no backend pool instances."
    }
    $totalBytesReceived = Get-Metric -ResourceId $Resource.Id -MetricName 'BytesReceived' -AggregationType 'Total' -PeriodInDays $periodInDays
    if ($null -ne $totalBytesReceived -and $totalBytesReceived.Sum -lt 1) {
        return [ResourceAction]::markForDeletion, "Application Gateway had no received bytes for $periodInDays days."
    }
    return [ResourceAction]::none, ""
}

# [ADD NEW HOOKS HERE], ideally insert them above in alphanumeric order


######################################################################
# Helper Functions
######################################################################

function Get-Metric([string]$ResourceId, [string]$MetricName, [string]$AggregationType, [int]$PeriodInDays = 35, [int]$TimeGrainInHours = 24) {
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { throw [System.ApplicationException]::new("ResourceId not specified")}
    if ([string]::IsNullOrWhiteSpace($MetricName)) { throw [System.ApplicationException]::new("MetricName not specified")}
    if ([string]::IsNullOrWhiteSpace($AggregationType)) { throw [System.ApplicationException]::new("AggregationType not specified")}
    $metric = $null
    $retries = 3
    $delaySeconds = 3
    do {
        if ($retries -ne 3) { Start-Sleep -Seconds $delaySeconds }
        $retries -= 1
        try {
            $metric = Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName -AggregationType $AggregationType `
                -StartTime (Get-Date -AsUTC).AddDays(-$PeriodInDays) -EndTime (Get-Date -AsUTC) `
                -TimeGrain ([timespan]::FromHours($TimeGrainInHours).ToString()) `
                -ErrorAction Continue
        } catch {
            $metric = $null
            Write-HostOrOutput "Retrying in $delaySeconds seconds..."
            if ($retries -eq 1) {
                # Workaround: Get-AzMetric doesn't work sometimes with TimeGrain specified (https://github.com/Azure/azure-powershell/issues/22750)
                $metric = Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName -AggregationType $AggregationType `
                    -StartTime (Get-Date -AsUTC).AddDays(-$PeriodInDays) -EndTime (Get-Date -AsUTC) `
                    -ErrorAction Continue
            }
            else {
                $metric = Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName -AggregationType $AggregationType `
                    -StartTime (Get-Date -AsUTC).AddDays(-$PeriodInDays) -EndTime (Get-Date -AsUTC) `
                    -TimeGrain ([timespan]::FromHours($TimeGrainInHours).ToString()) `
                    -ErrorAction SilentlyContinue
            }
        }
        $retries -= 1
        if ($null -eq $metric -and $retries -gt 0) {
            Write-HostOrOutput "$($tab)$($tab)Metric could not be retrieved, retrying in $delaySeconds seconds..." -ForegroundColor DarkGray
        }
    } while ($null -eq $metric -and $retries -gt 0)
    if ($null -eq $metric) {
        Write-HostOrOutput "$($tab)$($tab)Failed to get metric '$MetricName' for resource '$ResourceId'" -ForegroundColor Red
        return $null
    }
    $metricData = $metric.Data
    $measuredMetricData = $metricData | Measure-Object -Property $AggregationType -AllStats
    return $measuredMetricData
}

function Add-SubjectForDeletionTags 
{
    [CmdletBinding(SupportsShouldProcess)]
    param (
        $ResourceOrGroup, 
        [SubjectForDeletionStatus]$Status = [SubjectForDeletionStatus]::suspected,
        [string]$Reason = $null, 
        [string]$Hint = $null, 
        [switch]$SuppressHostOutput = $false,
        [switch]$AllowResetOfRejectedToSuspected = $false
    )
    $tags = $ResourceOrGroup.Tags
    $subjectForDeletionTagValue = ($tags.$subjectForDeletionTagName ?? '').Trim()
    $subjectForDeletionFindingDateTagValue = ($tags.$subjectForDeletionFindingDateTagName ?? '').Trim()
    # only update tag if not existing yet or still in suspected status
    $targetTagValue = $Status.ToString()
    if ([string]::IsNullOrWhiteSpace($subjectForDeletionTagValue) -or `
        ($subjectForDeletionTagValue -ine [SubjectForDeletionStatus]::confirmed.ToString() -and `
         $subjectForDeletionTagValue -ine [SubjectForDeletionStatus]::suspectedSubResources.ToString()) -or `
        ($subjectForDeletionTagValue -ieq [SubjectForDeletionStatus]::rejected.ToString() -and `
         $AllowResetOfRejectedToSuspected) )
    {
        $dateString = Get-Date -AsUTC -Format "dd.MM.yyyy"
        $tagsToBeRemoved = @{}
        $newTags = @{ $subjectForDeletionTagName = $targetTagValue }
        # Don't overwrite FindingDate tag if value is existing
        if ([string]::IsNullOrWhiteSpace($subjectForDeletionFindingDateTagValue)) {
            $newTags.Add($subjectForDeletionFindingDateTagName, $dateString)
        }
        if (![String]::IsNullOrWhiteSpace($Reason)) {
            $text = $Reason.Trim()
            if ($text.Length -gt 256) {
                $text = $text.Substring(0, 256)
            }
            $newTags.Add($subjectForDeletionReasonTagName, $text)
        }
        elseif ($null -ne $tags.$subjectForDeletionReasonTagName) {
            $tagsToBeRemoved.Add($subjectForDeletionReasonTagName, $tags.$subjectForDeletionReasonTagName)
        }
        if ([String]::IsNullOrWhiteSpace($Hint) -and ![String]::IsNullOrWhiteSpace($subjectForDeletionHintTagValue)) {
            $Hint = $subjectForDeletionHintTagValue
        }
        if (![String]::IsNullOrWhiteSpace($Hint)) {
            $text = $Hint.Trim()
            if ($text.Length -gt 256) {
                $text = $text.Substring(0, 256)
            }
            $newTags.Add($subjectForDeletionHintTagName, $text)
        }
        elseif ($null -ne $tags.$subjectForDeletionHintTagName) {
            $tagsToBeRemoved.Add($subjectForDeletionHintTagName, $tags.$subjectForDeletionHintTagName)
        }
        $result = Update-AzTag -ResourceId $ResourceOrGroup.ResourceId -tag $newTags -Operation Merge -WhatIf:$WhatIfPreference
        if (!$SuppressHostOutput -and $result) {
            Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Added tags " -NoNewline
            Write-HostOrOutput ($newTags | ConvertTo-Json -Compress) -ForegroundColor White
        }
    }
    # Remove existing tags which are not specified
    if ($tagsToBeRemoved.Keys.Count -gt 0) {
        Update-AzTag -ResourceId $ResourceOrGroup.ResourceId -tag $tagsToBeRemoved -Operation Delete -WhatIf:$WhatIfPreference | Out-Null
    }
}

function Remove-SubjectForDeletionTags
{
    [CmdletBinding(SupportsShouldProcess)]
    param (
        $ResourceOrGroup    
    )
    $tags = $ResourceOrGroup.Tags
    if (!$tags) { return }
    $resourceOrGroupId = $ResourceOrGroup.ResourceId
    $subjectForDeletionTagValue = ($tags.$subjectForDeletionTagName ?? '').Trim()
    $status = $null
    if (![string]::IsNullOrWhiteSpace($subjectForDeletionTagValue)) {
        $status = [SubjectForDeletionStatus]$subjectForDeletionTagValue
    }
    $subjectForDeletionFindingDateTagValue = $tags.$subjectForDeletionFindingDateTagName
    $subjectForDeletionReasonTagValue = $tags.$subjectForDeletionReasonTagName
    $subjectForDeletionHintTagValue = $tags.$subjectForDeletionHintTagName
    $tagsToRemove = @{}
    $removeNecessary = $false
    # Certain tags shall not be removed in 'rejected' status!
    if ($status -ine [SubjectForDeletionStatus]::rejected.ToString()) {
        $tagsToRemove.Add($subjectForDeletionTagName, $subjectForDeletionTagValue)
        $removeNecessary = $true
        if ($null -ne $subjectForDeletionFindingDateTagValue) {
            $tagsToRemove.Add($subjectForDeletionFindingDateTagName, $subjectForDeletionFindingDateTagValue)
        }
        if ($null -ne $subjectForDeletionHintTagValue) {
            $tagsToRemove.Add($subjectForDeletionHintTagName, $subjectForDeletionHintTagValue)
        }
    }
    if ($null -ne $subjectForDeletionReasonTagValue) {
        $tagsToRemove.Add($subjectForDeletionReasonTagName, $subjectForDeletionReasonTagValue)
        $removeNecessary = $true
    }
    if ($removeNecessary) {
        Update-AzTag -ResourceId $resourceOrGroupId -tag $tagsToRemove -Operation Delete -WhatIf:$WhatIfPreference | Out-Null
    }
}

enum UserConfirmationResult {
    Unknown
    No
    Yes
    YesForAll
}

function Get-UserConfirmationWithTimeout(
    # Continue automatically after this number of seconds assuming 'No'
    [int]$TimeoutSeconds = 30, 
    # Wait for user input forever
    [switch]$DisableTimeout = $false, 
    # Consider last user input, i.e. YesToAll suppresses confirmation prompt
    [UserConfirmationResult]$LastConfirmationResult = [UserConfirmationResult]::Unknown) 
{
    $choice = "cancel"
    $questionTimeStamp = (Get-Date -AsUTC)
    if ($LastConfirmationResult -eq [UserConfirmationResult]::YesForAll) {
        $choice = "a"
    }
    else {
        try {
            Write-HostOrOutput "$([Environment]::NewLine)Continue?  'y' = yes, 'a' = yes to all, <Any> = no : " -ForegroundColor Red -NoNewline

            # Read key input from host
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $choice = $null
            # Clear console key input queue
            while ([Console]::KeyAvailable) {
                [Console]::ReadKey($true) | Out-Null
            }
            # Wait for user input
            if (!$DisableTimeout) {
                while (-not [Console]::KeyAvailable -and $null -eq $choice) {
                    if ($timer.ElapsedMilliseconds -gt ($TimeoutSeconds*1000)) {
                        $choice = 'n'
                        break
                    }
                    else {
                        Start-Sleep -Milliseconds 250
                    }
                }
            }
            if ($null -eq $choice) {
                $choice = ([Console]::ReadKey()).KeyChar
            }
            $timer.Stop()
            $timer = $null
            Write-HostOrOutput ""

            $answerTimeStamp = (Get-Date -AsUTC)
            if (!$DisableTimeout -and `
                $answerTimeStamp.Subtract($questionTimeStamp) -gt [timespan]::FromSeconds($TimeoutSeconds)) 
            {
                Write-HostOrOutput "No response within $($TimeoutSeconds)s (the situation may have changed), assuming 'no'..."
                $choice = 'n'
            }
        } catch {
            Write-HostOrOutput "Asking user for confirmation failed, assuming 'no'..."
            $choice = 'n'
        }
    }
    if ($choice -ieq "y") {
        return [UserConfirmationResult]::Yes
    }
    elseif ($choice -ieq "a") {
        return [UserConfirmationResult]::YesForAll
    }
    return [UserConfirmationResult]::No
}


######################################################################
# Execution
######################################################################

$WarningPreference = 'SilentlyContinue'  # to suppress upcoming breaking changes warnings

$IsWhatIfMode = !$PSCmdlet.ShouldProcess("mode is enabled (no changes will be made)", $null, $null)
$WhatIfHint = $IsWhatIfMode ? "What if: " : ""

# Override $performDeletionWithoutConfirmation settings when -Confirm is used
if ($performDeletionWithoutConfirmation -eq $true -and $ConfirmPreference -eq $true) {
    $performDeletionWithoutConfirmation = $false
}
$lastUserConfirmationResult = $performDeletionWithoutConfirmation -eq $true ? 
    [UserConfirmationResult]::YesForAll : [UserConfirmationResult]::Unknown

if (!((Get-AzEnvironment).Name -contains $AzEnvironment)) {
    throw [System.ApplicationException]::new("Invalid Azure environment name '$AzEnvironment'")
    return
}

Write-HostOrOutput "Signing-in to Azure..."

$loggedIn = $false
$null = Disable-AzContextAutosave -Scope Process # ensures that an AzContext is not inherited
$useSystemIdentity = ![string]::IsNullOrWhiteSpace($AutomationAccountResourceId)
$useDeviceAuth = $UseDeviceAuthentication.IsPresent
$warnAction = $useDeviceAuth ? 'Continue' : 'SilentlyContinue'
if ($useSystemIdentity -eq $true) {
    # Use system-assigned identity
    Write-HostOrOutput "Using system-assigned identity..."
    $loggedIn = Connect-AzAccount -Identity -WarningAction $warnAction -WhatIf:$false
}
elseif ($null -eq $ServicePrincipalCredential) {
    # Use user authentication (interactive or device)
    Write-HostOrOutput "Using user authentication..."
    if (![string]::IsNullOrWhiteSpace($DirectoryId)) {
        $loggedIn = Connect-AzAccount -Environment $AzEnvironment -UseDeviceAuthentication:$useDeviceAuth -TenantId $DirectoryId -WarningAction $warnAction -WhatIf:$false
    }
    else {
        $loggedIn = Connect-AzAccount -Environment $AzEnvironment -UseDeviceAuthentication:$useDeviceAuth -WarningAction $warnAction -WhatIf:$false
        $DirectoryId = (Get-AzContext).Tenant.Id
    }
}
else {
    # Use service principal authentication
    Write-HostOrOutput "Using service principal authentication..."
    $loggedIn = Connect-AzAccount -Environment $AzEnvironment -TenantId $DirectoryId -ServicePrincipal -Credential $ServicePrincipalCredential -WhatIf:$false
}
if (!$loggedIn) {
    throw [System.ApplicationException]::new("Sign-in failed")
    return
}
Write-HostOrOutput "Signed in successfully."

Write-HostOrOutput "$([Environment]::NewLine)Getting Azure subscriptions..."
$allSubscriptions = @(Get-AzSubscription -TenantId $DirectoryId | Where-Object -Property State -NE Disabled | Sort-Object -Property Name)

if ($allSubscriptions.Count -lt 1) {
    throw [System.ApplicationException]::new("No Azure subscriptions found")
    return
}

if ($null -ne $SubscriptionIdsToProcess -and $SubscriptionIdsToProcess.Count -gt 0) {
    Write-HostOrOutput "Only the following $($SubscriptionIdsToProcess.Count) of all $($allSubscriptions.Count) Azure subscriptions will be processed (according to the specified filter):"
    foreach ($s in $SubscriptionIdsToProcess) {
        Write-HostOrOutput "$($tab)$s"
    }
}
else {
    Write-HostOrOutput "All Azure subscriptions will be processed"
}

# Filled during processing and reported at the end
$usedResourceTypesWithoutHook = [System.Collections.ArrayList]@()
$signedInIdentity = $null
if ($useSystemIdentity) {
    Write-HostOrOutput "Getting system-managed identity of the automation account..."
    $signedInIdentity = Get-AzSystemAssignedIdentity -Scope $AutomationAccountResourceId
}
elseif ($null -ne $ServicePrincipalCredential) {
    Write-HostOrOutput "Getting signed-in service principal..."
    $signedInIdentity = Get-AzADServicePrincipal -ApplicationId (Get-AzContext).Account.Id
}
else {
    Write-HostOrOutput "Getting signed-in user identity..."
    $signedInIdentity = Get-AzADUser -SignedIn
}
Write-HostOrOutput "Identity Object ID: $($signedInIdentity.Id)"

foreach ($sub in $allSubscriptions) {
    if ($null -ne $SubscriptionIdsToProcess -and $SubscriptionIdsToProcess.Count -gt 0 -and !$SubscriptionIdsToProcess.Contains($sub.Id)) {
        continue
    }
    Write-HostOrOutput "$([Environment]::NewLine)vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv" -ForegroundColor Cyan
    Write-HostOrOutput "Processing subscription '$($sub.Name)' ($($sub.Id))..." -ForegroundColor Cyan

    # get all resources in current subscription
    Select-AzSubscription -SubscriptionName $sub.Name -TenantId $DirectoryId -WhatIf:$false | Out-Null

    $tempRoleAssignment = $null
    if ($TryMakingUserContributorTemporarily) {
        if ($null -ne $signedInIdentity) {
            $subscriptionResourceId = "/subscriptions/$($sub.Id)"
            $roleAssignmentExists = @((Get-AzRoleAssignment -ObjectId $signedInIdentity.Id -Scope $subscriptionResourceId -RoleDefinitionName Contributor)).Count -gt 0
            if (!$roleAssignmentExists -and $PSCmdlet.ShouldProcess($subscriptionResourceId, "Assign Contributor role")) {
                $tempRoleAssignment = New-AzRoleAssignment -ObjectId $signedInIdentity.Id -Scope $subscriptionResourceId -RoleDefinitionName Contributor `
                    -Description "Temporary permission to create tags on resources and delete empty resource groups" -ErrorAction SilentlyContinue
                if ($tempRoleAssignment) {
                    Write-HostOrOutput "$($tab)$($WhatIfHint)Contributor role was temporarily assigned to the signed-in identity '$($ServicePrincipalCredential ? $signedInIdentity.ApplicationId : $signedInIdentity.UserPrincipalName)'" -ForegroundColor DarkGray
                }
            }
        }
    }

    $resources = [System.Collections.ArrayList]@()
        $query = "resources | where type =~ 'Microsoft.Network/applicationGateways'"
    $skipToken = $null;
    $queryResult = $null;
    do {
        if ($null -eq $skipToken) {
            $queryResult = Search-AzGraph -Subscription $sub.Id -Query $query
        }
        else {
            $queryResult = Search-AzGraph -Subscription $sub.Id -Query $query -SkipToken $skipToken
        }
        $skipToken = $queryResult.SkipToken;
        $resources.AddRange($queryResult.Data)
    } while ($null -ne $skipToken)

    Write-HostOrOutput "$($tab)Number of resources to process: $($resources.Count)"
    if ($resources.Count -lt 1) {
        continue
    }

    $processedResourceGroups = [System.Collections.ArrayList]@()

    foreach ($resource in $resources) {
        Write-HostOrOutput "$($tab)Processing resource '" -NoNewline
        Write-HostOrOutput $($resource.name) -ForegroundColor White -NoNewline
        Write-HostOrOutput "' (type: $($resource.type), resource group: $($resource.resourceGroup))..."
        $resourceTypeName = $resource.type
        $resourceKindName = $resource.kind

        # process resource group
        $resourceGroupName = $resource.resourceGroup
        if (!$processedResourceGroups.Contains($resourceGroupName)) {
            $rg = Get-AzResourceGroup -Name $resourceGroupName
            $rgJustTagged = $false

            # Check for unused resource group was requested
            if ($CheckForUnusedResourceGroups) {
                # reset 'rejected' status to 'suspected' after specified time if specified, otherwise skip 'rejected' resource group
                $subjectForDeletionTagValue = ''
                $subjectForDeletionTagValue = ($rg.Tags.$subjectForDeletionTagName ?? '').Trim()
                $findingDateString = ''
                $findingDateString = ($rg.Tags.$subjectForDeletionFindingDateTagName ?? '').Trim()
                if ($subjectForDeletionTagValue -ieq [SubjectForDeletionStatus]::rejected.ToString()) {
                    if ($EnableRegularResetOfRejectedState -and $findingDateString) {
                        $findingDateTime = (Get-Date -AsUTC)
                        if ([datetime]::TryParse($findingDateString, [ref]$findingDateTime)) {
                            if ((Get-Date -AsUTC).Subtract($findingDateTime) -gt $ResetOfRejectedStatePeriodInDays) {
                                Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Resetting status from 'rejected' to 'suspected' after $ResetOfRejectedStatePeriodInDays days for resource group: $resourceGroupName..."
                                Add-SubjectForDeletionTags -ResourceOrGroup $rg -Status suspected `
                                    -AllowResetOfRejectedToSuspected -SuppressHostOutput -WhatIf:$WhatIfPreference
                            }
                        }
                    }
                    continue
                }
                # check for deployments in the specified number of last days and mark resource group for deletion if no deployments found
                $deployments = $rg | Get-AzResourceGroupDeployment | Sort-Object -Property Timestamp -Descending
                if ($deployments) {
                    # determine whether newest deployment is too old
                    $noRecentDeployments = $deployments[0].Timestamp -lt (Get-Date -AsUTC).AddDays(-$resourceGroupOldAfterDays)
                    if ($noRecentDeployments) {
                        # check activity log for relevant activity over the last 3 months (max.)
                        $activityLogs = Get-AzActivityLog -ResourceGroupName $resourceGroupName -StartTime (Get-Date -AsUTC).AddDays(-90) -EndTime (Get-Date -AsUTC)
                        $activelyUsed = $activityLogs | Where-Object { $_.Authorization.Action -imatch '^(?:(?!tags|roleAssignments).)*\/(write|action)$' }
                        if (!$activelyUsed) {
                            Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Marking potentially unused resource group '$resourceGroupName' for deletion..." -ForegroundColor Yellow
                            Add-SubjectForDeletionTags -ResourceOrGroup $rg -SuppressHostOutput -WhatIf:$WhatIfPreference `
                                -Reason "no deployments for $resourceGroupOldAfterDays days and no write/action activities for 3 months"
                            $rgJustTagged = $true
                        }
                    }
                }
            }

            $processedResourceGroups.Add($resourceGroupName) | Out-Null

            if (!$rgJustTagged) {
                # Check whether existing tags from past runs shall be removed again from the resource group
                $tags = $rg.Tags
                $subjectForDeletionTagValue = ($tags.$subjectForDeletionTagName ?? '').Trim()
                if (![string]::IsNullOrWhiteSpace($subjectForDeletionTagValue)) {
                    $taggedResources = Search-AzGraph -Query "resources | where subscriptionId =~ '$($sub.SubscriptionId)' and resourceGroup =~ '$($rg.ResourceGroupName)' and tags contains '$($subjectForDeletionTagName)'"
                    if ($taggedResources.Count -eq 0) {
                        Remove-SubjectForDeletionTags -ResourceOrGroup $rg -WhatIf:$WhatIfPreference
                    }
                }
            }
        }

        # reset 'rejected' status to 'suspected' after specified time if specified, otherwise skip 'rejected' resource
        $subjectForDeletionTagValue = ''
        $subjectForDeletionTagValue = ($resource.Tags.$subjectForDeletionTagName ?? '').Trim()
        $findingDateString = ''
        $findingDateString = ($resource.Tags.$subjectForDeletionFindingDateTagName ?? '').Trim()
        if ($subjectForDeletionTagValue -ieq [SubjectForDeletionStatus]::rejected.ToString()) {
            if ($EnableRegularResetOfRejectedState -and $findingDateString) {
                $findingDateTime = (Get-Date -AsUTC)
                if ([datetime]::TryParse($findingDateString, [ref]$findingDateTime)) {
                    if ((Get-Date -AsUTC).Subtract($findingDateTime) -gt $ResetOfRejectedStatePeriodInDays) {
                        Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Resetting status from 'rejected' to 'suspected' after $ResetOfRejectedStatePeriodInDays days for resource: $($resource.Name)..."
                        Add-SubjectForDeletionTags -ResourceOrGroup $resource -Status suspected `
                            -AllowResetOfRejectedToSuspected -SuppressHostOutput -WhatIf:$WhatIfPreference
                    }
                }
            }
            continue
        }
        
        # call resource type specific hook for testing unused characteristics of this resource
        $normalizedResourceTypeName = $resourceTypeName.Replace(".", "-").Replace("/", "-").Replace(",", "-").ToLower()
        $normalizedResourceKindName = $normalizedResourceTypeName
        if (![String]::IsNullOrWhiteSpace($resourceKindName)) {
            $normalizedResourceKindName += "-$($resourceKindName.Replace(".", "-").Replace("/", "-").Replace(",", "-").ToLower())"
        }
        $action = [ResourceAction]::none
        $reason = $null
        $hook = $null
        $hookFunctionName = "Test-ResourceActionHook-" + $normalizedResourceKindName
        $hook = (Get-Command $hookFunctionName -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
        if ($null -eq $hook) {
            if (![String]::IsNullOrWhiteSpace($resourceKindName)) {
                $usedResourceTypesWithoutHook.Add("Type: '$resourceTypeName', Kind: '$resourceKindName' (hook name: 'Test-ResourceActionHook-$normalizedResourceKindName')") | Out-Null
            }
            $hookFunctionName = "Test-ResourceActionHook-" + $normalizedResourceTypeName
            $hook = (Get-Command $hookFunctionName -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
        }
        if ($null -ne $hook) {
            
            # Delete timed-out suspected resources
            if ($DeleteSuspectedResourcesAndGroupsAfterDays -ge 0) {
                $status = ($resource.Tags.$subjectForDeletionTagName ?? '').Trim()
                $isResourceSuspected = $status -ieq [SubjectForDeletionStatus]::suspected.ToString()
                $isResourceDeletionRejected = $status -ieq [SubjectForDeletionStatus]::rejected.ToString()
                $lastEvalDateString = ($resource.Tags.$subjectForDeletionFindingDateTagName ?? '').Trim()
                if ($isResourceSuspected -and $lastEvalDateString) {
                    $lastEvalDateTime = (Get-Date -AsUTC)
                    if ([datetime]::TryParse($lastEvalDateString, [ref]$lastEvalDateTime)) {
                        if ((Get-Date -AsUTC).Subtract($lastEvalDateTime) -gt [timespan]::FromDays($DeleteSuspectedResourcesAndGroupsAfterDays)) {
                            Write-HostOrOutput "$($tab)$($tab)--> review deadline reached for this suspected resource"
                            $lastUserConfirmationResult = Get-UserConfirmationWithTimeout `
                                -DisableTimeout:$DisableTimeoutForDeleteConfirmationPrompt `
                                -LastConfirmationResult $lastUserConfirmationResult
                            if ($lastUserConfirmationResult -ne [UserConfirmationResult]::No) {
                                Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Resource is being deleted..." -ForegroundColor Red
                                Remove-AzResource -ResourceId $resource.ResourceId -Force -AsJob -WhatIf:$WhatIfPreference | Out-Null
                                continue  # skip to next resource
                            }
                            else {
                                Write-HostOrOutput "$($tab)$($tab)Deletion cancelled by user"
                            }
                        }
                    }
                }
                elseif ($isResourceDeletionRejected) {
                    # Remove reason and finding date tags
                    Remove-SubjectForDeletionTags -ResourceOrGroup $resource -WhatIf:$WhatIfPreference | Out-Null
                }
            }

            # Only test resources which are existing long enough
            $hasMinimumAge = $true  # if creation time cannot be determined we assume age to be older than 30 days
            if ($MinimumResourceAgeInDaysForChecking -gt 0) {
                $r = Get-AzResource -ResourceId $resource.id -ExpandProperties
                $createdTime = $r.Properties.CreationTime
                if ($null -ne $createdTime -and 
                    (Get-Date -AsUTC).Subtract($createdTime) -lt [timespan]::FromDays($MinimumResourceAgeInDaysForChecking)) 
                {
                    $hasMinimumAge = $false
                }
            }

            if ($hasMinimumAge) {
                # Execute test hook for current resource type
                $action, $reason = Invoke-Command -ScriptBlock $hook -ArgumentList $resource
                if ($action -eq [ResourceAction]::delete -and $AlwaysOnlyMarkForDeletion) {
                    $action = [ResourceAction]::markForDeletion
                }
            }
            else {
                # Resource doesn't have the specified minimum age for checking
                Write-HostOrOutput "$($tab)$($tab)Resource has not reached the minimum age and is ignored" -ForegroundColor DarkGray
                $action = [ResourceAction]::none
            }
            Write-HostOrOutput "$($tab)$($tab)--> action: " -NoNewline
            $color = [ConsoleColor]::Gray
            switch ($action) {
                none { $color = [ConsoleColor]::Green }
                suspected { $color = [ConsoleColor]::DarkYellow }
                markForDeletion { $color = [ConsoleColor]::Yellow }
                markForSuspectSubResourceCheck { $color = [ConsoleColor]::Yellow }
                delete { $color = [ConsoleColor]::Red }
                Default {}
            }
            Write-HostOrOutput $action.ToString() -ForegroundColor $color -NoNewline
            if (![string]::IsNullOrWhiteSpace($reason)) { Write-HostOrOutput " (reason: '$reason')" } else { Write-HostOrOutput "" }
        }
        else {
            Write-HostOrOutput "$($tab)$($tab)--> no matching test hook for this type of resource" -ForegroundColor DarkGray
            $usedResourceTypesWithoutHook.Add("Type: '$resourceTypeName' (hook name: 'Test-ResourceActionHook-$normalizedResourceTypeName')") | Out-Null
        }

        # delete or mark resource accordingly
        switch ($action) {
            "markForDeletion" {
                Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Marking resource for deletion..."
                Add-SubjectForDeletionTags -ResourceOrGroup $resource -Reason $reason -WhatIf:$WhatIfPreference
            }
            "markForSuspectSubResourceCheck" {
                Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Marking resource for check of suspect sub resources..."
                Add-SubjectForDeletionTags -ResourceOrGroup $resource -Status suspectedSubResources -Reason $reason -WhatIf:$WhatIfPreference
            }
            "delete" {
                Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Deleting resource..."
                $lastUserConfirmationResult = Get-UserConfirmationWithTimeout -DisableTimeout:$DisableTimeoutForDeleteConfirmationPrompt `
                    -LastConfirmationResult $lastUserConfirmationResult
                if ($lastUserConfirmationResult -ne [UserConfirmationResult]::No) {
                    Remove-AzResource -ResourceId $resource.ResourceId -Force -AsJob -WhatIf:$WhatIfPreference | Out-Null
                }
                else {
                    Write-HostOrOutput "$($tab)$($tab)Deletion rejected by user"
                }
            }
            default {
                $tags = $resource.Tags
                if ($tags.$subjectForDeletionTagName) {
                    # previously tagged resource changed and is no subject for deletion anymore
                    Remove-SubjectForDeletionTags -ResourceOrGroup $resource -WhatIf:$WhatIfPreference
                }
            }
        }
    }

    # Process resource groups
    Write-HostOrOutput "$($tab)Processing resource groups..."
    $resourceGroups = Get-AzResourceGroup
    foreach ($resourceGroup in $resourceGroups) {
        $rgname = $resourceGroup.ResourceGroupName

        # Delete suspected and timed-out resource groups
        if ($DeleteSuspectedResourcesAndGroupsAfterDays -ge 0) {
            $status = ($resourceGroup.Tags.$subjectForDeletionTagName ?? '').Trim()
            $isResourceGroupSuspected = $status -ieq [SubjectForDeletionStatus]::suspected.ToString()
            $isResourceGroupDeletionRejected = $status -ieq [SubjectForDeletionStatus]::rejected.ToString()
            $lastEvalDateString = ($resourceGroup.Tags.$subjectForDeletionFindingDateTagName ?? '').Trim()
            if ($isResourceGroupSuspected -and $lastEvalDateString) {
                $lastEvalDateTime = (Get-Date -AsUTC)
                if ([datetime]::TryParse($lastEvalDateString, [ref]$lastEvalDateTime)) {
                    if ((Get-Date -AsUTC).Subtract($lastEvalDateTime) -gt [timespan]::FromDays($DeleteSuspectedResourcesAndGroupsAfterDays)) {
                        Write-HostOrOutput "$($tab)$($tab)--> review deadline reached for this suspected resource group '$rgname'"
                        $lastUserConfirmationResult = Get-UserConfirmationWithTimeout -DisableTimeout:$DisableTimeoutForDeleteConfirmationPrompt `
                            -LastConfirmationResult $lastUserConfirmationResult
                        if ($lastUserConfirmationResult -ne [UserConfirmationResult]::No) {
                            Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Resource group is being deleted..." -ForegroundColor Red
                            Remove-AzResourceGroup -Name $resourceGroup.ResourceGroupName -Force -AsJob -WhatIf:$WhatIfPreference | Out-Null
                            continue  # skip to next resource group
                        }
                        else {
                            Write-HostOrOutput "$($tab)$($tab)Deletion cancelled by user"
                        }
                    }
                }
            }
            elseif ($isResourceGroupDeletionRejected) {
                # Remove reason and finding date tags
                Remove-SubjectForDeletionTags -ResourceOrGroup $resourceGroup -WhatIf:$WhatIfPreference | Out-Null
            }
        }

        # Process empty resource groups
        if (!$processedResourceGroups.Contains($rgname)) {
            # confirm that this resource group is really empty
            $resourceCount = (Get-AzResource -ResourceGroupName $rgname).Count
            if ($resourceCount -eq 0) {
                if ($AlwaysOnlyMarkForDeletion -or $DontDeleteEmptyResourceGroups) {
                    Write-HostOrOutput "$($tab)$($tab)--> action: " -NoNewline
                    Write-HostOrOutput ([ResourceAction]::markForDeletion).toString() -ForegroundColor Yellow
                    Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Marking empty resource group '$rgname' for deletion..."
                    Add-SubjectForDeletionTags -ResourceOrGroup $resourceGroup -Reason "group is empty" -WhatIf:$WhatIfPreference
                }
                else {
                    Write-HostOrOutput "$($tab)$($tab)--> action: " -NoNewline
                    Write-HostOrOutput ([ResourceAction]::delete).ToString() -ForegroundColor Red
                    Write-HostOrOutput "$($tab)$($tab)$($WhatIfHint)Deleting empty resource group '$rgname'..."
                    $lastUserConfirmationResult = Get-UserConfirmationWithTimeout -DisableTimeout:$DisableTimeoutForDeleteConfirmationPrompt `
                        -LastConfirmationResult $lastUserConfirmationResult
                    if ($lastUserConfirmationResult -ne [UserConfirmationResult]::No) {
                        Remove-AzResourceGroup -Id $resourceGroup.ResourceId -Force -AsJob -WhatIf:$WhatIfPreference | Out-Null
                    }
                    else {
                        Write-HostOrOutput "$($tab)$($tab)Deletion rejected by user"
                    }
                }
            }
        }
    }
    Write-HostOrOutput "$($tab)$($tab)Done"

    if ($TryMakingUserContributorTemporarily -and $null -ne $tempRoleAssignment -and $PSCmdlet.ShouldProcess($tempRoleAssignment.Scope, "Remove Contributor role assignment")) {
        Remove-AzRoleAssignment -InputObject $tempRoleAssignment -ErrorAction SilentlyContinue | Out-Null
        Write-HostOrOutput "$($tab)$($WhatIfHint)Contributor role was removed again from the signed-in identity '$($ServicePrincipalCredential ? $signedInIdentity.ApplicationId : $signedInIdentity.UserPrincipalName)'" -ForegroundColor DarkGray
    }
}

# Wait for still running resource deletion jobs
$runningJobs = Get-Job -State Running
if ($runningJobs.Count -gt 0) {
    Write-HostOrOutput "$([Environment]::NewLine)Waiting for all background jobs to complete..."
    while ($runningJobs.Count -gt 0) {
        Write-HostOrOutput "$($runningJobs.Count) jobs still running..." -ForegroundColor DarkGray
        $jobs = Get-Job -State Completed
        $jobs | Receive-Job | Out-null
        $jobs | Remove-Job | Out-null
        $runningJobs = Get-Job -State Running
        Start-Sleep -Seconds 5
    }
}

if ($usedResourceTypesWithoutHook.Count -gt 0) {
    Write-HostOrOutput "$([System.Environment]::NewLine)Discovered resource types without matching hook:"
    foreach ($resourceType in ($usedResourceTypesWithoutHook | Sort-Object -Unique)) {
        Write-HostOrOutput "$($tab)$resourceType"
    }
}

Write-HostOrOutput "$([System.Environment]::NewLine)Finished." -ForegroundColor Green
