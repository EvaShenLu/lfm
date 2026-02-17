param(
    [string]$Target = "sim_render",
    [string]$LogFile = ".\lfm_benchmark_log.txt",
    [switch]$Append,
    [switch]$UseNsys,
    [string]$NsysExe = "nsys",
    [string]$NsysOutputBase = ".\lfm_profile"
)

$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {
    if ($Append) {
        $teeParams = @{ FilePath = $LogFile; Append = $true }
    }
    else {
        $teeParams = @{ FilePath = $LogFile }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] benchmark_target=$Target use_nsys=$UseNsys" | Tee-Object @teeParams

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $runExitCode = 0
    $runLines = New-Object System.Collections.Generic.List[string]
    $prevErrorActionPreference = $ErrorActionPreference
    try {
        # Capture native stderr/stdout as text lines.
        $ErrorActionPreference = "Continue"

        if ($UseNsys) {
            if (-not (Get-Command $NsysExe -ErrorAction SilentlyContinue)) {
                throw "Cannot find '$NsysExe'. Install Nsight Systems or pass -NsysExe with full path."
            }
            if (-not (Test-Path ".\build\sim_render.exe")) {
                throw "Missing .\build\sim_render.exe. Build first: xmake build"
            }

            $output = & $NsysExe profile -o $NsysOutputBase --stats=true .\build\sim_render.exe 2>&1
            $runExitCode = $LASTEXITCODE
        }
        else {
            $output = xmake run $Target 2>&1
            $runExitCode = $LASTEXITCODE
        }

        foreach ($line in $output) {
            $lineStr = if ($line -is [System.Management.Automation.ErrorRecord]) { $line.ToString() } else { "$line" }
            $runLines.Add($lineStr)
        }

        $output | Tee-Object -FilePath $LogFile -Append
    }
    finally {
        $ErrorActionPreference = $prevErrorActionPreference
        $sw.Stop()
    }

    $endTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$endTimestamp] elapsed_seconds=$($sw.Elapsed.TotalSeconds)" | Tee-Object -FilePath $LogFile -Append
    "[$endTimestamp] run_exit_code=$runExitCode" | Tee-Object -FilePath $LogFile -Append

    if ($UseNsys) {
        $nsysRep = "$NsysOutputBase.nsys-rep"
        $nsysTxt = "$NsysOutputBase.txt"
        if (Test-Path $nsysRep) {
            "[$endTimestamp] nsys_report=$nsysRep" | Tee-Object -FilePath $LogFile -Append
        }
        if (Test-Path $nsysTxt) {
            "[$endTimestamp] nsys_stats=$nsysTxt" | Tee-Object -FilePath $LogFile -Append
        }
    }

    if ($runExitCode -ne 0) {
        exit $runExitCode
    }
}
finally {
    Pop-Location
}
