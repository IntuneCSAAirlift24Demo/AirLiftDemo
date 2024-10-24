# Data Collection Rule (DCR) and Data Collection Endpoint (DCE) details
$DcrImmutableId = "dcr-a658c2efcc4249beaab715b8df62d51b" # DCR ID
$DceURI = "https://intunedatacdrendpoint-dmwp.eastus-1.ingest.monitor.azure.com" # DCE endpoint where data will be sent
$Table = "IntuneDevices3_CL" # custom log that must be created already

# Microsoft Entra ID Authentication details
$tenantId = "" #Azure AD Tenant ID
$appId = "" #the app ID created and granted permissions
$appSecret = "" #the secret created for the app id above

# Function to get the Azure AD token (Bearer token) for Graph API
$body = @{
    client_id     = $appId
    scope         = "https://graph.microsoft.com/.default"
    client_secret = $appSecret
    grant_type    = "client_credentials"
}
$tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$headers = @{"Content-Type" = "application/x-www-form-urlencoded"}
$bearerToken = (Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body -Headers $headers).access_token

# Graph API request headers with the Bearer token
$graphHeaders = @{
    "Authorization" = "Bearer $bearerToken"
    "Content-Type"  = "application/json"
}

# Graph API URL for querying Critical Device Timeline Events
$graphUri = "https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsDeviceTimelineEvent?`$filter=eventLevel eq 'critical'"

# Initialize an empty array to hold Device Timeline data
$allDeviceTimelineEvents = @()

# Loop to handle paginated responses from Graph API
do {
    # Get the data from the current page
    $response = Invoke-RestMethod -Uri $graphUri -Method Get -Headers $graphHeaders
    
    # Append current page of events to the list
    $allDeviceTimelineEvents += $response.value
    
    # Check if there's another page to query
    $graphUri = $response.'@odata.nextLink'
    
} while ($graphUri) # Continue until there's no more pages

# Prepare device timeline information for logging, converting each device into a custom object
$Events = $allDeviceTimelineEvents | ForEach-Object {
    [PSCustomObject]@{
        TimeGenerated   = (Get-Date).ToString("dddd MM/dd/yyyy HH:mm K")
        deviceId        = $_.deviceId
        eventDateTime   = $_.eventDateTime
        eventDetails    = $_.eventDetails
        eventLevel      = $_.eventLevel
        eventName       = $_.eventName
        eventSource     = $_.eventSource
        id              = $_.id
    }
}

# Get a new token for data ingestion
$scope = [System.Web.HttpUtility]::UrlEncode("https://monitor.azure.com/.default")
$body = "client_id=$appId&scope=$scope&client_secret=$appSecret&grant_type=client_credentials";
$headers = @{"Content-Type" = "application/x-www-form-urlencoded" };
$uri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$bearerToken = (Invoke-RestMethod -Uri $uri -Method "Post" -Body $body -Headers $headers).access_token

# Prepare and upload data to Azure Monitor (DCE)
$body = $Events | ConvertTo-Json
$headers = @{"Authorization" = "Bearer $bearerToken"; "Content-Type" = "application/json" };
$uri = "$DceURI/dataCollectionRules/$DcrImmutableId/streams/Custom-$Table"+"?api-version=2023-01-01";
$uploadResponse = Invoke-RestMethod -Uri $uri -Method "Post" -Body $body -Headers $headers;
