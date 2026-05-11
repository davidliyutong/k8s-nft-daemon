# k8s-nft-daemon

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
    ├── cleanup/                 # Emergency cleanup — removes rules when normal delete fails
    │   ├── kustomization.yaml   # ← set namespace to match the environment being cleaned
    │   └── patch.yaml           # ← set NFT_TABLE, nodeSelector, tolerations to match
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
4. On pod deletion or node drain, cleanup happens in two stages:
   - The `preStop` lifecycle hook runs **synchronously** before SIGTERM, deleting the managed table while the container is still healthy.
   - Then SIGTERM is sent; the trap handler in `entrypoint.sh` attempts the same deletion as a no-op fallback.

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
| prod | nft-firewall | `node-feature/nft-daemon=true` | control-plane + master | NFS guard |
| custom | nft-firewall-custom | template (commented) | template (commented) | pass-through template |
| cleanup | configurable | configurable | configurable | _(no rules — removes table)_ |

## Removing the deployment

### Normal removal

```bash
kubectl delete -k overlays/prod
```

On deletion each pod goes through:
1. **preStop hook** — `nft delete table inet <NFT_TABLE>` runs synchronously.
2. **SIGTERM** — the trap handler in `entrypoint.sh` retries the deletion (no-op if already gone).
3. Pod exits; the node's nftables are restored.

### Emergency cleanup (rules stuck after crash / SIGKILL)

If pods were killed without graceful shutdown (node crash, OOM kill, `kubectl delete --force`), the nftables table may remain on the node.  Use the cleanup overlay to remove it:

```bash
# 1. Edit overlays/cleanup/kustomization.yaml — set namespace to match the dead deployment.
# 2. Edit overlays/cleanup/patch.yaml — set NFT_TABLE and copy nodeSelector/tolerations.
# 3. Deploy the cleanup DaemonSet (deletes the table on start, then sleeps).
kubectl apply -k overlays/cleanup

# 4. Wait for a Running pod on every affected node.
kubectl rollout status daemonset/nft-firewall -n <namespace>

# 5. Delete the cleanup DaemonSet (preStop hook runs, which is a no-op).
kubectl delete -k overlays/cleanup
```

The cleanup DaemonSet deliberately sleeps after the table deletion so it stays `Running` without restart-looping, and so that step 5 triggers the standard preStop + SIGTERM path.

## Architecture Notes

- **hostNetwork: true** — pods share the host network namespace; `nft` commands affect the node's kernel netfilter tables directly.
- **CAP_NET_ADMIN** — only the minimum capability required for nftables is added; `privileged: true` is not needed.
- **Named table isolation** — all rules live in a single named table (default `inet nft-custom`).  Other nftables tables on the host are never touched.
- **Two-stage teardown** — the `preStop` lifecycle hook removes the table synchronously before SIGTERM arrives; the SIGTERM trap in `entrypoint.sh` is a belt-and-suspenders fallback.
- **Rolling update** — `maxUnavailable: 1` on the DaemonSet update strategy keeps impact to one node at a time during rollouts.
- **Image** — `ghcr.io/davidliyutong/k8s-nft-daemonset` built from this repo's `Dockerfile` via the `publish` GitHub Actions workflow. Pin a digest in production.
