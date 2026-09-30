<#
.SYNOPSIS
    Watches a Windows service and, when it comes up or restarts, restarts a list
    of other services in a set order.

.DESCRIPTION
    Polls the watched service (local or remote). The workflow fires when either:
      - the service goes from any non-Running state (Stopped, Start Pending,
        server unreachable/rebooting) to Running, or
      - the service is Running both times but its process ID changed, which
        means a fast restart happened between polls.
    Before acting, it waits a settle period and re-checks that the service is
    still up. Dependent services are then restarted one at a time. Each must
    reach Running before the next starts. The chain stops at the first failure.
    A cooldown keeps the workflow from re-firing in a loop.

.EXAMPLE
    .\Watch-ServiceRestart.ps1 -WatchService "MSSQLSERVER" `
        -RestartServices "AppPoolSvc","JobScheduler","ApiGateway" `
        -ComputerName SQL01 -TargetComputer APP01

.NOTES
    Remote servers need WinRM (CIM + Invoke-Command). The account running this
    needs rights to query the watched server and control services on the target
    (a gMSA is a good fit).
    Services hosted in a shared svchost may keep the same PID across restarts.
    For those, only the stop -> start transition is detected.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $WatchService,
    [Parameter(Mandatory)] [string[]] $RestartServices,      # restarted in this order
    [string] $ComputerName        = $env:COMPUTERNAME,       # where the watched service lives
    [string] $TargetComputer      = $env:COMPUTERNAME,       # where the services to restart live
    [int]    $PollSeconds         = 15,
    [int]    $SettleSeconds       = 30,                      # let the watched service finish initializing
    [int]    $CooldownMinutes     = 10,                      # min gap between workflow runs
    [int]    $StartTimeoutSeconds = 120,                     # per-service wait for Running
    [switch] $TriggerIfRunningAtStart,                       # fire once if already up when the watcher starts (post-reboot use)
    [string] $LogPath             = "C:\ProgramData\ServiceWatcher\watcher.log"
)

$localNames = @($env:COMPUTERNAME, 'localhost', '.')

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Get-WatchState {
    $cimArgs = @{
        ClassName   = 'Win32_Service'
        Filter      = "Name='$WatchService'"
        ErrorAction = 'Stop'
    }
    if ($ComputerName -notin $localNames) { $cimArgs.ComputerName = $ComputerName }
    try {
        $svc = Get-CimInstance @cimArgs
        if (-not $svc) { return [pscustomobject]@{ State = 'NotFound'; ProcessId = 0 } }
        [pscustomobject]@{ State = $svc.State; ProcessId = [int]$svc.ProcessId }
    }
    catch {
        [pscustomobject]@{ State = 'Unreachable'; ProcessId = 0 }
    }
}

# Runs on the target machine: restart (or start) one service and wait for Running.
$restartOne = {
    param([string]$Name, [int]$TimeoutSec)
    $svc = Get-Service -Name $Name -ErrorAction Stop
    if ($svc.Status -eq 'Running') { Restart-Service -Name $Name -Force -ErrorAction Stop }
    else                           { Start-Service   -Name $Name -ErrorAction Stop }
    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($TimeoutSec))
}

function Invoke-OnTarget {
    param([scriptblock]$Block, [object[]]$ArgumentList)
    if ($TargetComputer -in $localNames) {
        & $Block @ArgumentList
    }
    else {
        Invoke-Command -ComputerName $TargetComputer -ScriptBlock $Block `
                       -ArgumentList $ArgumentList -ErrorAction Stop
    }
}

function Invoke-Workflow {
    param([string]$Reason)
    Write-Log "'$WatchService' $Reason. Waiting $SettleSeconds s before acting."
    Start-Sleep -Seconds $SettleSeconds

    $check = Get-WatchState
    if ($check.State -ne 'Running') {
        Write-Log "'$WatchService' is no longer running ($($check.State)). Workflow aborted." 'WARN'
        return $false
    }

    foreach ($name in $RestartServices) {
        try {
            Write-Log "Restarting '$name' on $TargetComputer..."
            Invoke-OnTarget -Block $restartOne -ArgumentList @($name, $StartTimeoutSeconds)
            Write-Log "'$name' is Running."
        }
        catch {
            Write-Log "Failed on '$name': $($_.Exception.Message). Stopping the chain." 'ERROR'
            return $false
        }
    }
    Write-Log "Workflow complete."
    return $true
}

# ---- main ----
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

Write-Log "Watching '$WatchService' on $ComputerName every $PollSeconds s. On restart: $($RestartServices -join ' -> ') on $TargetComputer."
$prev      = Get-WatchState
$lastFired = [datetime]::MinValue
Write-Log "Initial state: $($prev.State) (PID $($prev.ProcessId))"

if ($TriggerIfRunningAtStart -and $prev.State -eq 'Running') {
    if (Invoke-Workflow -Reason 'was running when the watcher started') { $lastFired = Get-Date }
    $prev = Get-WatchState
}

while ($true) {
    Start-Sleep -Seconds $PollSeconds
    $cur    = Get-WatchState
    $reason = $null

    if ($cur.State -eq 'Running' -and $prev.State -ne 'Running') {
        $reason = "came up (was $($prev.State))"
    }
    elseif ($cur.State -eq 'Running' -and $prev.ProcessId -ne 0 -and $cur.ProcessId -ne $prev.ProcessId) {
        $reason = "restarted (PID $($prev.ProcessId) -> $($cur.ProcessId))"
    }
    elseif ($cur.State -ne $prev.State) {
        Write-Log "'$WatchService' state: $($prev.State) -> $($cur.State)" 'WARN'
    }

    if ($reason) {
        if (((Get-Date) - $lastFired).TotalMinutes -lt $CooldownMinutes) {
            Write-Log "'$WatchService' $reason, but still inside the $CooldownMinutes-minute cooldown. Skipping." 'WARN'
        }
        elseif (Invoke-Workflow -Reason $reason) {
            $lastFired = Get-Date
        }
        # Re-read so changes caused by the workflow itself don't re-trigger it.
        $cur = Get-WatchState
    }

    $prev = $cur
}
