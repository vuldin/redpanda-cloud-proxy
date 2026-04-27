# Redpanda Cloud proxy

A reference deployment that puts [Kroxylicious](https://kroxylicious.io/) in
front of a Redpanda Cloud cluster so that Kafka clients see a single proxy
hostname (and a single static IP) instead of per-broker hostnames. Useful when
the client environment can only allowlist by static IP and DNS-based egress
controls aren't available.

## Why a Kafka-aware proxy

A pure TCP passthrough is **not** sufficient for Redpanda Cloud. Advertised
listeners are per-broker DNS names. After the bootstrap connection, Kafka
clients resolve those names via public DNS and would attempt to connect to
broker IPs the proxy doesn't own. Kroxylicious rewrites the metadata response
so clients only ever see addresses owned by the proxy.

## What's in this repo

```
.
├── README.md             you are here
├── .env.example          template for SASL creds + proxy host
├── docker-compose.yml    runs Kroxylicious 0.15.0 in Docker
├── kroxy-config.yaml     virtualCluster + portIdentifiesNode (downstream plaintext)
├── test.sh               rpk metadata + produce/consume against the local proxy
└── gcp/                  reference deployment to GCE with TLS + Let's Encrypt
```

The root files run a plaintext proxy on `localhost`. The `gcp/` folder
extends that to a publicly reachable proxy on a static IP with a real LE cert.

## Local quickstart (plaintext)

1. `cp .env.example .env` and fill in SASL creds for your cluster
2. Edit `kroxy-config.yaml` — set `bootstrapServers` to your cluster's
   bootstrap address. `numberOfBrokerPorts` defaults to 3; if your cluster has
   a different number of brokers, see `nodeIdRanges` in the [Kroxylicious
   docs][kroxy-docs].
3. `docker compose up -d`
4. `docker logs -f kroxy` — confirm "Kroxylicious is started"
5. `./test.sh` — runs metadata + produce/consume through the proxy

`rpk cluster metadata` should return broker addresses pointing at
`127.0.0.1:9193+` instead of the upstream broker hostnames. That's the
proof the rewrite is working.

[kroxy-docs]: https://kroxylicious.io/

## Production-shaped deployment (TLS, public hostname)

See [gcp/README.md](gcp/README.md) for a step-by-step that:

- Reserves a static external IP in GCP
- Creates a small Compute Engine VM with Docker
- Issues a Let's Encrypt cert via certbot
- Runs Kroxylicious with downstream TLS

## How TLS / SASL flow through the proxy

- **Downstream TLS** terminates at the proxy. The proxy presents its own cert
  (LE in the GCE example). Clients validate against the proxy hostname.
- **Upstream TLS** is a separate session per broker. The proxy uses the
  platform trust store to validate the upstream cluster's public cert.
- **SASL** passes through. The Kafka client uses the same credentials it
  would use against the upstream cluster — the proxy doesn't terminate or
  rewrite the SASL exchange.

## Caveats and known gaps

- **Single point of failure.** This repo runs one container. For production
  you want at least two instances behind an L4 load balancer with EIPs.
- **Proxy bottleneck.** All Kafka throughput flows through the proxy fleet.
  Size accordingly.
- **Schema Registry / HTTP Proxy / Console** use separate ports and aren't
  proxied here. Add additional gateways or front them with a separate
  reverse proxy if your clients need them.
