# Import required AWS module
Import-Module AWSPowerShell

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
    Wait-EC2Volume -VolumeId $volumeId -TargetState 'Available'
}

function Create-Snapshot($volumeId) {
    $snapshotId = New-EC2Snapshot -VolumeId $volumeId -Description "Automated snapshot before repair"
    Write-Output "Creating snapshot $snapshotId for volume $volumeId..."
    Wait-EC2Snapshot -SnapshotId $snapshotId -TargetState 'Completed'
    return $snapshotId
}

function Attach-AndWaitVolume($instanceId, $volumeId, $device) {
    Add-EC2Volume -InstanceId $instanceId -VolumeId $volumeId -Device $device
    Write-Output "Attaching volume $volumeId to instance $instanceId as $device..."
    Wait-EC2Volume -VolumeId $volumeId -TargetState 'InUse'
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

    Stop-AndWaitInstance $instanceId

    $rootVolumeId = Get-RootVolumeId $instanceId
    Detach-AndWaitVolume $instanceId $rootVolumeId

    $snapshotId = Create-Snapshot $rootVolumeId

    $currentInstanceId = Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/instance-id
    Attach-AndWaitVolume $currentInstanceId $rootVolumeId 'xvdf'

    Mount-VolumeAsD
    Remove-CrowdStrikeFile
    Unmount-Volume 'D'

    Detach-AndWaitVolume $currentInstanceId $rootVolumeId

    Attach-AndWaitVolume $instanceId $rootVolumeId '/dev/sda1'

    Start-AndWaitInstance $instanceId

    Write-Output "Repair completed for instance: $instanceId"
    Write-Output "Snapshot created: $snapshotId"
}

# Main execution
$currentAZ = Get-CurrentInstanceAZ
$unhealthyInstances = Get-UnhealthyInstances $currentAZ

foreach ($instance in $unhealthyInstances) {
    Repair-UnhealthyInstance $instance
}

Write-Output "Script execution completed."