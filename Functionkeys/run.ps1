using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

function getKuduCreds($appName, $resourceGroup) {
    
    [XML]$PublishingProfile = (Get-AzWebAppPublishingProfile -ResourceGroupName $resourceGroup -Name $appName)
  
    $user = (Select-Xml -Xml $PublishingProfile -XPath "//publishData/publishProfile[contains(@profileName,'Web Deploy')]/@userName").Node.Value
    $pass = (Select-Xml -Xml $PublishingProfile -XPath "//publishData/publishProfile[contains(@profileName,'Web Deploy')]/@userPWD").Node.Value
 
    $pair = $user + ':' + $pass
    $kuduCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
 
    return $kuduCredentials
}

function Add-AzFunctionKey {
 
    Param(
        [string]$appName,
        [string]$resourceGroup,
        [string]$funcKeyName,
        [string]$funcKeyValue
    )

    $kuduCredentials = (getKuduCreds $appName $resourceGroup)
    $authToken = Invoke-RestMethod -Uri "https://$appName.scm.azurewebsites.net/api/functions/admin/token" -Headers @{Authorization = ("Basic {0}" -f $kuduCredentials)} -Method GET
 
    $functions = Invoke-RestMethod -Method GET -Headers @{Authorization = ("Bearer {0}" -f $authToken)} -Uri "https://$appName.azurewebsites.net/admin/functions"
    $functions = $functions.Name
    
    foreach ($functionName in $functions) {
        if ($functionName -eq $funcName) {
            $data = @{ 
                "name"  = "$funcKeyName"
                "value" = "$funcKeyValue"
            }
            $json = $data | ConvertTo-Json;
    
            $keys = Invoke-RestMethod -Method PUT -Headers @{Authorization = ("Bearer {0}" -f $authToken)} -ContentType "application/json" -Uri "https://$appName.azurewebsites.net/admin/functions/$functionName/keys/$funcKeyName" -body $json
            
            #Write-Output "Function '$functionName' key ('$funcKeyName') updated => $keys"
            Write-Output "Function '$functionName' key ('$funcKeyName') updated"
        }
    }
}

function Get-RandomString {
	
	[CmdletBinding()]
	Param (
            [int] $length = 64
	)

    return ( -join ((0x30..0x39) + ( 0x41..0x5A) + ( 0x61..0x7A) | Get-Random -Count $length  | % {[char]$_}) )	
}

function getFunctionKey([string]$appName, [string]$functionName, [string]$funcKeyName, [string]$encodedCreds)
{
    $jwt = Invoke-RestMethod -Uri "https://$appName.scm.azurewebsites.net/api/functions/admin/token" -Headers @{Authorization=("Basic {0}" -f $encodedCreds)} -Method GET

    $keys = Invoke-RestMethod -Method GET -Headers @{Authorization=("Bearer {0}" -f $jwt)} `
            -Uri "https://$appName.azurewebsites.net/admin/functions/$functionName/keys" 

    #Write-Host "keys: " $keys.keys
    foreach ($key in $keys.keys){
        #Write-Host "key: " $key
        if($funcKeyName -eq $key.name)
        {
            $code = $key.value
        }

    }
    #$code = $keys.keys[0].value
    return $code
}

$pwd = $env:Password
$appid = $env:ApplicationId
$tenantid = $env:TenantId
$resourceGroup = $env:ResourceGroup
$appName = $env:AppName
$funcName = $env:FuncName

$passwd = ConvertTo-SecureString $pwd -AsPlainText -Force
$pscredential = New-Object System.Management.Automation.PSCredential($appid, $passwd)
Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant $tenantid 

$funcKeyName = $Request.Body.Account

$funcKeyValue = getFunctionKey $appName $funcName $funcKeyName (getKuduCreds $appName $resourceGroup)
Write-Host "funcKeyValue: " $funcKeyValue

if (-not $funcKeyValue){
    Write-Host "Add-AzFunctionKey"
    $funcKeyValue = (Get-RandomString)
    Add-AzFunctionKey $appName $resourceGroup $funcKeyName $funcKeyValue
}

# Interact with query parameters or the body of the request.
$name = $Request.Query.Name
if (-not $name) {
    $name = $Request.Body.Name
}

if ($name) {
    $status = [HttpStatusCode]::OK
    $body = @{"Account"=$funcKeyName;"IoTKey"=$funcKeyValue}
}
else {
    $status = [HttpStatusCode]::BadRequest
    $body = "Please pass a name on the query string or in the request body."
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $status
    Body = $body
})
