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

# Set the hostname
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \ 
	'sudo hostnamectl hostname snaps.canonical.internal'

# Generate the CA
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'openssl req -new -x509 -extensions v3_ca -keyout cakey.pem -out cacert.pem -days 3650 -subj "/C=BR/ST=Sao_Paulo/L=Sao_Paulo/O=Canonical/CN=snaps.canonical.internal" -passin 'pass:passw0rd' -passout 'pass:passw0rd''

# Generate the CSR
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'openssl genrsa -out server.key 2048'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'openssl req -new -key server.key -out server.csr -subj "/C=BR/ST=Sao_Paulo/L=Sao_Paulo/O=Canonical/CN=snaps.canonical.internal"'

# Sign the certificate and generate SAN
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
'cat <<EOF > v3.ext
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer:always
basicConstraints       = CA:TRUE
keyUsage               = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment, keyAgreement, keyCertSign
subjectAltName         = DNS:snaps.canonical.internal, DNS:*.canonical.internal
issuerAltName          = issuer:copy
EOF'

ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'openssl x509 -req -days 365 -in server.csr -out server.crt -CA ./cacert.pem -CAkey ./cakey.pem -passin 'pass:passw0rd' -extfile v3.ext'

# Add CA certificate to trusted db
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip\
	'sudo cp cacert.pem /usr/local/share/ca-certificates/cacert.crt'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo update-ca-certificates'

# Install DB client
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo apt update -y && sudo apt install postgresql-client-common postgresql-client-14 -y'

# Create required DB extension
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
'cat <<EOF > proxydb.sql
CREATE EXTENSION "btree_gist";
EOF'

ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	"PGPASSWORD=$db_password psql -h $db_endpoint -U $db_user -d $db_name < proxydb.sql"

# Install and configure snap-store-proxy
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo snap install snap-store-proxy'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo snap-proxy config proxy.domain="snaps.canonical.internal"'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	"sudo snap-proxy config proxy.db.connection="postgresql://$db_user:$db_password@$db_endpoint:5432/$db_name""
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'snap-proxy check-connections'

# Register the snap-proxy store
read -p "Enter Snapstore Email: " snap_email 
read -p "Enter Snapstore Password: " snap_pass
read -p "Enter Snapstore 2FA: " snap_2fa

ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	"sudo SNAPSTORE_EMAIL=$snap_email SNAPSTORE_PASSWORD='$snap_pass' SNAPSTORE_OTP=$snap_2fa snap-proxy register --https  --skip-questions"
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'snap-proxy status'

# Configure Certificates
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'cat server.crt server.key | sudo snap-proxy import-certificate'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo snap restart snap-store-proxy'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'snap-proxy status'

# Copy certificates to S3 bucket so client can use
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo apt update'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo apt install awscli -y'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'aws s3 mb s3://snap-cli-cert'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'aws s3 cp cacert.pem s3://snap-cli-cert/cacert.crt'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'aws s3 cp server.crt s3://snap-cli-cert/server.crt'

# Create an override for validation purposes
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo snap-proxy override aws-cli stable=341'
ssh $ssh_flags -i $ssh_key $snapproxy_public_ip \
	'sudo snap-proxy override aws-cli v1/stable=341'

store_id=$(ssh $ssh_flags -i $ssh_key $snapproxy_public_ip "snap-proxy status | grep 'Store ID'")
echo "store_id=$(echo $store_id | awk '{print $3}')" | tee -a output.sh
