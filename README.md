# EC2 Crowdstrike Repair (EXPERIMENTAL, NEEDS TESTERS)

This Terraform configuration sets up an Auto Scaling Group (ASG) that runs a PowerShell script to repair unhealthy EC2 instances across all Availability Zones in the current AWS region.

## Features

- Launches instances across all available Availability Zones in an ASG, with a single instance per AZ.
- Each instance runs a custom PowerShell repair script, that iterates over all unhealthy instance form the current AZ:

1. detaches the root volume from the current unhealthy instance.
2. attaches it to the current instance.
3. attempts to delete the broken CrowdStrike update file.
4. detaches and re-attaches the volume to the initial instance.
5. restarts the initial instance.

## Prerequisites

- Terraform installed (version 0.12 or later)

## Usage

1. Clone this repository

2. Initialize the Terraform working directory:

   ```shell
   terraform init
   ```

3. Review the planned changes:

   ```shell
   terraform plan
   ```

4. Apply the Terraform configuration:

   ```shell
   terraform apply
   ```

5. Confirm the changes by typing `yes` when prompted.

## Customization

- To use a different Windows Server version, modify the `name` parameter in the `aws_ssm_parameter` data source.
- Adjust the `instance_type` in the launch template if you need more powerful instances.
- Modify the `min_size`, `max_size`, and `desired_capacity` in the ASG resource if you want a different scaling behavior.

## Clean Up

To remove all created resources:

```shell
terraform destroy
```

## Contributing

Feel free to submit issues or pull requests if you have suggestions for improvements or bug fixes.

## License

This code is (C) 2024 Cristian Magherusan-Stanciu, and released under the MIT license.

Check out more of our OSS repos at [LeanerCloud.com](https://github.com/LeanerCloud).
