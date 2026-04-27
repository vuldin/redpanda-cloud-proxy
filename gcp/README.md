# gcp/ — TLS-enabled proxy on GCE

Reference deployment that runs Kroxylicious on a Compute Engine VM with a
Let's Encrypt cert. Adapt the IDs (project, region, instance name, hostname)
to your environment.

## Resources you'll provision

- A static external IP in your GCP project / region
- A small VM (e2-medium is plenty for a POC; size up for production)
- Firewall rules opening the proxy ports + 80 (for the LE HTTP-01 challenge)
  + 22 from your laptop's IP
- DNS A record `<your-proxy-hostname>` → static IP
- A Let's Encrypt cert for `<your-proxy-hostname>`

## Provision (sample gcloud commands)

```bash
PROJECT=<your-gcp-project>
ZONE=us-central1-a
REGION=us-central1
NAME=kroxy-poc
HOSTNAME=<your-proxy-hostname>
LAPTOP_IP=$(curl -s ifconfig.me)/32

gcloud config set project $PROJECT

# 1. Static IP
gcloud compute addresses create $NAME --region=$REGION --network-tier=PREMIUM
IP=$(gcloud compute addresses describe $NAME --region=$REGION --format='value(address)')
echo "Reserved $IP — add a DNS A record: $HOSTNAME -> $IP"

# 2. Firewall
gcloud compute firewall-rules create $NAME-kafka --network=default \
  --direction=INGRESS --action=ALLOW --rules=tcp:9192-9195 \
  --source-ranges=0.0.0.0/0 --target-tags=$NAME
gcloud compute firewall-rules create $NAME-http --network=default \
  --direction=INGRESS --action=ALLOW --rules=tcp:80 \
  --source-ranges=0.0.0.0/0 --target-tags=$NAME
gcloud compute firewall-rules create $NAME-ssh --network=default \
  --direction=INGRESS --action=ALLOW --rules=tcp:22 \
  --source-ranges=$LAPTOP_IP --target-tags=$NAME

# 3. VM with Docker preinstalled via startup script
gcloud compute instances create $NAME \
  --zone=$ZONE --machine-type=e2-medium \
  --image-family=debian-12 --image-project=debian-cloud \
  --address=$NAME --tags=$NAME \
  --metadata=startup-script='#!/bin/bash
set -e
apt-get update
apt-get install -y ca-certificates curl gnupg certbot
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
mkdir -p /opt/kroxy && chown $(id -u $USER):$(id -g $USER) /opt/kroxy 2>/dev/null || true
touch /var/log/startup-done
'
```

After the A record propagates (`dig +short $HOSTNAME @1.1.1.1` returns the
static IP), continue:

## Deploy the proxy

```bash
# 1. Edit kroxy-config.yaml: replace <upstream-bootstrap-host>
#    and <your-proxy-hostname>

# 2. Sync to the VM
gcloud compute scp --zone=$ZONE --recurse \
  kroxy-config.yaml docker-compose.yml issue-cert.sh renew-hook.sh \
  $NAME:/opt/kroxy/

# 3. Issue the LE cert
gcloud compute ssh $NAME --zone=$ZONE --command="
  cd /opt/kroxy && chmod +x *.sh && \
  DOMAIN=$HOSTNAME EMAIL=<your-le-email> ./issue-cert.sh
"

# 4. Start the proxy
gcloud compute ssh $NAME --zone=$ZONE --command="cd /opt/kroxy && docker compose up -d"
```

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
90-day expiry.

## Cleanup

```bash
gcloud compute instances delete $NAME --zone=$ZONE --quiet
gcloud compute addresses delete $NAME --region=$REGION --quiet
gcloud compute firewall-rules delete $NAME-kafka $NAME-http $NAME-ssh --quiet
```
