# Install and Import required AWS module
Import-Module AWSPowerShell

function Start-InitialDelay {
    param (
        [int]$DelayInSeconds = 180
    )
    Write-Output "Waiting for $DelayInSeconds seconds before starting the repair process..."
    Start-Sleep -Seconds $DelayInSeconds
}

function Wait-EC2Instance {
    param (
        [string]$InstanceId,
        [string]$TargetState
    )

    do {
        $instance = Get-EC2Instance -InstanceId $InstanceId
        $state = $instance.Instances[0].State.Name
        Write-Output "Instance $InstanceId is in state: $state"
        if ($state -eq $TargetState) {
            break
        }
        Start-Sleep -Seconds 10
    } while ($true)
}
function Wait-EC2Volume {
    param (
        [string]$VolumeId,
        [string]$TargetState
    )

    do {
        $volume = Get-EC2Volume -VolumeId $VolumeId
        $state = $volume.State
        Write-Output "Volume $VolumeId is in state: $state"
        if ($state -eq $TargetState) {
            break
        }
        Start-Sleep -Seconds 10
    } while ($true)
}

function Create-Snapshot($volumeId, $instanceId) {
    $snapshot = New-EC2Snapshot -VolumeId $volumeId -Description "Automated snapshot before repair"
    $snapshotId = $snapshot.SnapshotId
    Write-Output "Created snapshot $snapshotId for volume $volumeId"

    # Tag the snapshot
    New-EC2Tag -Resource $snapshotId -Tag @{Key = "OriginalInstanceId"; Value = $instanceId }

    # Tag the volume
    New-EC2Tag -Resource $volumeId -Tag @{Key = "OriginalInstanceId"; Value = $instanceId }

    return $snapshotId
}

function Wait-EC2Snapshot {
    param (
        [string]$SnapshotId,
        [string]$TargetState
    )

    Write-Output "Waiting for snapshot $SnapshotId to reach state $TargetState"
    do {
        $snapshot = Get-EC2Snapshot -SnapshotId $SnapshotId
        $state = $snapshot.State
        $progress = $snapshot.Progress
        Write-Output "Snapshot $SnapshotId is in state: $state, Progress: $progress"
        if ($state -eq $TargetState) {
            break
        }
        Start-Sleep -Seconds 10
    } while ($true)
}

function Stop-AndTerminateInstance {
    $currentInstanceId = Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/instance-id
    Write-Output "Shutting down and terminating the current instance ($currentInstanceId)..."
    Stop-Computer -Force
    Remove-EC2Instance -InstanceId $currentInstanceId -Force
}

function Get-CurrentInstanceAZ {
    $instanceId = Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/instance-id
    $instance = Get-EC2Instance -InstanceId $instanceId
    return $instance.Instances[0].Placement.AvailabilityZone
}

function Get-UnhealthyInstances($az) {
    $instances = Get-EC2Instance | Where-Object { $_.Instances[0].Placement.AvailabilityZone -eq $az }
    return $instances | Where-Object {
        $instanceId = $_.Instances[0].InstanceId
          (Get-EC2InstanceStatus -InstanceId $instanceId).Status.Status -ne "ok"
        # for testing use the ID of the test instance
        # $instanceId -eq "i-123456f890"
    }
}

function Stop-AndWaitInstance($instanceId) {
    Stop-EC2Instance -InstanceId $instanceId -Force
    Write-Output "Stopping instance $instanceId..."
    Wait-EC2Instance -InstanceId $instanceId -TargetState 'Stopped'
}

function Get-RootVolumeId($instanceId) {
    return (Get-EC2Instance -InstanceId $instanceId).Instances[0].BlockDeviceMappings |
    Where-Object { $_.DeviceName -eq '/dev/sda1' } |
    Select-Object -ExpandProperty Ebs |
    Select-Object -ExpandProperty VolumeId
}

function Detach-AndWaitVolume($instanceId, $volumeId) {
    Dismount-EC2Volume -InstanceId $instanceId -VolumeId $volumeId -Force
    Write-Output "Detaching volume $volumeId from instance $instanceId..."
    Wait-EC2Volume -VolumeId $volumeId -TargetState 'available'
}



function Attach-AndWaitVolume($instanceId, $volumeId, $device) {
    Add-EC2Volume -InstanceId $instanceId -VolumeId $volumeId -Device $device
    Write-Output "Attaching volume $volumeId to instance $instanceId as $device..."
    Wait-EC2Volume -VolumeId $volumeId -TargetState 'in-use'
}

function Mount-VolumeAsD {
    $driveLetter = 'D'
    $volume = Get-Volume | Where-Object { $_.DriveLetter -eq $null -and $_.FileSystemLabel -eq $null }
    if ($volume) {
        $partition = $volume | Get-Partition
        $partition | Set-Partition -NewDriveLetter $driveLetter
        Write-Output "Volume mounted as ${driveLetter}:"
    }
    else {
        Write-Error "No suitable volume found to mount as ${driveLetter}:"
    }
}

function Remove-CrowdStrikeFile {
    $filePath = "D:\Windows\System32\drivers\CrowdStrike\C-00000291*.sys"
    if (Test-Path $filePath) {
        Remove-Item -Path $filePath -Force
        Write-Output "CrowdStrike file removed."
    }
    else {
        Write-Output "CrowdStrike file not found."
    }
}

function Unmount-Volume($driveLetter) {
    $volume = Get-Volume -DriveLetter $driveLetter
    if ($volume) {
        $partition = $volume | Get-Partition
        $partition | Remove-PartitionAccessPath -AccessPath "${driveLetter}:"
        Write-Output "Volume ${driveLetter}: unmounted."
    }
    else {
        Write-Error "Volume ${driveLetter}: not found."
    }
}

function Start-AndWaitInstance($instanceId) {
    Start-EC2Instance -InstanceId $instanceId
    Write-Output "Starting instance $instanceId..."
    Wait-EC2Instance -InstanceId $instanceId -TargetState 'Running'
}


function Repair-UnhealthyInstance($instance) {
    $instanceId = $instance.Instances[0].InstanceId
    Write-Output "Repairing unhealthy instance: $instanceId"

    $instanceState = (Get-EC2Instance -InstanceId $instanceId).Instances[0].State.Name
    if ($instanceState -ne 'running') {
        Write-Output "Instance $instanceId is not running. Current state: $instanceState"
        return
    }

    Stop-AndWaitInstance $instanceId

    $rootVolumeId = Get-RootVolumeId $instanceId
    if (-not $rootVolumeId) {
        Write-Output "Failed to get root volume ID for instance $instanceId"
        return
    }

    Detach-AndWaitVolume $instanceId $rootVolumeId

    $snapshotId = Create-Snapshot $rootVolumeId $instanceId
    # We're skipping the Wait-EC2Snapshot call here

    $currentInstanceId = Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/instance-id
    Attach-AndWaitVolume $currentInstanceId $rootVolumeId 'xvdf'

    # Add a delay before mounting
    Start-Sleep -Seconds 10

    Mount-VolumeAsD
    Remove-CrowdStrikeFile
    Unmount-Volume 'D'

    # Add a delay before detaching
    Start-Sleep -Seconds 10

    Detach-AndWaitVolume $currentInstanceId $rootVolumeId

    Attach-AndWaitVolume $instanceId $rootVolumeId '/dev/sda1'

    Start-AndWaitInstance $instanceId

    Write-Output "Repair completed for instance: $instanceId"
    Write-Output "Snapshot created: $snapshotId"
}

# Main execution
Start-InitialDelay

$currentAZ = Get-CurrentInstanceAZ
$unhealthyInstances = Get-UnhealthyInstances $currentAZ

foreach ($instance in $unhealthyInstances) {
    Repair-UnhealthyInstance $instance
}

Write-Output "Script execution completed."

# Stop-AndTerminateInstance
