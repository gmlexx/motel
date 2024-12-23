# Development

## Prerequisites

* Make sure that you have a [HMC](https://github.com/Mirantis/hmc/blob/main/docs/dev.md) installed.
It's your "mothership" cluster.

* DNS to test motel with managed clusters installations

## Local deployment (without HMC)

Install into local clusters these helm charts using Makefile

```bash
make dev-storage-deploy
make dev-operators-deploy
make dev-collectors-deploy
```

When everything up and running you can connect to grafana using port-forwarding

```bash
kubectl --namespace motel port-forward svc/grafana-vm-service 3000:3000
```

## Managed clusters deployment with HMC in AWS

Install helm charts into a local registry

```bash
make helm-push
```

Define your DNS zone (automatically managed by external-dns)

```bash
MOTEL_DNS="dev.example.net"
```

Install "mothership" helm chart into your "mothership" cluster


```bash
make dev-ms-deploy-aws
```

Create "storage" managed cluster using HMC

```bash
make dev-storage-deploy-aws
```

Create "managed" managed cluster using HMC

```bash
make dev-managed-deploy-aws
```

When everything up and running you can connect to grafana using port-forwarding from your "mothership" cluster

```bash
kubectl --namespace motel port-forward svc/grafana-vm-service 3000:3000
```
