$Environment = Get-EnvironmentInformation
function Start-PSPackage {
    [CmdletBinding(DefaultParameterSetName='Version',SupportsShouldProcess=$true)]
    param(
        # PowerShell packages use Semantic Versioning http://semver.org/
        [Parameter(ParameterSetName = "Version")]
        [string]$Version,

        [Parameter(ParameterSetName = "ReleaseTag")]
        [ValidatePattern("^v\d+\.\d+\.\d+(-\w+\.\d+)?$")]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseTag,

        # Package name
        [ValidatePattern("^powershell")]
        [string]$Name = "powershell",

        # Ubuntu, CentOS, Fedora, OS X, and Windows packages are supported
        [ValidateSet("deb", "osxpkg", "rpm", "msi", "appx", "zip", "AppImage")]
        [string[]]$Type,

        # Generate windows downlevel package
        [ValidateSet("win81-x64", "win7-x86", "win7-x64")]
        [ValidateScript({$Environment.IsWindows})]
        [string]$WindowsDownLevel
    )

    # Runtime and Configuration settings required by the package
    ($Runtime, $Configuration) = if ($WindowsDownLevel) {
        $WindowsDownLevel, "Release"
    } else {
        New-PSOptions -Configuration "Release" -WarningAction SilentlyContinue | ForEach-Object { $_.Runtime, $_.Configuration }
    }
    Write-Verbose "Packaging RID: '$Runtime'; Packaging Configuration: '$Configuration'" -Verbose

    $Script:Options = Get-PSOptions
    
    # Make sure the most recent build satisfies the package requirement
    if (-not $Script:Options -or                                ## Start-PSBuild hasn't been executed yet
        -not $Script:Options.CrossGen -or                       ## Last build didn't specify -CrossGen
        $Script:Options.Runtime -ne $Runtime -or                ## Last build wasn't for the required RID
        $Script:Options.Configuration -ne $Configuration -or    ## Last build was with configuration other than 'Release'
        $Script:Options.Framework -ne "netcoreapp2.0")          ## Last build wasn't for CoreCLR
    {
        # It's possible that the most recent build doesn't satisfy the package requirement but
        # an earlier build does. e.g., run the following in order on win10-x64:
        #    Start-PSBuild -Clean -CrossGen -Runtime win10-x64 -Configuration Release
        #    Start-PSBuild -FullCLR
        #    Start-PSPackage -Type msi
        # It's also possible that the last build actually satisfies the package requirement but
        # then `Start-PSPackage` runs from a new PS session or `build.psm1` was reloaded.
        #
        # In these cases, the user will be asked to build again even though it's technically not
        # necessary. However, we want it that way -- being very explict when generating packages.
        # This check serves as a simple gate to ensure that the user knows what he is doing, and
        # also ensure `Start-PSPackage` does what the user asks/expects, because once packages
        # are generated, it'll be hard to verify if they were built from the correct content.
        throw "Please ensure you have run 'Start-PSBuild -Clean -CrossGen -Runtime $Runtime -Configuration $Configuration'!"
    }

    # If ReleaseTag is specified, use the given tag to calculate Vesrion
    if ($PSCmdlet.ParameterSetName -eq "ReleaseTag") {
        $Version = $ReleaseTag -Replace '^v'
    }

    # Use Git tag if not given a version
    if (-not $Version) {
        $Version = (git --git-dir="$PSScriptRoot/../../.git" describe) -Replace '^v'
    }

    $Source = Split-Path -Path $Script:Options.Output -Parent
    Write-Verbose "Packaging Source: '$Source'" -Verbose

    # Decide package output type
    if (-not $Type) {
        $Type = if ($Environment.IsLinux) {
            if ($Environment.LinuxInfo.ID -match "ubuntu") {
                "deb"
            } elseif ($Environment.IsRedHatFamily) {
                "rpm"
            } else {
                throw "Building packages for $($Environment.LinuxInfo.PRETTY_NAME) is unsupported!"
            }
        } elseif ($Environment.IsOSX) {
            "osxpkg"
        } elseif ($Environment.IsWindows) {
            "msi", "appx"
        }
        Write-Warning "-Type was not specified, continuing with $Type!"
    }
    Write-Verbose "Packaging Type: $Type" -Verbose

    # Build the name suffix for win-plat packages
    if ($Environment.IsWindows) {
        # Add the server name to the $RunTime. $runtime produced by dotnet is same for client or server
        switch ($Runtime) {
            'win81-x64' {$NameSuffix = 'win81-win2012r2-x64'}
            'win10-x64' {$NameSuffix = 'win10-win2016-x64'}
            'win7-x64'  {$NameSuffix = 'win7-win2008r2-x64'}
            Default {$NameSuffix = $Runtime}
        }
    }

    switch ($Type) {
        "zip" {
            $Arguments = @{
                PackageNameSuffix = $NameSuffix
                PackageSourcePath = $Source
                PackageVersion = $Version
            }

            if($pscmdlet.ShouldProcess("Create Zip Package"))
            {
                New-ZipPackage @Arguments
            }
        }
        "msi" {
            $TargetArchitecture = "x64"
            if ($Runtime -match "-x86")
            {
                $TargetArchitecture = "x86"
            }

            $Arguments = @{
                ProductNameSuffix = $NameSuffix
                ProductSourcePath = $Source
                ProductVersion = $Version
                AssetsPath = "$PSScriptRoot\..\..\assets"
                LicenseFilePath = "$PSScriptRoot\..\..\assets\license.rtf"
                # Product Guid needs to be unique for every PowerShell version to allow SxS install
                ProductGuid = New-Guid
                ProductTargetArchitecture = $TargetArchitecture;
            }

            if($pscmdlet.ShouldProcess("Create MSI Package"))
            {
                New-MSIPackage @Arguments
            }
        }
        "appx" {
            $Arguments = @{
                PackageNameSuffix = $NameSuffix
                PackageSourcePath = $Source
                PackageVersion = $Version
                AssetsPath = "$PSScriptRoot\..\..\assets"
            }
            New-AppxPackage @Arguments
        }
        "AppImage" {
            if ($Environment.IsUbuntu14) {
                $null = Start-NativeExecution { bash -iex "$PSScriptRoot/../appimage.sh" }
                $appImage = Get-Item PowerShell-*.AppImage
                if ($appImage.Count -gt 1) {
                    throw "Found more than one AppImage package, remove all *.AppImage files and try to create the package again"
                }
                Rename-Item $appImage.Name $appImage.Name.Replace("-","-$Version-")
            } else {
                Write-Warning "Ignoring AppImage type for non Ubuntu Trusty platform"
            }
        }
        default {
            $Arguments = @{
                Type = $_
                PackageSourcePath = $Source
                Name = $Name
                Version = $Version
            }

            if($pscmdlet.ShouldProcess("Create $_ Package"))
            {
                New-UnixPackage @Arguments
            }
        }
    }
}

function New-UnixPackage {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("deb", "osxpkg", "rpm")]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$PackageSourcePath,

        # Must start with 'powershell' but may have any suffix
        [Parameter(Mandatory)]
        [ValidatePattern("^powershell")]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Version,

        # Package iteration version (rarely changed)
        # This is a string because strings are appended to it
        [string]$Iteration = "1"
    )

    # Validate platform
    $ErrorMessage = "Must be on {0} to build '$Type' packages!"
    switch ($Type) {
        "deb" {
            $WarningMessage = "Building for Ubuntu {0}.04!"
            if (!$Environment.IsUbuntu) {
                    throw ($ErrorMessage -f "Ubuntu")
                } elseif ($Environment.IsUbuntu14) {
                    Write-Warning ($WarningMessage -f "14")
                } elseif ($Environment.IsUbuntu16) {
                    Write-Warning ($WarningMessage -f "16")
                }
        }
        "rpm" {
            if (!$Environment.IsRedHatFamily) {
                throw ($ErrorMessage -f "Redhat Family")
            }
        }
        "osxpkg" {
            if (!$Environment.IsOSX) {
                throw ($ErrorMessage -f "OS X")
            }
        }
    }

    foreach ($Dependency in "fpm", "ronn") {
        if (!(precheck $Dependency "Package dependency '$Dependency' not found. Run Start-PSBootstrap -Package")) {
            # These tools are not added to the path automatically on OpenSUSE 13.2
            # try adding them to the path and re-tesing first
            [string] $gemsPath = $null
            [string] $depenencyPath = $null
            $gemsPath = Get-ChildItem -Path /usr/lib64/ruby/gems   | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
            if($gemsPath) {
                $depenencyPath  = Get-ChildItem -Path (Join-Path -Path $gemsPath -ChildPath "gems" -AdditionalChildPath $Dependency) -Recurse  | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty DirectoryName
                $originalPath = $env:PATH
                $env:PATH = $ENV:PATH +":" + $depenencyPath
                if((precheck $Dependency "Package dependency '$Dependency' not found. Run Start-PSBootstrap -Package")) {
                    continue
                }
                else {
                    $env:PATH = $originalPath
                }
            }

            throw "Dependency precheck failed!"
        }
    }

    $Description = @"
PowerShell is an automation and configuration management platform.
It consists of a cross-platform command-line shell and associated scripting language.
"@

    # Suffix is used for side-by-side package installation
    $Suffix = $Name -replace "^powershell"
    if (!$Suffix) {
        Write-Warning "Suffix not given, building primary PowerShell package!"
        $Suffix = $Version
    }

    # Setup staging directory so we don't change the original source directory
    $Staging = "$PSScriptRoot/staging"
    if($pscmdlet.ShouldProcess("Create staging folder"))
    {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Staging
        Copy-Item -Recurse $PackageSourcePath $Staging

        # Rename files to given name if not "powershell"
        if ($Name -ne "powershell") {
            $Files = @("powershell",
                    "powershell.dll",
                    "powershell.deps.json",
                    "powershell.pdb",
                    "powershell.runtimeconfig.json",
                    "powershell.xml")

            foreach ($File in $Files) {
                $NewName = $File -replace "^powershell", $Name
                Move-Item "$Staging/$File" "$Staging/$NewName"
            }
        }
    }

    # Follow the Filesystem Hierarchy Standard for Linux and OS X
    $Destination = if ($Environment.IsLinux) {
        "/opt/microsoft/powershell/$Suffix"
    } elseif ($Environment.IsOSX) {
        "/usr/local/microsoft/powershell/$Suffix"
    }

    # Destination for symlink to powershell executable
    $Link = if ($Environment.IsLinux) {
        "/usr/bin"
    } elseif ($Environment.IsOSX) {
        "/usr/local/bin"
    }

    if($pscmdlet.ShouldProcess("Create package file system"))
    {
        New-Item -Force -ItemType SymbolicLink -Path "/tmp/$Name" -Target "$Destination/$Name" >$null

        if ($Environment.IsRedHatFamily) {
            # add two symbolic links to system shared libraries that libmi.so is dependent on to handle
            # platform specific changes. This is the only set of platforms needed for this currently
            # as Ubuntu has these specific library files in the platform and OSX builds for itself
            # against the correct versions.
            New-Item -Force -ItemType SymbolicLink -Target "/lib64/libssl.so.10" -Path "$Staging/libssl.so.1.0.0" >$null
            New-Item -Force -ItemType SymbolicLink -Target "/lib64/libcrypto.so.10" -Path "$Staging/libcrypto.so.1.0.0" >$null

            $AfterInstallScript = [io.path]::GetTempFileName()
            $AfterRemoveScript = [io.path]::GetTempFileName()
            @'
#!/bin/sh
if [ ! -f /etc/shells ] ; then
    echo "{0}" > /etc/shells
else
    grep -q "^{0}$" /etc/shells || echo "{0}" >> /etc/shells
fi
'@ -f "$Link/$Name" | Out-File -FilePath $AfterInstallScript -Encoding ascii

        @'
if [ "$1" = 0 ] ; then
    if [ -f /etc/shells ] ; then
        TmpFile=`/bin/mktemp /tmp/.powershellmXXXXXX`
        grep -v '^{0}$' /etc/shells > $TmpFile
        cp -f $TmpFile /etc/shells
        rm -f $TmpFile
    fi
fi
'@ -f "$Link/$Name" | Out-File -FilePath $AfterRemoveScript -Encoding ascii
        }
        elseif ($Environment.IsUbuntu) {
            $AfterInstallScript = [io.path]::GetTempFileName()
            $AfterRemoveScript = [io.path]::GetTempFileName()
            @'
#!/bin/sh
set -e
case "$1" in
    (configure)
        add-shell "{0}"
    ;;
    (abort-upgrade|abort-remove|abort-deconfigure)
        exit 0
    ;;
    (*)
        echo "postinst called with unknown argument '$1'" >&2
        exit 0
    ;;
esac
'@ -f "$Link/$Name" | Out-File -FilePath $AfterInstallScript -Encoding ascii

        @'
#!/bin/sh
set -e
case "$1" in
        (remove)
        remove-shell "{0}"
        ;;
esac
'@ -f "$Link/$Name" | Out-File -FilePath $AfterRemoveScript -Encoding ascii
        }


        # there is a weird bug in fpm
        # if the target of the powershell symlink exists, `fpm` aborts
        # with a `utime` error on OS X.
        # so we move it to make symlink broken
        $symlink_dest = "$Destination/$Name"
        $hack_dest = "./_fpm_symlink_hack_powershell"
        if ($Environment.IsOSX) {
            if (Test-Path $symlink_dest) {
                Write-Warning "Move $symlink_dest to $hack_dest (fpm utime bug)"
                Move-Item $symlink_dest $hack_dest
            }
        }

        # run ronn to convert man page to roff
        $RonnFile = Join-Path $PSScriptRoot "/../../assets/powershell.1.ronn"
        $RoffFile = $RonnFile -replace "\.ronn$"

        # Run ronn on assets file
        # Run does not play well with files named powershell6.0.1, so we generate and then rename
        Start-NativeExecution { ronn --roff $RonnFile }

        # Setup for side-by-side man pages (noop if primary package)
        $FixedRoffFile = $RoffFile -replace "powershell.1$", "$Name.1"
        if ($Name -ne "powershell") {
            Move-Item $RoffFile $FixedRoffFile
        }

        # gzip in assets directory
        $GzipFile = "$FixedRoffFile.gz"
        Start-NativeExecution { gzip -f $FixedRoffFile }

        $ManFile = Join-Path "/usr/local/share/man/man1" (Split-Path -Leaf $GzipFile)

        # Change permissions for packaging
        Start-NativeExecution {
            find $Staging -type d | xargs chmod 755
            find $Staging -type f | xargs chmod 644
            chmod 644 $GzipFile
            chmod 755 "$Staging/$Name" # only the executable should be executable
        }
    }

    # Setup package dependencies
    # These should match those in the Dockerfiles, but exclude tools like Git, which, and curl
    $Dependencies = @()
    if ($Environment.IsUbuntu) {
        $Dependencies = @(
            "libc6",
            "libcurl3",
            "libgcc1",
            "libssl1.0.0",
            "libstdc++6",
            "libtinfo5",
            "libunwind8",
            "libuuid1",
            "zlib1g"
        )
        # Please note the different libicu package dependency!
        if ($Environment.IsUbuntu14) {
            $Dependencies += "libicu52"
        } elseif ($Environment.IsUbuntu16) {
            $Dependencies += "libicu55"
        }
    } elseif ($Environment.IsRedHatFamily) {
        $Dependencies = @(
            "glibc",
            "libicu",
            "openssl",
            "libunwind",
            "uuid",
            "zlib"
        )

        if($Environment.IsFedora -or $Environment.IsCentOS)
        {
            $Dependencies += "libcurl"
            $Dependencies += "libgcc"
            $Dependencies += "libstdc++"
            $Dependencies += "ncurses-base"
        }

        if($Environment.IsOpenSUSE)
        {
            $Dependencies += "libgcc_s1"
            $Dependencies += "libstdc++6"
        }
    }

    # iteration is "debian_revision"
    # usage of this to differentiate distributions is allowed by non-standard
    if ($Environment.IsUbuntu14) {
        $Iteration += "ubuntu1.14.04.1"
    } elseif ($Environment.IsUbuntu16) {
        $Iteration += "ubuntu1.16.04.1"
    }

    # We currently only support:
    # CentOS 7
    # Fedora 24+
    # OpenSUSE 42.1 (13.2 might build but is EOL)
    # Also SEE: https://fedoraproject.org/wiki/Packaging:DistTag
    if ($Environment.IsCentOS) {
        $rpm_dist = "el7"
    } elseif ($Environment.IsFedora) {
        $version_id = $Environment.LinuxInfo.VERSION_ID
        $rpm_dist = "fedora.$version_id"
    } elseif ($Environment.IsOpenSUSE) {
        $version_id = $Environment.LinuxInfo.VERSION_ID
        $rpm_dist = "suse.$version_id"
    }


    $Arguments = @(
        "--force", "--verbose",
        "--name", $Name,
        "--version", $Version,
        "--iteration", $Iteration,
        "--maintainer", "PowerShell Team <PowerShellTeam@hotmail.com>",
        "--vendor", "Microsoft Corporation",
        "--url", "https://microsoft.com/powershell",
        "--license", "MIT License",
        "--description", $Description,
        "--category", "shells",
        "-t", $Type,
        "-s", "dir"
    )
    if ($Environment.IsRedHatFamily) {
        $Arguments += @("--rpm-dist", $rpm_dist)
        $Arguments += @("--rpm-os", "linux")
    }
    foreach ($Dependency in $Dependencies) {
        $Arguments += @("--depends", $Dependency)
    }
    if ($AfterInstallScript) {
       $Arguments += @("--after-install", $AfterInstallScript)
    }
    if ($AfterRemoveScript) {
       $Arguments += @("--after-remove", $AfterRemoveScript)
    }
    $Arguments += @(
        "$Staging/=$Destination/",
        "$GzipFile=$ManFile",
        "/tmp/$Name=$Link"
    )
    # Build package
    try {
        if($pscmdlet.ShouldProcess("Create $type package"))
        {
            $Output = Start-NativeExecution { fpm $Arguments }
        }
    } finally {
        if ($Environment.IsOSX) {
            # this is continuation of a fpm hack for a weird bug
            if (Test-Path $hack_dest) {
                Write-Warning "Move $hack_dest to $symlink_dest (fpm utime bug)"
                Move-Item $hack_dest $symlink_dest
            }
        }
        if ($AfterInstallScript) {
           Remove-Item -erroraction 'silentlycontinue' $AfterInstallScript
        }
        if ($AfterRemoveScript) {
           Remove-Item -erroraction 'silentlycontinue' $AfterRemoveScript
        }
    }

    # Magic to get path output
    $createdPackage = Get-Item (Join-Path $PWD (($Output[-1] -split ":path=>")[-1] -replace '["{}]'))

    if ($Environment.IsOSX) {
        if($pscmdlet.ShouldProcess("Fix package name"))
        {
            # Add the OS information to the OSX package file name.
            $packageExt = [System.IO.Path]::GetExtension($createdPackage.Name)
            $packageNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($createdPackage.Name)

            $newPackageName = "{0}-{1}{2}" -f $packageNameWithoutExt, $script:Options.Runtime, $packageExt
            $newPackagePath = Join-Path $createdPackage.DirectoryName $newPackageName
            $createdPackage = Rename-Item $createdPackage.FullName $newPackagePath -PassThru
        }
    }

    return $createdPackage
}

# Function to create a zip file for Nano Server and xcopy deployment
function New-ZipPackage
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (

        # Name of the Product
        [ValidateNotNullOrEmpty()]
        [string] $PackageName = 'PowerShell',

        # Suffix of the Name
        [string] $PackageNameSuffix,

        # Version of the Product
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageVersion,

        # Source Path to the Product Files - required to package the contents into an Zip
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageSourcePath
    )

    $ProductSemanticVersion = Get-PackageSemanticVersion -Version $PackageVersion

    $zipPackageName = $PackageName + "-" + $ProductSemanticVersion
    if ($PackageNameSuffix) {
        $zipPackageName = $zipPackageName, $PackageNameSuffix -join "-"
    }

    Write-Verbose "Create Zip for Product $zipPackageName"

    $zipLocationPath = Join-Path $PWD "$zipPackageName.zip"

    If(Get-Command Compress-Archive -ErrorAction Ignore)
    {
        if($pscmdlet.ShouldProcess("Create zip package"))
        {
            Compress-Archive -Path $PackageSourcePath\* -DestinationPath $zipLocationPath
        }

        Write-Verbose "You can find the Zip @ $zipLocationPath" -Verbose
        $zipLocationPath

    }
    #TODO: Use .NET Api to do compresss-archive equivalent if the pscmdlet is not present
    else
    {
        Write-Error -Message "Compress-Archive cmdlet is missing in this PowerShell version"
    }
}
