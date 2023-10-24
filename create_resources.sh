#!/bin/bash

set -x

# Get variables from config.sh
source config.sh

ssh_flags=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null "

wait_for_ssh() {
    # $1 is ipaddr
    local max_ssh_attempts=10
    local ssh_attempt_sleep_time=10
    local ipaddr=$1

    # Start with a sleep so that it waits a bit in case of a reboot
    sleep $ssh_attempt_sleep_time

    # Loop until SSH is successful or max_attempts is reached
    for ((i = 1; i <= $max_ssh_attempts; i++)); do
        ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} exit
        if [ $? -eq 0 ]; then
            echo "SSH connection successful."
            break
        else
            echo "Attempt $i: SSH connection failed. Retrying in $ssh_attempt_sleep_time seconds..."
            sleep $ssh_attempt_sleep_time
        fi
    done

    if [ $i -gt $max_ssh_attempts ]; then
        echo "Max SSH connection attempts reached. Exiting."
    fi
}

# Create RDS Database
db_instance=$(echo $db_instance_prefix-`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1`)
aws rds create-db-instance --db-name $db_name --db-instance-identifier $db_instance --allocated-storage $db_size --db-instance-class $db_class --engine postgres --master-username $db_user --master-user-password $db_password --vpc-security-group-ids $security_group --region $region --no-cli-pager
aws rds wait db-instance-available --db-instance-identifier $db_instance --region $region
db_endpoint=$(aws rds describe-db-instances --db-instance-identifier $db_instance --query 'DBInstances[*].Endpoint.Address' --output text)

# Create snap-proxy instance
cat <<EOF > block.json
[
	{
                    "DeviceName": "/dev/sda1",
                    "Ebs": {
                        "DeleteOnTermination": true,
                        "VolumeSize": 100,
                        "VolumeType": "gp3",
                        "Encrypted": false
                    }
	}
]
EOF

snapproxy_instance=$(aws ec2 run-instances --image-id $ami --instance-type $instance_type --key-name $keypair --security-group-id $security_group --subnet-id $subnet --block-device-mappings file://./block.json --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=snap-proxy-rds-https}]' 'ResourceType=volume,Tags=[{Key=Name,Value=snap-proxy-rds-httpsvol}]' --region $region --query 'Instances[0].InstanceId' --output text)

# Create snap-client instance
snapcli_instance=$(aws ec2 run-instances --image-id $ami --instance-type $instance_type --key-name $keypair --security-group-id $security_group --subnet-id $subnet --block-device-mappings file://./block.json --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=snap-proxy-rds-https-cli}]' 'ResourceType=volume,Tags=[{Key=Name,Value=snap-proxy-rds-cli-httpsvol}]' --region $region --query 'Instances[0].InstanceId' --output text)

# Get the relevant IP Addresses
snapproxyip=$(aws ec2 describe-instances  --query "Reservations[*].Instances[*].[PrivateIpAddress]" --region $region --filters Name=instance-id,Values=$snapproxy_instance --output text)
snapproxy_public_ip=$(aws ec2 describe-instances --instance-ids $snapproxy_instance --region $region --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
snapclient_public_ip=$(aws ec2 describe-instances --instance-ids $snapcli_instance --region $region --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Update /etc/hosts in the instances
wait_for_ssh $snapproxy_public_ip
wait_for_ssh $snapclient_public_ip

ssh $ssh_flags -i $ssh_key $snapproxy_public_ip "echo '$snapproxyip   snaps.canonical.internal' | sudo tee -a /etc/hosts"
ssh $ssh_flags -i $ssh_key $snapclient_public_ip "echo '$snapproxyip   snaps.canonical.internal' | sudo tee -a /etc/hosts"

# Prepare S3 instance profiles
cat <<EOF > Role-Trust-Policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRole"
            ],
            "Principal": {
                "Service": [
                    "ec2.amazonaws.com"
                ]
            }
        }
    ]
}
EOF

# Prepare instance profile for the snap-proxy
aws iam create-role --role-name S3-Role-RW --assume-role-policy-document file://Role-Trust-Policy.json
aws iam wait role-exists --role-name S3-Role-RW --region=sa-east-1
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --role-name S3-Role-RW
aws iam create-instance-profile --instance-profile-name snap-proxy
aws iam wait instance-profile-exists --instance-profile-name snap-proxy --region=sa-east-1
aws iam add-role-to-instance-profile --role-name S3-Role-RW --instance-profile-name snap-proxy

# Prepare instance profile for the snap-client
aws iam create-role --role-name S3-Role-RO --assume-role-policy-document file://Role-Trust-Policy.json
aws iam wait role-exists --role-name S3-Role-RO --region=sa-east-1
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess --role-name S3-Role-RO
aws iam create-instance-profile --instance-profile-name snap-client
aws iam wait instance-profile-exists --instance-profile-name snap-client --region=sa-east-1
aws iam add-role-to-instance-profile --role-name S3-Role-RO --instance-profile-name snap-client

# Associate profiles to the instances
aws ec2  associate-iam-instance-profile --iam-instance-profile Name=snap-proxy --instance-id $snapproxy_instance --region $region
aws ec2  associate-iam-instance-profile --iam-instance-profile Name=snap-client --instance-id $snapcli_instance --region $region

# Generate output file
cat <<EOF > output.sh
db_instance=$db_instance
db_endpoint=$db_endpoint
snapproxy_instance=$snapproxy_instance
snapcli_instance=$snapcli_instance
snapproxyip=$snapproxyip
snapproxy_public_ip=$snapproxy_public_ip
snapclient_public_ip=$snapclient_public_ip
EOF
