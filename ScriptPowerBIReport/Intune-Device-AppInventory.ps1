<#
DISCLAIMER:
This script is provided "as is" without warranty of any kind, express or implied. Use this script at your own risk.
The author and contributors are not responsible for any damage or issues potentially caused by the use of this script.
Always test scripts in a non-production environment before deploying them into a production setting.
#>
# Requires Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement and Az.Storage Modules
<#
####################################################
# Using Azure Automation
# Variables
$tenantID = Get-AutomationVariable 'tenantID' # Azure Tenant ID Variable
$resourceGroupName = Get-AutomationVariable 'resourceGroupName' # Resource group name
$storageAccountName = Get-AutomationVariable 'storageAccountName' # Storage account name

# Report specific Variables
$containerName = Get-AutomationVariable 'deviceInventory' # Container Name

# Graph App Registration Creds
# Uses a Secret Credential named 'GraphApi' in your Automation Account
$clientInfo = Get-AutomationPSCredential 'GraphApi'
# Username of Automation Credential is the Graph App Registration client ID 
$ClientID = $clientInfo.UserName
# Password  of Automation Credential is the Graph App Registration secret key (create one if needed)
$ClientSecret = $clientInfo.GetNetworkCredential().Password

####################################################
#>

# Variables for Storage
$resourceGroupName = "rg-IntuneReports"         # Resource Group name
$storageAccountName = "sarrifonasintunereports" # Storage Account Name

# Declare variables used by the report
$ExportPath = "." # Set the export path. Use "." for Azure Automation

# Populate with the App Registration details and Tenant ID
$ClientId          = ""      # Application ID
$ClientSecret      = ""  # Client Secret
$tenantid          = ""      # Tenant ID

# Create ClientSecretCredential
$secret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
$ClientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ClientId, $secret

#Connect to Azure
Write-Output ("Logging in to Azure...")
#Connect-AzAccount -Identity # Use with Automation Account
Connect-AzAccount -TenantId $tenantId -Credential $ClientSecretCredential -ServicePrincipal # Use with App Registration. Permissions: Subscription (Reader and Data Access) and Storage Account (Storage Blob Data Contributor)

# Authenticate to the Microsoft Graph
Connect-MgGraph -TenantId $tenantid -ClientSecretCredential $ClientSecretCredential

# Report Parameters - Device Inventory
$Reportparams = @{
    reportName = "DevicesWithInventory"
    filter = "(ManagementAgents eq '2') or (ManagementAgents eq '10') or (ManagementAgents eq '512') or (ManagementAgents eq '514') or (ManagementAgents eq '64') or (ManagementAgents eq '522')" 
    localizationType = "LocalizedValuesAsAdditionalColumn"
    format = "csv"
    select = @() # Select columns to be added or retrieve all columns
}

# Execute Device Inventory Report
$WebResult = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs" -Body $Reportparams

# Check if report is ready
$ReportStatus = ""
$ReportQuery = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$($WebResult.id)')"
$ReportStatus = Invoke-MgGraphRequest -Method GET -Uri $ReportQuery

do{
    Start-Sleep -Seconds 5
    $ReportStatus = Invoke-MgGraphRequest -Method GET -Uri $ReportQuery
    if ($?) {
        Write-Host "Report Status: $($ReportStatus.status)..."
    }
    else {
        Write-Error "Error"
        break
    }
} until ($ReportStatus.status -eq "completed" -or $ReportStatus.status -eq "failed")

# Extract Report and Rename it
Remove-Item -Path "$ExportPath\$($Reportparams.ReportName)*.csv" -Force
$ZipPath = "$ExportPath\$($Reportparams.ReportName).zip"
Invoke-WebRequest -Uri $ReportStatus.url -OutFile $ZipPath
Expand-Archive -Path $ZipPath -DestinationPath $ExportPath -Force
Remove-Item -Path $ZipPath -Force
Rename-Item -Path "$ExportPath\$($ReportStatus.Id).csv" -NewName "$($ReportStatus.reportName).csv"

# Upload File to Storage Account
$containerName = "deviceinventory" # Storage Account Container
$storageContext = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
Set-AzStorageBlobContent -Context $storageContext.Context -Container $ContainerName -File "$ExportPath\$($ReportStatus.reportName).csv" -Blob "$($ReportStatus.reportName).csv" -Force

# Report Parameters - Application Inventory
$Reportparams = @{
    reportName = "AppInvRawData"
    localizationType = "LocalizedValuesAsAdditionalColumn"
    format = "csv"
    select = @(
        "ApplicationName",
        "ApplicationPublisher",
        "ApplicationVersion",
        "DeviceId",
        "UserId"
    )
}

# Execute Application Report
$WebResult = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs" -Body $Reportparams

# Check if report is ready
$ReportStatus = ""
$ReportQuery = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$($WebResult.id)')"

do{
    Start-Sleep -Seconds 5
    $ReportStatus = Invoke-MgGraphRequest -Method GET -Uri $ReportQuery
    if ($?) {
        Write-Host "Report Status: $($ReportStatus.status)..."
    }
    else {
        Write-Error "Error"
        break
    }
} until ($ReportStatus.status -eq "completed" -or $ReportStatus.status -eq "failed")

# Extract Report and Rename it
Remove-Item -Path "$ExportPath\$($Reportparams.ReportName)*.csv" -Force
$ZipPath = "$ExportPath\$($Reportparams.ReportName).zip"
Invoke-WebRequest -Uri $ReportStatus.url -OutFile $ZipPath
Expand-Archive -Path $ZipPath -DestinationPath $ExportPath -Force
Remove-Item -Path $ZipPath -Force
Rename-Item -Path "$ExportPath\$($ReportStatus.Id).csv" -NewName "$($ReportStatus.reportName).csv"
$containerName = "appinventory" # Storage Account Container
Set-AzStorageBlobContent -Context $storageContext.Context -Container $ContainerName -File "$ExportPath\$($ReportStatus.reportName).csv" -Blob "$($ReportStatus.reportName).csv" -Force

# Crash Events Report
$GraphUri = "https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsDeviceTimelineEvent?`$filter=eventLevel eq 'error'"
$OutputFile = "CrashEvents"

$QueryResults = @()
$Results = Invoke-MgGraphRequest -Method GET -Uri $GraphUri -OutputType PSObject 
$QueryResults += $Results.value
if (!([string]::IsNullOrEmpty($Results.'@odata.nextLink'))) # Loop required for paginated output
{
    do {
            $Results = Invoke-MgGraphRequest -Method GET -Uri $Results.'@odata.nextLink' -OutputType PSObject 
            $Results.value
            $QueryResults += $Results.value
         #   Start-Sleep -Seconds 3
        } while (!([string]::IsNullOrEmpty($results.'@odata.nextLink'))) 
}

$QueryResults  | Export-Csv -Path "$ExportPath\$($OutputFile).csv" -NoTypeInformation
$containerName = "crashevents" # Storage Account Container
Set-AzStorageBlobContent -Context $storageContext.Context -Container $ContainerName -File "$ExportPath\$($OutputFile).csv" -Blob "$($OutputFile).csv" -Force

Disconnect-MgGraph
