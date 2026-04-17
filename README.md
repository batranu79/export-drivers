# Description

This script extracts all third-party drivers that are in use from the current online Windows installation and saves them to a specified folder. The parent folder of the target folder must already exist.

# Usage

PS> .\Export-Drivers.ps1 -TargetDirectory "C:\temp\drivers"
Exports the third-party drivers that are in used to the target folder "C:\temp\drivers".

# Use cases

This should be useful for situations when the manual installation of drivers leaves more drivers and add-ons on a reference computer than necessary.
The script filters all non-Microsoft drivers that are found in use and exports them in a central folder for easy packaging inside tools like MDT or SCCM.
