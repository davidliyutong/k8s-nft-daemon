# idekube-outbound-nft-firewall

A Kubernetes deployment project for enforcing **node-level nftables firewall rules** via a DaemonSet, managed with Kustomize.

Each pod runs on a node in the host network namespace, applies a named nftables table from a ConfigMap, and removes it cleanly on pod deletion or node drain.  The design is **idempotent**: re-applying the same overlay always converges to the same ruleset.

## Project Structure

```
.
├── base/                        # Base resources (do not edit for per-env config)
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── serviceaccount.yaml
│   ├── daemonset.yaml
│   ├── entrypoint.sh            # Pod startup script (apply rules, trap SIGTERM)
│   └── rules.nft                # Default rules — pass-through, no restrictions
└── overlays/
    ├── custom/                  # Template — copy this to create a new environment
    │   ├── kustomization.yaml   # ← namespace + image ref
    │   ├── patch.yaml           # ← resources, nodeSelector, tolerations
    │   └── rules.nft            # ← site-specific nftables rules
    ├── dev/                     # Pass-through rules, minimal resources
    │   ├── kustomization.yaml
    │   ├── patch.yaml
    │   └── rules.nft
    └── prod/                    # Bogon-blocking rules, control-plane tolerations
        ├── kustomization.yaml
        ├── patch.yaml
        └── rules.nft
```

## Quick Start

```bash
# Deploy dev (pass-through, no blocking)
kubectl apply -k overlays/dev

# Deploy prod (bogon blocking on all nodes including control-plane)
kubectl apply -k overlays/prod

# Preview rendered manifests (dry-run)
kubectl kustomize overlays/prod
```

## How It Works

1. The DaemonSet schedules one pod per node (subject to `nodeSelector` / `tolerations`).
2. The pod runs with `hostNetwork: true` and `CAP_NET_ADMIN` so that `nft` commands operate on the **host kernel's** netfilter tables, not just the pod's network namespace.
3. On startup `entrypoint.sh`:
   - Installs `nft` via `apk` if the image does not already provide it.
   - Deletes the managed table (`inet nft-custom` by default) if it exists — this removes any stale rules from a previous run.
   - Loads the fresh ruleset from `/etc/nft/rules.nft`.
4. On pod deletion or node drain (SIGTERM), the script removes the table, leaving the node in its original state.

### Idempotency

Running `kubectl apply -k overlays/<env>` multiple times is safe:
- Kustomize only updates resources that have changed.
- The ConfigMap hash suffix causes a rolling DaemonSet restart only when `rules.nft` or `entrypoint.sh` actually change.
- The entrypoint always flushes and recreates the table, so concurrent or repeated applies never accumulate duplicate rules.

## Creating a New Environment

Copy the `custom` overlay and rename it:

```bash
cp -r overlays/custom overlays/staging
```

Then edit three files:

### `overlays/staging/kustomization.yaml`

| Field | Purpose |
|-------|---------|
| `namespace` | Kubernetes namespace to deploy into |
| `images[].newTag` | Alpine image tag |
| `images[].newName` | Override registry (private mirror) |
| `images[].digest` | Pin exact image digest |

### `overlays/staging/patch.yaml`

| Field | Purpose |
|-------|---------|
| `containers[].resources` | CPU/memory requests and limits |
| `spec.template.spec.nodeSelector` | Restrict pods to labelled nodes |
| `spec.template.spec.tolerations` | Schedule onto tainted nodes |
| `env[NFT_TABLE]` | Override the managed table name |
| `env[REAPPLY_INTERVAL]` | Re-apply rules every N seconds (0 = off) |

### `overlays/staging/rules.nft`

Replace with your site-specific nftables rules.  The table name inside this file must match `NFT_TABLE` (default: `nft-custom`).

See `examples/` for ready-to-use templates.

## Configuring nftables Rules

Edit `rules.nft` in your overlay.  All rules live in a single named table with one or more chains.

### Block specific destinations

```nft
table inet nft-custom {
    set blocked4 {
        type ipv4_addr
        flags interval
        elements = { 203.0.113.0/24, 198.51.100.0/24 }
    }

    chain output {
        type filter hook output priority filter;
        policy accept;
        ip daddr @blocked4 drop comment "block specific ranges"
    }

    chain forward {
        type filter hook forward priority filter;
        policy accept;
        ip daddr @blocked4 drop comment "block from pods too"
    }
}
```

### Override rules per overlay

Each overlay replaces only `rules.nft` via `behavior: merge` in `configMapGenerator`, leaving `entrypoint.sh` from the base intact:

```yaml
configMapGenerator:
  - name: nft-config
    behavior: merge
    files:
      - rules.nft
```

### Periodic re-apply

If another tool on the node (e.g. `firewalld`) may flush nftables rules, enable the periodic re-apply:

```yaml
# in patch.yaml
env:
  - name: REAPPLY_INTERVAL
    value: "300"   # re-apply every 5 minutes
```

## nodeSelector

Restrict which nodes run the DaemonSet pod by uncommenting `nodeSelector` in `patch.yaml`:

```yaml
# overlays/<env>/patch.yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/os: linux
        node-role.kubernetes.io/worker: "true"
```

To run on **all** nodes including control-plane, remove `nodeSelector` and add tolerations for control-plane taints (see `overlays/prod/patch.yaml` for an example).

## Overlay Reference

| Overlay | Namespace | nodeSelector | Tolerations | Rules |
|---------|-----------|--------------|-------------|-------|
| dev | nft-firewall-dev | none (all nodes) | none | pass-through |
| prod | nft-firewall | none (all nodes) | control-plane + master | bogon block |
| custom | nft-firewall-custom | template (commented) | template (commented) | pass-through template |

## Architecture Notes

- **hostNetwork: true** — pods share the host network namespace; `nft` commands affect the node's kernel netfilter tables directly.
- **CAP_NET_ADMIN** — only the minimum capability required for nftables is added; `privileged: true` is not needed.
- **Named table isolation** — all rules live in `inet nft-custom` (configurable).  Other nftables tables on the host are never touched.
- **Clean teardown** — SIGTERM handling in `entrypoint.sh` removes the table before the pod exits, so node firewall state is always restored on DaemonSet deletion or rollout.
- **Rolling update** — `maxUnavailable: 1` on the DaemonSet update strategy keeps impact to one node at a time during rollouts.
- **Image** — [`alpine:3.21`](https://hub.docker.com/_/alpine) from Docker Hub.  `nftables` is installed via `apk` on first start if not already present in the image.  Pin a digest in production.
