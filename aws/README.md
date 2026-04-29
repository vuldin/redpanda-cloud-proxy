# aws/ — TLS-enabled proxy on EC2

Reference deployment that runs Kroxylicious on an EC2 instance with a Let's
Encrypt cert, an Elastic IP, and **no SSH port exposed** (administration
goes through AWS Systems Manager Session Manager). Adapt the IDs (region,
hostname, etc.) to your environment.

## Resources you'll provision

- An Elastic IP (EIP) in your AWS region
- A small VPC + public subnet (sandbox accounts often lack a default VPC; if
  you have one, skip the VPC step and reuse the default subnet)
- A security group: tcp 9192–9195 (Kafka via proxy) + tcp 80 (LE HTTP-01).
  **No port 22** — Session Manager handles SSH/SCP via an SSM tunnel.
- An IAM role + instance profile with `AmazonSSMManagedInstanceCore`
- A t3.medium Debian 12 instance with the EIP attached
- DNS A record `<your-proxy-hostname>` → EIP (Route 53 or your DNS provider)
- A Let's Encrypt cert for `<your-proxy-hostname>`

## Prerequisites on your laptop

- `aws` CLI authenticated (the rest of this doc assumes a profile named
  `<your-profile>` with EC2/IAM/SSM permissions in the chosen region)
- `session-manager-plugin` for SSM tunneling — see
  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
- `rpk` for the end-to-end test

## Provision (sample aws CLI commands)

```bash
PROFILE=<your-profile>
REGION=us-east-1
NAME=kroxy-poc
HOSTNAME=<your-proxy-hostname>

# 1. EIP — capture the address before doing anything else; flip your DNS A
#    record now so propagation overlaps with provisioning.
EIP_ALLOC_ID=$(aws --profile $PROFILE --region $REGION ec2 allocate-address \
  --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME}]" \
  --query 'AllocationId' --output text)
EIP=$(aws --profile $PROFILE --region $REGION ec2 describe-addresses \
  --allocation-ids $EIP_ALLOC_ID --query 'Addresses[0].PublicIp' --output text)
echo "Reserved $EIP — point $HOSTNAME at it now (see DNS section below)."

# 2. VPC + public subnet (skip if you already have one — substitute your VPC/subnet IDs)
VPC_ID=$(aws --profile $PROFILE --region $REGION ec2 create-vpc \
  --cidr-block 10.99.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$NAME-vpc}]" \
  --query 'Vpc.VpcId' --output text)
aws --profile $PROFILE --region $REGION ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws --profile $PROFILE --region $REGION ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
IGW_ID=$(aws --profile $PROFILE --region $REGION ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws --profile $PROFILE --region $REGION ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
SUBNET_ID=$(aws --profile $PROFILE --region $REGION ec2 create-subnet \
  --vpc-id $VPC_ID --cidr-block 10.99.1.0/24 --availability-zone ${REGION}a \
  --query 'Subnet.SubnetId' --output text)
aws --profile $PROFILE --region $REGION ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch
RT_ID=$(aws --profile $PROFILE --region $REGION ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws --profile $PROFILE --region $REGION ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws --profile $PROFILE --region $REGION ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_ID

# 3. Security group — no port 22; SSM provides the management plane
SG_ID=$(aws --profile $PROFILE --region $REGION ec2 create-security-group \
  --group-name $NAME --description "Kroxylicious proxy POC" --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
aws --profile $PROFILE --region $REGION ec2 authorize-security-group-ingress --group-id $SG_ID \
  --ip-permissions IpProtocol=tcp,FromPort=9192,ToPort=9195,IpRanges='[{CidrIp=0.0.0.0/0,Description="Kafka via Kroxylicious"}]'
aws --profile $PROFILE --region $REGION ec2 authorize-security-group-ingress --group-id $SG_ID \
  --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0,Description="LE HTTP-01"}]'

# 4. IAM role + instance profile for SSM
ROLE=$NAME-ssm
cat > /tmp/trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws --profile $PROFILE iam create-role --role-name $ROLE --assume-role-policy-document file:///tmp/trust.json
aws --profile $PROFILE iam attach-role-policy --role-name $ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws --profile $PROFILE iam create-instance-profile --instance-profile-name $ROLE
aws --profile $PROFILE iam add-role-to-instance-profile --instance-profile-name $ROLE --role-name $ROLE

# 5. Key pair (used to authenticate the SSH session inside the SSM tunnel)
aws --profile $PROFILE --region $REGION ec2 create-key-pair --key-name $NAME --key-type ed25519 \
  --query 'KeyMaterial' --output text > ~/.ssh/$NAME.pem
chmod 600 ~/.ssh/$NAME.pem

# 6. Latest Debian 12 AMI from Debian's official AWS account
AMI=$(aws --profile $PROFILE --region $REGION ec2 describe-images --owners 136693071363 \
  --filters "Name=name,Values=debian-12-amd64-*" "Name=architecture,Values=x86_64" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
```

Save the user-data script as `user-data.sh` (Docker + certbot dependencies +
SSM agent — Debian cloud images don't ship the agent preinstalled):

```bash
cat > user-data.sh <<'EOF'
#!/bin/bash
set -e
exec > >(tee /var/log/user-data.log) 2>&1

apt-get update
apt-get install -y ca-certificates curl gnupg

# Docker (official apt repo)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# certbot via pip (Debian 12's apt certbot 2.1.0 has a known
# AttributeError bug with josepy on Python 3.11; pip-installed certbot is fine).
apt-get install -y python3-venv libaugeas0
python3 -m venv /opt/certbot/
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot
ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot

# AWS SSM agent
mkdir -p /tmp/ssm && cd /tmp/ssm
curl -fsSL -O https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb
systemctl enable --now amazon-ssm-agent

mkdir -p /opt/kroxy && chown admin:admin /opt/kroxy
usermod -aG docker admin

touch /var/log/startup-done
EOF
```

Then launch and attach the EIP:

```bash
INSTANCE_ID=$(aws --profile $PROFILE --region $REGION ec2 run-instances \
  --image-id $AMI --instance-type t3.medium \
  --key-name $NAME --subnet-id $SUBNET_ID --security-group-ids $SG_ID \
  --iam-instance-profile Name=$ROLE \
  --user-data file://user-data.sh \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --query 'Instances[0].InstanceId' --output text)

aws --profile $PROFILE --region $REGION ec2 wait instance-running --instance-ids $INSTANCE_ID
aws --profile $PROFILE --region $REGION ec2 associate-address \
  --instance-id $INSTANCE_ID --allocation-id $EIP_ALLOC_ID
echo "Instance $INSTANCE_ID running on $EIP"
```

Wait until SSM picks the instance up (typically 1–3 min after `instance-running`):

```bash
aws --profile $PROFILE --region $REGION ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[*].PingStatus' --output text
# expect: Online
```

## DNS

### Route 53 (recommended on AWS)

If `<your-proxy-hostname>` is in a Route 53 hosted zone, do the A record via
the AWS CLI — same plane, same audit trail:

```bash
ZONE_ID=$(aws --profile $PROFILE route53 list-hosted-zones-by-name \
  --dns-name <your-zone-apex>. --query 'HostedZones[0].Id' --output text)

cat > /tmp/rrset.json <<EOF
{
  "Comment": "Point $HOSTNAME at kroxy proxy",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$HOSTNAME.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "$EIP"}]
    }
  }]
}
EOF

aws --profile $PROFILE route53 change-resource-record-sets \
  --hosted-zone-id $ZONE_ID --change-batch file:///tmp/rrset.json
```

### Other DNS providers

If your zone lives elsewhere (Cloudflare, Vercel, your registrar, etc.), use
that provider's CLI/console to UPSERT the A record. Verify with
`dig +short $HOSTNAME @1.1.1.1` before issuing the cert.

## Deploy the proxy

The instructions below use **SSM Session Manager** to tunnel SSH and SCP, so
no port 22 is open in the security group. Add this once to `~/.ssh/config`:

```
Host i-* mi-*
    ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p' --profile <your-profile> --region us-east-1"
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

Then SCP and SSH "just work" against the instance ID:

```bash
# 1. Edit kroxy-config.yaml: replace <upstream-bootstrap-host> and <your-proxy-hostname>

# 2. Sync to the VM (admin is the default user on Debian 12 AMIs)
scp -i ~/.ssh/$NAME.pem -o IdentitiesOnly=yes \
  kroxy-config.yaml docker-compose.yml issue-cert.sh renew-hook.sh \
  admin@$INSTANCE_ID:/opt/kroxy/

# 3. Issue the LE cert
ssh -i ~/.ssh/$NAME.pem -o IdentitiesOnly=yes admin@$INSTANCE_ID \
  "cd /opt/kroxy && DOMAIN=$HOSTNAME EMAIL=<your-le-email> ./issue-cert.sh"

# 4. Start the proxy
ssh -i ~/.ssh/$NAME.pem -o IdentitiesOnly=yes admin@$INSTANCE_ID \
  "cd /opt/kroxy && sudo docker compose up -d"
```

The key pair is still required (it authenticates SSH inside the SSM tunnel),
but **the security group never opens port 22** — that's the hardening win
versus a public-key-on-port-22 setup.

## Test from your laptop

```bash
cp .env.example .env
# Fill in RPK_USER, RPK_PASS, PROXY_HOST=<your-proxy-hostname>
./test-tls.sh
```

You should see the metadata response list brokers as
`<your-proxy-hostname>:9193`, `:9194`, `:9195` — the rewrite confirms the
proxy is working. Produce + consume should round-trip.

## Renewal

`renew-hook.sh` is intended for `certbot renew --deploy-hook`. For a POC,
re-run `issue-cert.sh` and `docker compose restart` manually before the
90-day expiry. Port 80 must be reachable during renewal — close it again
afterwards if you want to minimize the public footprint.

## Cleanup

```bash
aws --profile $PROFILE --region $REGION ec2 terminate-instances --instance-ids $INSTANCE_ID
aws --profile $PROFILE --region $REGION ec2 wait instance-terminated --instance-ids $INSTANCE_ID
aws --profile $PROFILE --region $REGION ec2 release-address --allocation-id $EIP_ALLOC_ID
aws --profile $PROFILE --region $REGION ec2 delete-security-group --group-id $SG_ID
aws --profile $PROFILE --region $REGION ec2 delete-subnet --subnet-id $SUBNET_ID
aws --profile $PROFILE --region $REGION ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws --profile $PROFILE --region $REGION ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
aws --profile $PROFILE --region $REGION ec2 delete-route-table --route-table-id $RT_ID
aws --profile $PROFILE --region $REGION ec2 delete-vpc --vpc-id $VPC_ID
aws --profile $PROFILE --region $REGION ec2 delete-key-pair --key-name $NAME

aws --profile $PROFILE iam remove-role-from-instance-profile --instance-profile-name $ROLE --role-name $ROLE
aws --profile $PROFILE iam delete-instance-profile --instance-profile-name $ROLE
aws --profile $PROFILE iam detach-role-policy --role-name $ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws --profile $PROFILE iam delete-role --role-name $ROLE
```
