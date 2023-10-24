#!/bin/bash

set -x

# Get variables from config.sh and output.sh
source output.sh
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

# Install awscli to download the certificates
ssh $ssh_flags -i $ssh_key $snapclient_public_ip \
	'sudo apt update -y && sudo apt install awscli -y'

# Get the certificate file
ssh $ssh_flags -i $ssh_key $snapclient_public_ip \
	'aws s3 cp s3://snap-cli-cert/cacert.crt cacert.crt'

# Import the CA certificate
ssh $ssh_flags -i $ssh_key $snapclient_public_ip \
	'sudo cp cacert.crt /usr/local/share/ca-certificates/cacert.crt'
ssh $ssh_flags -i $ssh_key $snapclient_public_ip \
	'sudo update-ca-certificates'

# Restart snapd to read certificate
ssh $ssh_flags -i $ssh_key $snapclient_public_ip \
	'sudo systemctl restart snapd'

# Configre the client
ssh $ssh_flags -i $ssh_key $snapclient_public_ip \
	'curl -sL https://snaps.canonical.internal/v2/auth/store/assertions | sudo snap ack /dev/stdin'
ssh $ssh_flags -i $ssh_key $snapclient_public_ip \
	"sudo snap set core proxy.store=$store_id"
ssh $ssh_flags -i $ssh_key $snapclient_public_ip \
	'sudo snap info aws-cli'
