
<#PSScriptInfo

.VERSION 1.1

.GUID 

.AUTHOR Michael Niehaus / Fabian Niesen

.COMPANYNAME Microsoft

.COPYRIGHT

.TAGS

.LICENSEURI

.PROJECTURI

.ICONURI

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES
Version 1.1: Modifications by Fabian Niesen

.PRIVATEDATA

#>

<# 

.DESCRIPTION 
 Rename the computer 

#> 

Param([Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true,
ValueFromPipeline = $True,
HelpMessage = 'Please enter Choosen Prefix'
)]
[string] $Prefix= "AP-",
#Add validation
[string]$Suffix = "",
[string]$LogFilePath = "$Env:ProgramData\IFH\Logs"

)
IF ($LogFilePath.EndsWith("\") -like "False") { $LogFilePath =$LogFilePath+"\" }
IF (!(Test-Path $LogFilePath)) { new-item -Path $LogFilePath -ItemType directory -Force }
$dayDateTime = (Get-Date -UFormat "%A %d-%m-%Y %R")
$LogFilePath = $LogFilePath + $(get-date -format yyyyMMdd-HHmm) + "-" + $MyInvocation.ScriptName + ".log"

Function Write-Log {
    #Write-Log -Message 'warning' -LogLevel 2
    #Write-Log -Message 'Error' -LogLevel 3
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
			
        [Parameter()]
        [ValidateSet(1, 2, 3)]
        [int]$LogLevel = 1,

        [Parameter(HelpMessage = 'Outputs message to Event Log,when used with -WriteEventLog')]
        [switch]$WriteEventLog
    )
    Write-Host
    Write-Host $Message
    Write-Host
    $TimeGenerated = "$(Get-Date -Format HH:mm:ss).$((Get-Date).Millisecond)+000"
    $Line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="" file="">'
    $LineFormat = $Message, $TimeGenerated, (Get-Date -Format MM-dd-yyyy), "$($MyInvocation.ScriptName | Split-Path -Leaf):$($MyInvocation.ScriptLineNumber)", $LogLevel
    $Line = $Line -f $LineFormat
    Add-Content -Value $Line -Path $LogFilePath
    If ($WriteEventLog) { Write-EventLog -LogName $EventLogName -Source $EventLogSource -Message $Message  -Id 100 -Category 0 -EntryType Information }
}

####################################################

# If we are running as a 32-bit process on an x64 system, re-launch as a 64-bit process
if ("$env:PROCESSOR_ARCHITEW6432" -ne "ARM64")
{
    if (Test-Path "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe")
    {
        & "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy bypass -File "$PSCommandPath"
        Exit $lastexitcode
    }
}

# Create a tag file just so Intune knows this was installed
if (-not (Test-Path "$($env:ProgramData)\Microsoft\RenameComputer"))
{
    Mkdir "$($env:ProgramData)\Microsoft\RenameComputer"
}
Set-Content -Path "$($env:ProgramData)\Microsoft\RenameComputer\RenameComputer.ps1.tag" -Value "Installed"

# Initialization
$dest = "$($env:ProgramData)\Microsoft\RenameComputer"
if (-not (Test-Path $dest))
{
    mkdir $dest
}
Start-Transcript "$dest\RenameComputer.log" -Append
Write-Log "Writing Transscript to: $dest\RenameComputer.log"
# Make sure we are already domain-joined
$goodToGo = $true
$details = Get-ComputerInfo
if (-not $details.CsPartOfDomain)
{
    Write-Log "Not part of a domain."
    $goodToGo = $false
}

# Make sure we have connectivity
$dcInfo = [ADSI]"LDAP://RootDSE"
if ($dcInfo.dnsHostName -eq $null)
{
    Write-Log "No connectivity to the domain."
    $goodToGo = $false
}

if ($goodToGo)
{
    # Get the new computer name
    #$newName = Invoke-RestMethod -Method GET -Uri "https://generatename.azurewebsites.net/api/HttpTrigger1?prefix=AD-"
    $SN = $(Get-CimInstance win32_bios).SerialNumber
    Write-Log "SerialNumber: $SN"
    $DisallowedChar = '. $%&!?#*:;\><|/"~^(){}_'
    $regex = "[$([regex]::Escape($DisallowedChar))]"
    $SN = $($GPO.DisplayName).Trim() -replace $regex,""
    Write-Log "Cleaned SerialNumber: $SN"
    $Prefix = $($GPO.DisplayName).Trim() -replace $regex,""
    $Suffix = $($GPO.DisplayName).Trim() -replace $regex,""
    Write-Log "Choosen Prefix >$Prefix< - Choosen Suffix >$Suffix<"
    $SNml = 15 - $Prefix.Length - $Suffix.Length
    IF ( $SN.Length -gt $SNml ) 
    {
        Write-Log "Serialnumber is longer then $SNml characters. Shorten SerialNubmer $SN" -LogLevel 2
        [bool]$shorten=$true
        $SN = $SN[0..$SNml]
    }
    $newName = $Prefix + $SN + $Suffix
    Write-Log "New genereated devicename is: $newName"
    $searcher = [adsisearcher] "(cn=$newName)"
    $rtn = $searcher.FindAll()
    IF ( $rtn.Count -ge 1 ) 
    {
        Write-Log "Hostname $newName already exists in Active Directory!" -LogLevel 3
        Write-Log "Please check and delete or reset teh device account, if the account belong to a previous installation of this device" 
        IF ($shorten -eq $true) {Write-Log "Be aware the serialnumber was shorten, the error could occour due the shortening." -LogLevel 2}
        $goodToGo = $false
    }
}
if ($goodToGo)
{

    # Set the computer name
    Write-Log "Renaming computer to $($newName)"
    Rename-Computer -NewName $newName

    # Remove the scheduled task
    Disable-ScheduledTask -TaskName "RenameComputer" -ErrorAction Ignore
    Unregister-ScheduledTask -TaskName "RenameComputer" -Confirm:$false -ErrorAction Ignore
    Write-Log "Scheduled task unregistered."

    # Make sure we reboot if still in ESP/OOBE by reporting a 1641 return code (hard reboot)
    if ($details.CsUserName -match "defaultUser")
    {
        Write-Log "Exiting during ESP/OOBE with return code 1641" -LogLevel 2
        Stop-Transcript
        Exit 1641
    }
    else {
        Write-Log "Initiating a restart in 10 minutes"
        & shutdown.exe /g /t 600 /f /c "Restarting the computer due to a computer name change.  Save your work."
        Stop-Transcript
        Exit 0
    }
}
else
{
    # Check to see if already scheduled
    $existingTask = Get-ScheduledTask -TaskName "RenameComputer" -ErrorAction SilentlyContinue
    if ($existingTask -ne $null)
    {
        Write-Log "Scheduled task already exists."
        Stop-Transcript
        Exit 0
    }

    # Copy myself to a safe place if not already there
    if (-not (Test-Path "$dest\RenameComputer.ps1"))
    {
        Copy-Item $PSCommandPath "$dest\RenameComputer.PS1"
    }

    # Create the scheduled task action
    $action = New-ScheduledTaskAction -Execute "Powershell.exe" -Argument "-NoProfile -ExecutionPolicy bypass -WindowStyle Hidden -File $dest\RenameComputer.ps1"

    # Create the scheduled task trigger
    $timespan = New-Timespan -minutes 5
    $triggers = @()
    $triggers += New-ScheduledTaskTrigger -Daily -At 9am
    $triggers += New-ScheduledTaskTrigger -AtLogOn -RandomDelay $timespan
    $triggers += New-ScheduledTaskTrigger -AtStartup -RandomDelay $timespan
    
    # Register the scheduled task
    Register-ScheduledTask -User SYSTEM -Action $action -Trigger $triggers -TaskName "RenameComputer" -Description "RenameComputer" -Force
    Write-Log "Scheduled task created."
}

Stop-Transcript
