Param(
    [Parameter(Mandatory=$false)]
    [string]$ReviewID,
    [Parameter(Mandatory=$false)]
    [string]$Branch="master",
    [Parameter(Mandatory=$false)]
    [string]$CommitID,
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile="${env:WORKSPACE}\build-parameters.txt"
)

$ErrorActionPreference = "Stop"

$globalVariables = (Resolve-Path "$PSScriptRoot\..\global-variables.ps1").Path
$ciUtils = (Resolve-Path "$PSScriptRoot\..\Modules\CIUtils").Path

Import-Module $ciUtils
. $globalVariables

$global:BUILD_STATUS = $null
$global:LOGS_URLS = @()


function Install-Prerequisites {
    $prerequisites = @{
        'git'= @{
            'url'= $GIT_URL
            'install_args' = @("/SILENT")
            'install_dir' = $GIT_DIR
        }
        'cmake'= @{
            'url'= $CMAKE_URL
            'install_args'= @("/quiet")
            'install_dir'= $CMAKE_DIR
        }
        'gnuwin32'= @{
            'url'= $GNU_WIN32_URL
            'install_args'= @("/VERYSILENT","/SUPPRESSMSGBOXES","/SP-")
            'install_dir'= $GNU_WIN32_DIR
        }
        'python27'= @{
            'url'= $PYTHON_URL
            'install_args'= @("/qn")
            'install_dir'= $PYTHON_DIR
        }
        'putty'= @{
            'url'= $PUTTY_URL
            'install_args'= @("/q")
            'install_dir'= $PUTTY_DIR
        }
        '7zip'= @{
            'url'= $7ZIP_URL
            'install_args'= @("/q")
            'install_dir'= $7ZIP_DIR
        }
        'vs2017'= @{
            'url'= $VS2017_URL
            'install_args'= @(
                "--quiet",
                "--add", "Microsoft.VisualStudio.Component.CoreEditor",
                "--add", "Microsoft.VisualStudio.Workload.NativeDesktop",
                "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                "--add", "Microsoft.VisualStudio.Component.VC.DiagnosticTools",
                "--add", "Microsoft.VisualStudio.Component.Windows10SDK.15063.Desktop",
                "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
                "--add", "Microsoft.VisualStudio.Component.VC.ATL"
            )
            'install_dir'= $VS2017_DIR
        }
    }
    foreach($program in $prerequisites.Keys) {
        if(Test-Path $prerequisites[$program]['install_dir']) {
            Write-Output "$program is already installed"
            continue
        }
        Write-Output "Downloading $program from $($prerequisites[$program]['url'])"
        $fileName = $prerequisites[$program]['url'].Split('/')[-1]
        $programFile = Join-Path $env:TEMP $fileName
        Invoke-WebRequest -UseBasicParsing -Uri $prerequisites[$program]['url'] -OutFile $programFile
        $parameters = @{
            'FilePath' = $programFile
            'ArgumentList' = $prerequisites[$program]['install_args']
            'Wait' = $true
            'PassThru' = $true
        }
        if($programFile.EndsWith('.msi')) {
            $parameters['FilePath'] = 'msiexec.exe'
            $parameters['ArgumentList'] += @("/i", $programFile)
        }
        Write-Output "Installing $programFile"
        $p = Start-Process @parameters
        if($p.ExitCode -ne 0) {
            Throw "Failed to install prerequisite $programFile during the environment setup"
        }
    }
    # Add all the tools to PATH
    $toolsDirs = @("$CMAKE_DIR\bin", "$GIT_DIR\cmd", "$GIT_DIR\bin", "$PYTHON_DIR",
                   "$PYTHON_DIR\Scripts", "$7ZIP_DIR", "$GNU_WIN32_DIR\bin")
    $env:PATH += ';' + ($toolsDirs -join ';')
}

function Start-MesosCIProcess {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$ProcessPath,
        [Parameter(Mandatory=$false)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory=$true)]
        [string]$StdoutFileName,
        [Parameter(Mandatory=$true)]
        [string]$StderrFileName,
        [Parameter(Mandatory=$true)]
        [string]$BuildErrorMessage
    )
    $stdoutFile = Join-Path $MESOS_BUILD_LOGS_DIR $StdoutFileName
    $stderrFile = Join-Path $MESOS_BUILD_LOGS_DIR $StderrFileName
    New-Item -ItemType File -Path $stdoutFile
    New-Item -ItemType File -Path $stderrFile
    $logsUrl = Get-BuildLogsUrl
    $stdoutUrl = "${logsUrl}/${StdoutFileName}"
    $stderrUrl = "${logsUrl}/${StderrFileName}"
    $command = $ProcessPath -replace '\\', '\\'
    if($ArgumentList.Count) {
        $ArgumentList | Foreach-Object { $command += " $($_ -replace '\\', '\\')" }
    }
    try {
        Wait-ProcessToFinish -ProcessPath $ProcessPath -ArgumentList $ArgumentList `
                             -StandardOutput $stdoutFile -StandardError $stderrFile
        $msg = "Successfully executed: $command"
    } catch {
        $msg = "Failed command: $command"
        $global:BUILD_STATUS = 'FAIL'
        $global:LOGS_URLS += $($stdoutUrl, $stderrUrl)
        Write-Output "Exception: $($_.ToString())"
        Add-Content -Path $ParametersFile -Value "FAILED_COMMAND=$command"
        Throw $BuildErrorMessage
    } finally {
        Write-Output $msg
        Write-Output "Stdout log available at: $stdoutUrl"
        Write-Output "Stderr log available at: $stderrUrl"
    }
}

function Copy-CmakeBuildLogs {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$BuildName
    )
    Copy-Item "$MESOS_DIR\CMakeFiles\CMakeOutput.log" "$MESOS_BUILD_LOGS_DIR\$BuildName-CMakeOutput.log"
    Copy-Item "$MESOS_DIR\CMakeFiles\CMakeError.log" "$MESOS_BUILD_LOGS_DIR\$BuildName-CMakeError.log"
    if($global:BUILD_STATUS -eq 'FAIL') {
        $logsUrl = Get-BuildLogsUrl
        $global:LOGS_URLS += $("$logsUrl/$BuildName-CMakeOutput.log", "$logsUrl/$BuildName-CMakeError.log")
    }
}

function Add-ReviewBoardPatch {
    Write-Output "Applying Reviewboard patch(es) over Mesos $Branch branch"
    $tempFile = Join-Path $env:TEMP "mesos_dependent_review_ids"
    Start-MesosCIProcess -ProcessPath "python.exe" -StdoutFileName "get-review-ids-stdout.log" -StderrFileName "get-review-ids-stderr.log" `
                         -ArgumentList @("$PSScriptRoot\utils\get-review-ids.py", "-r", $ReviewID, "-o", $tempFile) `
                         -BuildErrorMessage "Failed to get dependent review IDs for the current patch."
    $reviewIDs = Get-Content $tempFile
    if(!$reviewIDs) {
        Write-Output "There aren't any reviews to be applied"
        return
    }
    Write-Output "Patches IDs that need to be applied: $reviewIDs"
    foreach($id in $reviewIDs) {
        Write-Output "Applying patch ID: $id"
        Push-Location $MESOS_GIT_REPO_DIR
        try {
            if($id -eq $ReviewID) {
                $buildErrorMsg = "Failed to apply the current review."
            } else {
                $buildErrorMsg = "Failed to apply the dependent review: $id."
            }
            Start-MesosCIProcess -ProcessPath "python.exe" -StdoutFileName "apply-review-${id}-stdout.log" -StderrFileName "apply-review-${id}-stderr.log" `
                                 -ArgumentList @(".\support\apply-reviews.py", "-n", "-r", $id) -BuildErrorMessage $buildErrorMsg
        } finally {
            Pop-Location
        }
    }
    Add-Content -Path $ParametersFile -Value "APPLIED_REVIEWS=$($reviewIDs -join '|')"
    Write-Output "Finished applying Reviewboard patch(es)"
}

function Set-LatestMesosCommit {
    Push-Location $MESOS_GIT_REPO_DIR
    try {
        if($CommitID) {
            Start-ExternalCommand { git.exe reset --hard $CommitID } -ErrorMessage "Failed to set Mesos git repo last commit to: $CommitID."
        }
        Start-ExternalCommand { git.exe log -n 1 } -ErrorMessage "Failed to get the latest commit message for the Mesos git repo" | Out-File "$MESOS_BUILD_LOGS_DIR\latest-commit.log"
        $mesosCommitId = Start-ExternalCommand { git.exe log --format="%H" -n 1 } -ErrorMessage "Failed to get the latest commit id for the Mesos git repo"
        Set-Variable -Name "LATEST_COMMIT_ID" -Value $mesosCommitId -Scope Global -Option ReadOnly
    } finally {
        Pop-Location
    }
}

function Get-LatestCommitID {
    if(!$global:LATEST_COMMIT_ID) {
        Throw "Failed to get the latest Mesos commit ID. Perhaps it has not saved."
    }
    return $global:LATEST_COMMIT_ID
}

function New-Environment {
    Write-Output "Creating new tests environment"
    Start-EnvironmentCleanup # Do an environment cleanup to make sure everything is fresh
    New-Directory $MESOS_DIR
    New-Directory $MESOS_BUILD_DIR
    New-Directory $MESOS_BINARIES_DIR
    New-Directory $MESOS_BUILD_OUT_DIR -RemoveExisting
    New-Directory $MESOS_BUILD_LOGS_DIR
    Add-Content -Path $ParametersFile -Value "BRANCH=$Branch"
    # Clone Mesos repository
    Start-GitClone -Path $MESOS_GIT_REPO_DIR -URL $MESOS_GIT_URL -Branch $Branch
    Set-LatestMesosCommit
    if($ReviewID) {
        # Pull the patch and all the dependent ones, if a review ID was given
        Add-ReviewBoardPatch
    }
    Start-ExternalCommand { git.exe config --global user.email "ostcauto@microsoft.com" } -ErrorMessage "Failed to set git user email"
    Start-ExternalCommand { git.exe config --global user.name "ostcauto" } -ErrorMessage "Failed to set git user name"
    # Set Visual Studio variables based on tested branch
    if ($branch -eq "master") {
        Set-VCVariables "15.0"
    } else {
        Set-VCVariables "14.0"
    }
    Write-Output "New tests environment was successfully created"
}

function Start-MesosBuild {
    Write-Output "Building Mesos"
    Push-Location $MESOS_DIR
    $logsUrl = Get-BuildLogsUrl
    try {
        if($Branch -eq "master") {
            $generatorName = "Visual Studio 15 2017 Win64"
        } else {
            $generatorName = "Visual Studio 14 2015 Win64"
        }
        Start-MesosCIProcess -ProcessPath "cmake.exe" -StdoutFileName "mesos-build-cmake-stdout.log" -StderrFileName "mesos-build-cmake-stderr.log" `
                             -ArgumentList @("$MESOS_GIT_REPO_DIR", "-G", "`"$generatorName`"", "-T", "host=x64", "-DENABLE_LIBEVENT=1", "-DHAS_AUTHENTICATION=0") `
                             -BuildErrorMessage "Mesos failed to build."
    } finally {
        Copy-CmakeBuildLogs -BuildName 'mesos-build'
        Pop-Location
    }
    Write-Output "Mesos was successfully built"
}

function Start-StdoutTestsBuild {
    Write-Output "Started Mesos stdout-tests build"
    Push-Location $MESOS_DIR
    try {
        Start-MesosCIProcess -ProcessPath "cmake.exe" -StdoutFileName "stout-tests-build-cmake-stdout.log" -StderrFileName "stout-tests-build-cmake-stderr.log" `
                             -ArgumentList @("--build", ".", "--target", "stout-tests", "--config", "Debug") `
                             -BuildErrorMessage "Mesos stdout-tests failed to build."
    } finally {
        Copy-CmakeBuildLogs -BuildName 'stdout-tests'
        Pop-Location
    }
    Write-Output "stdout-tests were successfully built"
}

function Start-StdoutTestsRun {
    Write-Output "Started Mesos stdout-tests run"
    Start-MesosCIProcess -ProcessPath "$MESOS_DIR\3rdparty\stout\tests\Debug\stout-tests.exe" `
                         -StdoutFileName "stdout-tests-stdout.log" -StderrFileName "stdout-tests-stderr.log" `
                         -BuildErrorMessage "Some Mesos stdout-tests tests failed."
    Write-Output "stdout-tests PASSED"
}

function Start-LibprocessTestsBuild {
    Write-Output "Started Mesos libprocess-tests build"
    Push-Location $MESOS_DIR
    try {
        Start-MesosCIProcess -ProcessPath "cmake.exe" -StdoutFileName "libprocess-tests-build-cmake-stdout.log" -StderrFileName "libprocess-tests-build-cmake-stderr.log" `
                             -ArgumentList @("--build", ".", "--target", "libprocess-tests", "--config", "Debug") `
                             -BuildErrorMessage "Mesos libprocess-tests failed to build"
    } finally {
        Copy-CmakeBuildLogs -BuildName 'libprocess-tests'
        Pop-Location
    }
    Write-Output "libprocess-tests were successfully built"
}

function Start-LibprocessTestsRun {
    Write-Output "Started Mesos libprocess-tests run"
    Start-MesosCIProcess -ProcessPath "$MESOS_DIR\3rdparty\libprocess\src\tests\Debug\libprocess-tests.exe" `
                         -StdoutFileName "libprocess-tests-stdout.log" -StderrFileName "libprocess-tests-stderr.log" `
                         -BuildErrorMessage "Some Mesos libprocess-tests failed."
    Write-Output "libprocess-tests PASSED"
}

function Start-MesosTestsBuild {
    Write-Output "Started Mesos tests build"
    Push-Location $MESOS_DIR
    try {
        Start-MesosCIProcess -ProcessPath "cmake.exe" -StdoutFileName "mesos-tests-build-cmake-stdout.log" -StderrFileName "mesos-tests-build-cmake-stderr.log" `
                             -ArgumentList @("--build", ".", "--target", "mesos-tests", "--config", "Debug") `
                             -BuildErrorMessage "Mesos tests failed to build."
    } finally {
        Copy-CmakeBuildLogs -BuildName 'mesos-tests'
        Pop-Location
    }
    Write-Output "Mesos tests were successfully built"
}

function Start-MesosTestsRun {
    Write-Output "Started Mesos tests run"
    Start-MesosCIProcess -ProcessPath "$MESOS_DIR\src\mesos-tests.exe" -ArgumentList @('--verbose') `
                         -StdoutFileName "mesos-tests-stdout.log" -StderrFileName "mesos-tests-stderr.log" `
                         -BuildErrorMessage "Some Mesos tests failed."
    Write-Output "mesos-tests PASSED"
}

function New-MesosBinaries {
    Write-Output "Started building Mesos binaries"
    Push-Location $MESOS_DIR
    try {
        Start-MesosCIProcess -ProcessPath "cmake.exe" -StdoutFileName "mesos-binaries-build-cmake-stdout.log" -StderrFileName "mesos-binaries-build-cmake-stderr.log" `
                             -ArgumentList @("--build", ".") -BuildErrorMessage "Mesos binaries failed to build."
    } finally {
        Copy-CmakeBuildLogs -BuildName 'mesos-binaries'
        Pop-Location
    }
    Write-Output "Mesos binaries were successfully built"
    New-Directory $MESOS_BUILD_BINARIES_DIR
    Copy-Item -Force -Exclude @("mesos-tests.exe","test-helper.exe") -Path "$MESOS_DIR\src\*.exe" -Destination "$MESOS_BUILD_BINARIES_DIR\"
    Compress-Files -FilesDirectory "$MESOS_BUILD_BINARIES_DIR\" -Filter "*.exe" -Archive "$MESOS_BUILD_BINARIES_DIR\mesos-binaries.zip"
    Copy-Item -Force -Exclude @("mesos-tests.pdb","test-helper.pdb") -Path "$MESOS_DIR\src\*.pdb" -Destination "$MESOS_BUILD_BINARIES_DIR\"
    Compress-Files -FilesDirectory "$MESOS_BUILD_BINARIES_DIR\" -Filter "*.pdb" -Archive "$MESOS_BUILD_BINARIES_DIR\mesos-pdb.zip"
    Write-Output "Mesos binaries were successfully generated"
}

function Copy-FilesToRemoteServer {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$LocalFilesPath,
        [Parameter(Mandatory=$true)]
        [string]$RemoteFilesPath
    )
    Write-Output "Started copying files from $LocalFilesPath to remote location at ${server}:${RemoteFilesPath}"
    Start-SCPCommand -Server $REMOTE_LOG_SERVER -User $REMOTE_USER -Key $REMOTE_KEY `
                     -LocalPath $LocalFilesPath -RemotePath $RemoteFilesPath
}

function New-RemoteDirectory {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$RemoteDirectoryPath
    )
    $remoteCMD = "if [[ -d $RemoteDirectoryPath ]]; then rm -rf $RemoteDirectoryPath; fi; mkdir -p $RemoteDirectoryPath"
    Start-SSHCommand -Server $REMOTE_LOG_SERVER -User $REMOTE_USER -Key $REMOTE_KEY -Command $remoteCMD
}

function New-RemoteSymlink {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$RemotePath,
        [Parameter(Mandatory=$false)]
        [string]$RemoteSymlinkPath
    )
    $remoteCMD = "if [[ -h $RemoteSymlinkPath ]]; then unlink $RemoteSymlinkPath; fi; ln -s $RemotePath $RemoteSymlinkPath"
    Start-SSHCommand -Server $REMOTE_LOG_SERVER -User $REMOTE_USER -Key $REMOTE_KEY -Command $remoteCMD
}

function Get-RemoteBuildDirectoryPath {
    if($ReviewID) {
        return "$REMOTE_MESOS_BUILD_DIR/review/$ReviewID"
    }
    $mesosCommitID = Get-LatestCommitID
    return "$REMOTE_MESOS_BUILD_DIR/$Branch/$mesosCommitID"
}

function Get-RemoteLatestSymlinkPath {
    if($ReviewID) {
        return "$REMOTE_MESOS_BUILD_DIR/review/latest"
    }
    return "$REMOTE_MESOS_BUILD_DIR/$Branch/latest"
}

function Get-BuildOutputsUrl {
    if($ReviewID) {
        return "$MESOS_BUILD_BASE_URL/review/$ReviewID"
    }
    $mesosCommitID = Get-LatestCommitID
    return "$MESOS_BUILD_BASE_URL/$Branch/$mesosCommitID"
}

function Get-BuildLogsUrl {
    $buildOutUrl = Get-BuildOutputsUrl
    return "$buildOutUrl/logs"
}

function Get-BuildBinariesUrl {
    $buildOutUrl = Get-BuildOutputsUrl
    return "$buildOutUrl/binaries"
}

function Start-LogServerFilesUpload {
    Param(
        [Parameter(Mandatory=$false)]
        [switch]$NewLatest
    )
    $consoleLog = Join-Path $env:WORKSPACE "mesos-build-$Branch-${env:BUILD_NUMBER}.log"
    if(Test-Path $consoleLog) {
        Copy-Item -Force $consoleLog "$MESOS_BUILD_LOGS_DIR\console-jenkins.log"
    }
    $remoteDirPath = Get-RemoteBuildDirectoryPath
    New-RemoteDirectory -RemoteDirectoryPath $remoteDirPath
    Copy-FilesToRemoteServer "$MESOS_BUILD_OUT_DIR\*" $remoteDirPath
    $buildOutputsUrl = Get-BuildOutputsUrl
    Add-Content -Path $ParametersFile -Value "BUILD_OUTPUTS_URL=$buildOutputsUrl"
    Write-Output "Build artifacts can be found at: $buildOutputsUrl"
    if($NewLatest) {
        $remoteSymlinkPath = Get-RemoteLatestSymlinkPath
        New-RemoteSymlink -RemotePath $remoteDirPath -RemoteSymlinkPath $remoteSymlinkPath
    }
}

function Start-EnvironmentCleanup {
    # Stop any potential hanging process
    $processes = @('python', 'git', 'cl', 'cmake',
                   'stdout-tests', 'libprocess-tests', 'mesos-tests')
    $processes | Foreach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
    cmd.exe /C "rmdir /s /q $MESOS_DIR > nul 2>&1"
}

function Get-SuccessBuildMessage {
    if($ReviewID) {
        return "Mesos patch $ReviewID was successfully built and tested."
    }
    return "Mesos nightly build and testing was successful."
}


try {
    # Recreate the parameters file at the beginning of the job
    if(Test-Path $ParametersFile) {
        Remove-Item -Force $ParametersFile
    }
    New-Item -ItemType File -Path $ParametersFile
    Install-Prerequisites
    New-Environment
    Start-MesosBuild
    Start-StdoutTestsBuild
    Start-StdoutTestsRun
    Start-LibprocessTestsBuild
    Start-LibprocessTestsRun
    Start-MesosTestsBuild
    Start-MesosTestsRun
    New-MesosBinaries
    $global:BUILD_STATUS = 'PASS'
    Add-Content $ParametersFile "STATUS=PASS"
    Add-Content $ParametersFile "MESSAGE=$(Get-SuccessBuildMessage)"
} catch {
    $errMsg = $_.ToString()
    Write-Output $errMsg
    if(!$global:BUILD_STATUS) {
        $global:BUILD_STATUS = 'FAIL'
    }
    if($global:LOGS_URLS) {
        $strLogsUrls = $global:LOGS_URLS -join '|'
        Add-Content -Path $ParametersFile -Value "LOGS_URLS=$strLogsUrls"
    }
    Add-Content -Path $ParametersFile -Value "STATUS=${global:BUILD_STATUS}"
    Add-Content -Path $ParametersFile -Value "MESSAGE=${errMsg}"
    exit 1
} finally {
    if($global:BUILD_STATUS -eq 'PASS') {
        Start-LogServerFilesUpload -NewLatest
    } else {
        Start-LogServerFilesUpload
    }
    Start-EnvironmentCleanup
}
exit 0
