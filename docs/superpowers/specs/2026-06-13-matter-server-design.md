# Matter Server — Design Spec

**Date:** 2026-06-13

## Context

Home Assistant runs as a single container in `kubernetes/apps/home-assistant/`. The cluster node has L3 routing to the IoT VLAN (no L2 adjacency), and an mDNS reflector is already configured on the router between VLANs.

## Design

Matter server runs as a **sidecar container** in the existing Home Assistant pod. Both containers share the pod's network namespace, so HA connects to Matter server via `ws://localhost:5580/ws` without exposing any port outside the pod.

## Components

### Sidecar container

- **Image:** `ghcr.io/home-assistant-libs/python-matter-server:latest` (pin to a specific version after first deploy)
- **Port:** 5580 (WebSocket, internal to pod only)
- **Resources:** requests `100m` CPU / `128Mi` memory — limits `256Mi` memory

### PVC

A dedicated `PersistentVolumeClaim` (`matter-server-data`, 1Gi, ReadWriteOnce) mounted at `/data` in the sidecar. Stores commissioned device fabric and node data — losing this volume requires re-commissioning all Matter devices.

### No new Service or Ingress

The WebSocket endpoint is only reachable within the pod. No external exposure needed.

## Integration

After deploy, configure the Matter integration in Home Assistant UI:
- Paramètres → Intégrations → Matter (HACS or built-in) → `ws://localhost:5580/ws`

## Network

mDNS multicast does not cross VLANs, but the existing mDNS reflector on the router handles discovery between the cluster VLAN and the IoT VLAN. Unicast traffic (TCP) routes normally via the L3 path.

## Files changed

| File | Change |
|------|--------|
| `kubernetes/apps/home-assistant/matter-server-pvc.yaml` | New — PVC for Matter server data |
| `kubernetes/apps/home-assistant/deployment.yaml` | Add sidecar container + volume mount |
| `kubernetes/apps/home-assistant/kustomization.yaml` | Add `matter-server-pvc.yaml` to resources |
