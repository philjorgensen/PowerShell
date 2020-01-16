﻿<#
	.SYNOPSIS
		Create a ConfigMgr Application for Lenovo System Update or Thin Installer

	.DESCRIPTION
		Script will download the latest version of System Update or Thin Installer from Lenovo's support site, creates a ConfigMgr Application/Deployment Type, and distributes to a Distribution Point

	.PARAMETER SystemUpdateSourcePath
		Source location System Update executable will be downloaded to

	.PARAMETER ThinInstallerSourcePath
		Source location Thin Installer executable will be downloaded to

	.PARAMETER DistributionPoint
		FQDN Name of a ConfigMgr Distribution Point

	.NOTES
		Run script as Administrator on Site Server
		Turn off Internet Explorer Enhanced Security Control for Administrators prior to running

	.EXAMPLE
        	.\Create-ConfigMgrSU_TIApplication.ps1 -SystemUpdateSourcePath "\\Share\Software\Lenovo\SystemUpdate\5.07.88" -DistributionPoint "\\dp.local"

	.EXAMPLE
		.\Create-ConfigMgrSU_TIApplication.ps1 -ThinInstallerSourcePath "\\Share\Software\Lenovo\ThinInstaller\1.3.00018" -DistributionPoint "\\dp.local"

#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory=$false)]
    [ValidateNotNull()]
    [String]$SystemUpdateSourcePath,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [String]$ThinInstallerSourcePath,

    [Parameter(Mandatory=$true, HelpMessage = "Specify FQDN of a Distribution Point")]
    [String]$DistributionPoint = 'FQDN of Distribution Point'

)

# Parse the TVT Admin Tools web page for the the current versions
$path = "https://support.lenovo.com/solutions/ht037099"
$ie = New-Object -ComObject InternetExplorer.Application
$ie.visible = $false
$ie.navigate($path)
while ($ie.ReadyState -ne 4) { Start-Sleep -Milliseconds 100 }
$document = $ie.document

If ($SystemUpdateSourcePath)
    {
        $suExeURL = $document.links | ? { $_.href.Contains("system_update") -and $_.href.EndsWith(".exe") } | % { $_.href }
        $suExe = $suExeURL.Split('/')[5]
        $suExeVer = $suExe.Split('_')[2].TrimEnd('.exe')
        # Downloading System Update to source location
        Invoke-WebRequest -Uri $suExeURL -OutFile "$SystemUpdateSourcePath\$suExe"
    }

If ($ThinInstallerSourcePath)
    {
        $tiExeURL = $document.links | ? { $_.href.Contains("thininstaller") -and $_.href.EndsWith(".exe") } | % { $_.href }
        $tiExe = $tiExeURL.Split('/')[5]
        # Downloading Thin Installer to source location
        Invoke-WebRequest -Uri $tiExeURL -OutFile "$ThinInstallerSourcePath\$tiExe"
        $tiExeVerRaw = (Get-ChildItem -Path "$ThinInstallerSourcePath\$tiExe").VersionInfo.FileVersionRaw
        $tiExeVer = "$($tiExeVerRaw.Major).$($tiExeVerRaw.Minor).$($tiExeVerRaw.Build)"
    }

$ie.Quit() > $null

<#
Saving the Thumbprint of the System Update and Thin Installer certificates as a variable
This will eventually change once a new certificate has been issued
#>

$Thumbprint = "CC5EE80524D43ACD5A32AB1F3A9D163CEE924443"

# Compare Certificate Thumbprints to verify authenticity.  Script errors out if thumbprints do not match.
If ($SystemUpdateSourcePath)
    {
        If ((Get-AuthenticodeSignature -FilePath $SystemUpdateSourcePath\$suExe).SignerCertificate.Thumbprint -ne $Thumbprint)
            {
                Write-Error "Certificate thumbprints do not match.  Exiting out" -ErrorAction Stop
            }
    }

If ($ThinInstallerSourcePath)
    {
        If ((Get-AuthenticodeSignature -FilePath $ThinInstallerSourcePath\$tiExe).SignerCertificate.Thumbprint -ne $Thumbprint)
            {
                Write-Error "Certificate thumbprints do not match. Exiting out" -ErrorAction Stop
            }
    }

# Import ConfigMgr PS Module
Import-Module $env:SMS_ADMIN_UI_PATH.Replace("bin\i386", "bin\ConfigurationManager.psd1") -Force

# Connect to ConfigMgr Site
$SiteCode = $(Get-WmiObject -ComputerName "$ENV:COMPUTERNAME" -Namespace "root\SMS" -Class "SMS_ProviderLocation").SiteCode
If (!(Get-PSDrive $SiteCode)) { }
New-PSDrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root "$ENV:COMPUTERNAME" -Description "Primary Site Server" -ErrorAction SilentlyContinue
Set-Location "$SiteCode`:"

# Create the System Update App
If ($SystemUpdateSourcePath)
    {
        If (!(Get-CMApplication -ApplicationName "System Update-$suExeVer")) `
            {
                $suApp = New-CMApplication -Name "System Update-$suExeVer" `
                    -Publisher "Lenovo" `
                    -SoftwareVersion "$suExeVer" `
                    -LocalizedName "Lenovo System Update" `
                    -LocalizedDescription "System Update enables IT administrators to distribute updates for software, drivers, and BIOS in a managed environment from a local server." `
                    -LinkText "https://support.lenovo.com/downloads/ds012808" `
                    -Verbose

                # Create Registry detection clause
                $clause1 = New-CMDetectionClauseRegistryKeyValue -ExpressionOperator IsEquals `
                    -Hive LocalMachine `
                    -KeyName "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\TVSU_is1" `
                    -PropertyType Version `
                    -ValueName "DisplayVersion" `
                    -Value:$true `
                    -ExpectedValue "$suExeVer" `
                    -Verbose

                # Add Deployment Type
                $suApp | Add-CMScriptDeploymentType -DeploymentTypeName "System Update-$suExeVer" `
                    -ContentLocation $SystemUpdateSourcePath `
                    -InstallCommand "$suExe /verysilent /norestart" `
                    -UninstallCommand "unins000.exe /verysilent /norestart" `
                    -UninstallWorkingDirectory "%PROGRAMFILES(X86)%\Lenovo\System Update" `
                    -AddDetectionClause $clause1 `
                    -InstallationBehaviorType InstallForSystem `
                    -Verbose
            }
    }

# Create the Thin Installer App
If ($ThinInstallerSourcePath)
    {
        If (!(Get-CMApplication -ApplicationName "Thin Installer-$tiExeVer"))
            {
                $tiApp = New-CMApplication -Name "Thin Installer-$tiExeVer" `
                    -Publisher "Lenovo" `
                    -SoftwareVersion "$tiExeVer" `
                    -LocalizedName "Lenovo Thin Installer" `
                    -LocalizedDescription "Thin Installer is a smaller version of System Update." `
                    -LinkText "https://support.lenovo.com/solutions/ht037099#ti" `
                    -Verbose

                # Create Registry detection clause
                $clause2 = New-CMDetectionClauseFile -Path "%PROGRAMFILES(x86)%\Lenovo\ThinInstaller" `
                    -FileName "ThinInstaller.exe" `
                    -PropertyType Version `
                    -Value:$true `
                    -ExpressionOperator IsEquals `
                    -ExpectedValue $tiExeVer `
                    -Verbose

                # Add Deployment Type
                $tiApp | Add-CMScriptDeploymentType -DeploymentTypeName "ThinInstaller-$tiExeVer" `
                    -ContentLocation $ThinInstallerSourcePath `
                    -InstallCommand "$tiExe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" `
                    -UninstallCommand 'powershell.exe -Command Remove-Item -Path "${env:ProgramFiles(x86)}\Lenovo\ThinInstaller" -Recurse' `
                    -AddDetectionClause $clause2 `
                    -InstallationBehaviorType InstallForSystem `
                    -Verbose
            }
    }

# Distribute app to Distribution Point
If ($SystemUpdateSourcePath)
    {
        $suApp | Start-CMContentDistribution -DistributionPointName $DistributionPoint -ErrorAction SilentlyContinue -Verbose
    }

If ($ThinInstallerSourcePath)
    {
        ($tiApp) | Start-CMContentDistribution -DistributionPointName $DistributionPoint -ErrorAction SilentlyContinue -Verbose
    }

Set-Location -Path $env:HOMEDRIVE