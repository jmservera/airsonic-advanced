#!/usr/bin/env pwsh
<#
    A script to set the needed permissions needed by Azure AD authentication for MySQL - Flexible Server
    This script is based on the following article:
    https://techcommunity.microsoft.com/t5/azure-database-for-mysql-blog/azure-ad-authentication-for-mysql-flexible-server-from-end-to/ba-p/3696353
#>
param(
    # The tenant ID of the Azure AD tenant where the User Managed Identity gets permissions
    [String]$TenantId,
    # The name of the User Managed Identity service principal
    [String]$UmiName,
    # A token to authenticate to Azure AD, if not provided, the script will prompt for credentials
    [String]$Token)


$graphappid = "00000003-0000-0000-c000-000000000000"
$permissions = "Directory.Read.All", "User.Read.All","Application.Read.All"
$scopes= "AppRoleAssignment.ReadWrite.All","User.Read.All", "Group.Read.All"

if(!$Token)
{
    Connect-MgGraph -TenantId $TenantId -Scopes $scopes
}
else{
    Connect-MgGraph -AccessToken $Token
}

$isGlobalAdmin = $false
Connect-MgGraph -AccessToken $Token
while(!$isGlobalAdmin){
    $usrId=(get-mguser -Filter "UserPrincipalName eq '$($(get-mgcontext).Account)'").Id
    if($usrId -ne $null){
        $isGlobalAdmin = $( (Get-MgDirectoryRoleMember -DirectoryRoleId (Get-MgDirectoryRole -Filter "DisplayName eq 'Global Administrator'").Id -Filter "Id eq '$usrId'").Id -eq $usrId )
    }
    
    Write-Host "isGlobalAdmin: $isGlobalAdmin"
    if(!$isGlobalAdmin){
        Write-Host "You need to be a Global Administrator to run this script, please login again with a Global Administrator account"
        Connect-MgGraph -TenantId $TenantId -Scopes $scopes
    }    
}

$umi = (Get-MgServicePrincipal -Filter "displayName eq '$UmiName'")

$graphsp = Get-MgServicePrincipal -Filter "appId eq '$graphappid'"

$approles = $graphsp.AppRoles | Where-Object {$_.Value -in ($permissions) -and $_.AllowedMemberTypes -contains "Application"}

foreach ($approle in $approles)
{
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $umi.Id -PrincipalId $umi.Id -ResourceId $graphsp.Id -AppRoleId $approle.Id
}
