<#
.SYNOPSIS
    Exports all third-party drivers that are in use from a Windows system to a folder.

.DESCRIPTION
    This script extracts all third-party drivers that are in use from the current online 
    Windows installation and saves them to a specified folder. 

.PARAMETER TargetDirectory
    Specifies the target folder where the drivers will be saved.
    If the specified target folder does not exist, it will be created automatically.
    The parent folder of the target folder must already exist.

.EXAMPLE
PS> .\Export-Drivers.ps1 -TargetDirectory "C:\temp\drivers"
    Exports the third-party drivers that are in used to the target folder "C:\temp\drivers".

.REQUIREMENTS
    - Administrative rights on the target computer
    - PowerShell 5.0 or newer

.NOTES
    Author   : Narcis-Ionel Mircea
    Version  : 2.5
    License  : MIT
    Created  : 14.11.2025

.VERSION HISTORY
    2.5 - Initial release

.LINK
    https://github.com/batranu79
#>

Param (
    [Parameter(Mandatory=$false)]
    [ValidateScript({Test-Path (Split-Path $_ -Parent) -PathType Container})]
    [String]
    $TargetDirectory = '.\' # working path to store the exported data
)

Write-Host "############ Starting the Export-Drivers script. ############"

# Initialize the list of detected driver packages
$Drivers = @()

### Get all relevant objects present in the OS currently
Write-Host -ForegroundColor Green "Get all relevant objects present in the OS currently."
try {
    $AllDriverFiles = Get-CimInstance -ClassName Win32_PNPSignedDriverCIMDataFile -ErrorAction Stop
    $AllDevices = Get-CimInstance -ClassName Win32_PNPEntity -ErrorAction Stop
    $PNPSignedDrivers = Get-CimInstance -ClassName Win32_PNPSignedDriver -ErrorAction Stop
    $AllSystemDriverPNPEntries = Get-CimInstance -ClassName Win32_SystemDriverPNPEntity -ErrorAction Stop
    $AllSystemDriverFileObjects = Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop
}
catch {
    Write-Host -ForegroundColor Red "ERROR: while retrieving driver related WMI objects:"
    Write-Host -ForegroundColor Red " > Exception     : $($_.Exception)."
    Write-Host -ForegroundColor Red " > InvocationLine: $($_.InvocationInfo.Line)."
    Write-Host -ForegroundColor Red " > Category      : $($_.CategoryInfo.Category)."
    return
}

Write-Host -ForegroundColor Green "Filter out the devices with Microsoft Manufacturer."
$Devices = $AllDevices | Where {$_.Name -notin ("",$null) -and $_.Manufacturer -notlike "*Microsoft*"} 

# Check the drivers for each device 
foreach ($i in $Devices) {
    $PNPSignedDriver = $null
    $DeviceName = $null
    $Driver = $null
    Write-Host -ForegroundColor Green "Checking device: $($i.Name)."

    ############################ Win32_PNPSignedDriver
    # For each device found on the system, try the WMI class Win32_PNPSignedDriver first
    $PNPSignedDriver = $PNPSignedDrivers | Where {$_.DeviceID -eq $i.DeviceID}
    if ($PNPSignedDriver -ne $null -and $PNPSignedDriver.DriverProviderName -notlike "*Microsoft*") {
        $DriverFiles = @()
        Write-Host -ForegroundColor Green " > Detected a non Microsoft driver defined for: $($PNPSignedDriver.DeviceName) - Moving on to detecting driver INF files for this device..."
        # create a Driver custom object 
        $Driver = @{ Name = $i.Name; DeviceID = $i.DeviceID; InfPath = ""; InfHash = ""; PackagePath = "" }
        # get the list of driver files for the current driver
        $DriverFiles += $AllDriverFiles | where {$_.Antecedent.DeviceID -eq $i.DeviceID} | Select-Object -ExpandProperty Dependent | Select-Object -ExpandProperty Name
        if ($DriverFiles.Count -gt 0) {
            Write-Host " >> Some driver files have been detected... Moving on to driver folder detection from DriverStore."
            foreach ($x in $DriverFiles) {
                if ($x.Split("\\")[$x.Split("\\").Length-1].split(".")[1] -eq "inf") {
                    # We get the file object for each INF file
                    $InfItem = Get-Item -Path $x
                    $Driver.InfPath = $InfItem.FullName
                    $InfHash = Get-FileHash -Path $InfItem.FullName
                    $Driver.InfHash = $InfHash.Hash
                    Write-Output " >>> The current driver file is ""$x"" for the device ""$($i.Name)"" and with Hash ""$($InfHash.Hash)""."
                    # Search in the DriverRepository for all packages containing this INF file, with the same length
                    $PackagedInfDrivers = Get-ChildItem C:\Windows\System32\DriverStore\FileRepository -Include "*.inf" -Recurse | where {$_.Length -eq $InfItem.Length}
                    # Initialize the array of found driver packages for this INF file size
                    $CurrentlyDetectedPackages = @()
                    foreach ($f in $PackagedInfDrivers) {
                        $Hash = $null
                        $Hash = Get-FileHash -Path $f.FullName
                        Write-Output " >>> Checking packaged inf path ""$($f.FullName)"" with Hash ""$($Hash.Hash)""."
                        if ($Hash.Hash -eq $InfHash.Hash) {
                            $PackagePath = Split-Path -Path $f -Parent
                            Write-Host " >>>> Hash matched for ""$($f.FullName)""! PackagePath detected $PackagePath." -ForegroundColor Magenta
                            $CurrentlyDetectedPackages += $PackagePath
                        }
                        else {
                            Write-Host " >>>> Hash not matched for ""$($f.FullName)""!" -ForegroundColor Yellow
                        }
                    }
                    # In case several driver packages are found with the same INF file length and hash, proceed to a second pass detection
                    if ($CurrentlyDetectedPackages.Count -gt 1 ) {
                        Write-Host " >>>>> More than one Driver Packages have been detected for the current inf file ""$($InfItem.FullName)""! Trying to filter down." -ForegroundColor Gray
                        # Initialize a second array of found driver packages for this WMI driver object
                        $CurrentlyDetectedPackages2 = @()
                        # In the second pass, get all non-inf driver files, because all of them must match in a Driver Package folder, for it to be considered detected on the second pass
                        foreach ($DrvPkg in $CurrentlyDetectedPackages) {
                            Write-Host " >>>>>> Validating package $DrvPkg." -ForegroundColor Gray
                            $PkgValidated = $true
                            foreach ($q in $DriverFiles) {
                                $DrvFileValidated = $false
                                $nipath = $null
                                $nipath2 = $null
                                $DriverItem = $null
                                $DriverItemMatch = @()
                                # Now process only files other than INF
                                if ($q.Split("\\")[$q.Split("\\").Length-1].split(".")[1] -ne "inf") {
                                    # get the file objects
                                    $DriverItem = Get-Item -Path $q
                                    Write-Host " >>>>>>> For package $DrvPkg, validating driver file $($DriverItem.FullName)." -ForegroundColor Gray
                                    $DriverItemMatch = Get-ChildItem $DrvPkg -Exclude "*.inf" -Recurse | where {$_.Length -eq $DriverItem.Length}
                                    if ($DriverItemMatch.Count -gt 0) {
                                        foreach ($dim in $DriverItemMatch) {
                                            if ((Get-FileHash -Path $dim.FullName).Hash -eq (Get-FileHash -Path $DriverItem.FullName).Hash) {
                                                $DrvFileValidated = $true
                                                Write-Host " >>>>>>>> For package $DrvPkg, driver file $($DriverItem.FullName) is validated." -ForegroundColor Gray
                                                break
                                            }
                                        }
                                    }
                                    if (!$DrvFileValidated) {
                                        Write-Host " >>>>>>> The package $DrvPkg not validated for driver file $($DriverItem.FullName)." -ForegroundColor Gray
                                        $PkgValidated = $false
                                        break
                                    }
                                }
                            }
                            if ($PkgValidated) {
                                 Write-Host " >>>>>>> The package $DrvPkg is overall validated." -ForegroundColor Gray
                                 $CurrentlyDetectedPackages2 += $DrvPkg
                            }
                        }
                        foreach ($DrvPkg2 in $CurrentlyDetectedPackages2) {
                            if (!($Drivers.PackagePath -contains $DrvPkg2)){
                                Write-Host " >>>>>>> Adding the package $DrvPkg to the results." -ForegroundColor Gray
                                $Driver.PackagePath = $DrvPkg2
                                $Drivers += [pscustomobject]$Driver
                            }
                            else {
                                Write-Host " >>>>>>> Package $DrvPkg already present." -ForegroundColor Gray
                            }
                        }
                    }
                    elseif ($CurrentlyDetectedPackages.Count -eq 1 ) {
                        # In case only one packaged driver is found, add it to the final results array, if it is not already present there, detected from another device
                        Write-Host " >>>>> One Driver Packages have been detected for the current inf file ""$($InfItem.FullName)""!" -ForegroundColor Gray
                        if (!($Drivers.PackagePath -contains $PackagePath)){
                            Write-Host " >>>>>> Adding the package $PackagePath to the results." -ForegroundColor Gray
                            $Driver.PackagePath = $PackagePath
                            $Drivers += [pscustomobject]$Driver
                        }
                        else {
                            Write-Host " >>>>>> Package $PackagePath already present." -ForegroundColor Gray
                        }

                    }
                    else {
                        Write-Host " >>>> No Driver Package detected for driver file ""$($InfItem.FullName)"" and device ""$($i.Name)""" -ForegroundColor Magenta
                    }
                } 
            } 
        } 

        ######################## Win32_SystemDriver
        else {
            $SystemDriverPNPEntries = @()
            $SystemDriverFileObjects = @()
            Write-Host -ForegroundColor Cyan "For device: ""$($i.Name)"" - no driver files have been detected in the Win32_PNPSignedDriverCIMDataFile WMI class. Moving on to Win32_SystemDriver WMI class."
            $SystemDriverPNPEntries += $AllSystemDriverPNPEntries | where {$_.Antecedent.DeviceID -eq $i.DeviceID} | Select-Object -ExpandProperty Dependent | Select-Object -ExpandProperty Name
  
            if ($SystemDriverPNPEntries.Count -gt 0) {
                foreach ($SystemDriverPNPEntry in $SystemDriverPNPEntries) {
                    $SystemDriverFileObjects += $AllSystemDriverFileObjects | where {$_.Name -eq $SystemDriverPNPEntry}
                    if ($SystemDriverFileObjects.Count -gt 0) {
                        foreach ($SystemDriverFileObject in $SystemDriverFileObjects) {
                            $SysItem = $null
                            $SystemDriverPath = $SystemDriverFileObject.PathName
                            Write-Host "Driver Path detected for the current device is $SystemDriverPath."
                            # Testing driver file path before getting file information
                            if (Test-Path -Path $SystemDriverPath) {
                                $SysItem = Get-Item -Path $SystemDriverPath
                                # Checking now to see if this sys file is not actually released by Microsoft...
                                if ($SysItem.VersionInfo.ProductName -like "*Microsoft*" -or $SysItem.VersionInfo.CompanyName -like "*Microsoft*") {
                                    Write-Host "This driver file is a Microsoft product. Skipping..."
                                    continue
                                }
                                # continue now to detect the associated folder from the DriverStore
                                # search in the DriverRepository for all packages containing this SYS file, with the same length
                                $PackagedSysDrivers = Get-ChildItem C:\Windows\System32\DriverStore\FileRepository -Include "*.sys" -Recurse | where {$_.Length -eq $SysItem.Length -and $_.Name -eq $SysItem.Name}
                                # initialize the array of found driver packages for this SYS file
                                $CurrentlyDetectedPackages = @()
                                $DriverStorePath = ("$env:windir\System32\DriverStore\FileRepository\").ToLower()
                                # The sys files found here may be present in subfolders of the driver packages from the FileRepository, so the entire driver packages must be detected in this case and not their subfolders
                                if ($PackagedSysDrivers.Count -gt 0){
                                    Write-Host " > One or more files detected with the same file length. Trying to filter down."
                                    foreach ($f in $PackagedSysDrivers) {
                                        if ((Get-FileHash -Path $f.FullName).Hash -eq (Get-FileHash -Path $SysItem.FullName).Hash) {
                                            Write-Host " >> Hash matched for driver path $($f.FullName). Checking path validity." -ForegroundColor Magenta
                                            $CurrentPath = $f.FullName.ToLower()
                                            if (!$CurrentPath.StartsWith($DriverStorePath)) {
                                                Write-Host " >>> This driver path ($CurrentPath) is not valid for export as it is not present in the OS driver file repository. Skipping..."
                                                continue
                                            }
                                            else {
                                                $PackagePath = $DriverStorePath + $CurrentPath.Replace($DriverStorePath,"").Split("\")[0]
                                                Write-Host " >>> PackagePath detected $PackagePath" -ForegroundColor Magenta
                                            }
                                            # add each result only after making sure there is no duplicate
                                            if (!($CurrentlyDetectedPackages -contains $PackagePath)){
                                            $CurrentlyDetectedPackages += $PackagePath
                                            }
                                        }
                                        else {
                                            Write-Host " >> Hash not matched for driver path $($f.FullName)." -ForegroundColor Yellow
                                        }
                                    }
                                    # add all discovered packages to the master array
                                    foreach ($z in $CurrentlyDetectedPackages) {
                                        if (!($Drivers.PackagePath -contains $z)){
                                            $Driver.PackagePath = $z
                                            $Drivers += [pscustomobject]$Driver
                                        }
                                    } 
                                } 
                            }
                        }
                    }
                    else {
                        Write-Host "No driver files have been detected for the current device in the Win32_SystemDriver either."
                    }
                }
            }
            else {
                Write-Host -ForegroundColor Cyan "For device: ""$($i.Name)"" - no driver files have been detected in the Win32_SystemDriver WMI class either."
            }
        }
    }
    elseif ($PNPSignedDriver -eq $null) {
        Write-Host "No driver files detected in the Win32_PNPSignedDriver for the current device."
    }
    elseif ($PNPSignedDriver.DriverProviderName -like "*Microsoft*") {
        Write-Host "The currently found device driver is provided by Microsoft. Skipping..."
    }
}


############################################################################################## Export Drivers section
# create the target folder before the copy operation
if (!(Test-Path -Path $TargetDirectory -PathType container)) {New-Item -Path $TargetDirectory -ItemType "directory"}

# copy each Driver Package detected to the target folder
foreach ($v in $Drivers) {
    $v.PackagePath
    Copy-Item -Path $v.PackagePath -Destination $TargetDirectory -Recurse -Force
}

Write-Host "############ Finished the Export-Drivers script. ############"
