param(
    [string]$Target = "sim_render",
    [string]$LogFile = ".\lfm_benchmark_log.txt",
    [string]$SummaryFile = ".\lfm_stage_summary.txt",
    [int]$RunSeconds = 30,
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
    "[$timestamp] benchmark_target=$Target use_nsys=$UseNsys run_seconds=$RunSeconds" | Tee-Object @teeParams

    # $IsWindows is not available in Windows PowerShell 5.1, so use a
    # version-agnostic platform check.
    $isWindowsPlatform = $env:OS -eq "Windows_NT"
    $targetExe = $null
    $targetName = if ($isWindowsPlatform) { "$Target.exe" } else { "$Target" }

    $directTarget = Join-Path ".\build" $targetName
    if (Test-Path $directTarget) {
        $targetExe = $directTarget
    }
    else {
        # xmake may place binaries under nested folders (e.g. build/windows/x64/...).
        $resolvedTarget = Get-ChildItem -Path ".\build" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq $targetName } |
            Select-Object -First 1
        if ($resolvedTarget) {
            $targetExe = $resolvedTarget.FullName
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $runExitCode = 0
    $runLines = New-Object System.Collections.Generic.List[string]
    $stageSamples = @{}
    $timedOut = $false
    $prevErrorActionPreference = $ErrorActionPreference
    try {
        # Capture native stderr/stdout as text lines.
        $ErrorActionPreference = "Continue"

        function Invoke-ProcessWithTimeout {
            param(
                [Parameter(Mandatory = $true)][string]$FilePath,
                [string[]]$ArgumentList = $null,
                [Parameter(Mandatory = $true)][string]$WorkingDirectory,
                [int]$TimeoutSeconds = 0,
                [string]$KillProcessName = ""
            )

            $stdoutFile = [System.IO.Path]::GetTempFileName()
            $stderrFile = [System.IO.Path]::GetTempFileName()
            try {
                $startParams = @{
                    FilePath               = $FilePath
                    WorkingDirectory       = $WorkingDirectory
                    PassThru               = $true
                    RedirectStandardOutput = $stdoutFile
                    RedirectStandardError  = $stderrFile
                }
                if ($ArgumentList -and $ArgumentList.Count -gt 0) {
                    $startParams.ArgumentList = $ArgumentList
                }

                $proc = Start-Process @startParams

                $didTimeout = $false
                if ($TimeoutSeconds -gt 0) {
                    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                        $didTimeout = $true

                        # For nsys profile runs, stop target app first so nsys can flush report.
                        if ($KillProcessName) {
                            Get-Process -Name $KillProcessName -ErrorAction SilentlyContinue |
                                Stop-Process -Force -ErrorAction SilentlyContinue
                            $null = $proc.WaitForExit(10000)
                        }

                        if (-not $proc.HasExited) {
                            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            $null = $proc.WaitForExit(5000)
                        }
                    }
                }
                else {
                    $proc.WaitForExit()
                }

                $stdout = if (Test-Path $stdoutFile) { Get-Content -Path $stdoutFile } else { @() }
                $stderr = if (Test-Path $stderrFile) { Get-Content -Path $stderrFile } else { @() }
                $combinedOutput = @($stdout + $stderr)

                $exitCode = if ($didTimeout) {
                    124
                }
                elseif ($proc.HasExited) {
                    $proc.ExitCode
                }
                else {
                    -1
                }

                return [PSCustomObject]@{
                    Output   = $combinedOutput
                    ExitCode = $exitCode
                    TimedOut = $didTimeout
                }
            }
            finally {
                Remove-Item -Path $stdoutFile -ErrorAction SilentlyContinue
                Remove-Item -Path $stderrFile -ErrorAction SilentlyContinue
            }
        }

        if ($UseNsys) {
            if (-not (Get-Command $NsysExe -ErrorAction SilentlyContinue)) {
                throw "Cannot find '$NsysExe'. Install Nsight Systems or pass -NsysExe with full path."
            }
            if (-not $targetExe) {
                throw "Missing executable '$targetName' under .\build. Build first: xmake build $Target"
            }

            $targetProcessName = [System.IO.Path]::GetFileNameWithoutExtension($targetName)
            $runResult = Invoke-ProcessWithTimeout `
                -FilePath $NsysExe `
                -ArgumentList @("profile", "-o", $NsysOutputBase, "--stats=true", $targetExe) `
                -WorkingDirectory $PSScriptRoot `
                -TimeoutSeconds $RunSeconds `
                -KillProcessName $targetProcessName

            $output = $runResult.Output
            $runExitCode = $runResult.ExitCode
            $timedOut = $runResult.TimedOut
        }
        else {
            if (-not $targetExe) {
                throw "Missing executable '$targetName' under .\build. Build first: xmake build $Target"
            }

            $runResult = Invoke-ProcessWithTimeout `
                -FilePath $targetExe `
                -WorkingDirectory $PSScriptRoot `
                -TimeoutSeconds $RunSeconds

            $output = $runResult.Output
            $runExitCode = $runResult.ExitCode
            $timedOut = $runResult.TimedOut
        }

        foreach ($line in $output) {
            $lineStr = if ($line -is [System.Management.Automation.ErrorRecord]) { $line.ToString() } else { "$line" }
            $runLines.Add($lineStr)

            # Parse profiler-like stage lines, e.g.:
            # [Profiler] Advection: 2.3 ms
            # Profiler Advection: 2.3ms
            if ($lineStr -match '(?i)(?:\[?\s*profiler\s*\]?\s*)?(?<stage>[^:]+):\s*(?<ms>\d+(?:\.\d+)?)\s*ms\b') {
                $stageName = $Matches['stage'].Trim()
                $msVal = [double]$Matches['ms']
                if (-not $stageSamples.ContainsKey($stageName)) {
                    $stageSamples[$stageName] = New-Object System.Collections.Generic.List[double]
                }
                $stageSamples[$stageName].Add($msVal)
            }
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
    "[$endTimestamp] timed_out=$timedOut" | Tee-Object -FilePath $LogFile -Append

    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add("benchmark_target=$Target")
    $summaryLines.Add("timestamp=$timestamp")
    $summaryLines.Add("elapsed_seconds=$($sw.Elapsed.TotalSeconds)")
    $summaryLines.Add("run_exit_code=$runExitCode")
    $summaryLines.Add("timed_out=$timedOut")
    $summaryLines.Add("")
    $summaryLines.Add("stage,count,avg_ms,min_ms,max_ms")

    $stageNames = @($stageSamples.Keys | Sort-Object)
    foreach ($stageName in $stageNames) {
        $samples = $stageSamples[$stageName]
        if ($samples.Count -eq 0) {
            continue
        }
        $avgMs = ($samples | Measure-Object -Average).Average
        $minMs = ($samples | Measure-Object -Minimum).Minimum
        $maxMs = ($samples | Measure-Object -Maximum).Maximum
        $summaryLines.Add(("{0},{1},{2:F6},{3:F6},{4:F6}" -f $stageName, $samples.Count, $avgMs, $minMs, $maxMs))
    }

    Set-Content -Path $SummaryFile -Value $summaryLines
    "[$endTimestamp] stage_summary=$SummaryFile" | Tee-Object -FilePath $LogFile -Append

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
