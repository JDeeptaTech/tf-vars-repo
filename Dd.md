```sql

-- Your vm_queue table
CREATE TABLE vm_queue (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vm_name     TEXT NOT NULL,
    environment TEXT NOT NULL,
    status      TEXT DEFAULT 'pending',   -- pending/placed/failed
    spec        JSONB NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Trigger function — fires NOTIFY automatically on insert/update
CREATE OR REPLACE FUNCTION notify_vm_queue_change()
RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify(
        'vm_queue_events',              -- channel name
        json_build_object(
            'id',          NEW.id,
            'vm_name',     NEW.vm_name,
            'environment', NEW.environment,
            'status',      NEW.status,
            'operation',   TG_OP          -- INSERT / UPDATE / DELETE
        )::text
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach trigger to table
CREATE TRIGGER vm_queue_notify
    AFTER INSERT OR UPDATE ON vm_queue
    FOR EACH ROW
    EXECUTE FUNCTION notify_vm_queue_change();


CREATE TABLE vm_registry (
    -- ── Identity ─────────────────────────────────────────────────
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vm_queue_id      UUID REFERENCES vm_queue(id),
    vm_name          TEXT NOT NULL,
    environment      TEXT NOT NULL,
    owner_team       TEXT NOT NULL,
    requested_by     TEXT NOT NULL,

    -- ── Location (relational — Day-2 resolver) ───────────────────
    cluster_name     TEXT NOT NULL,
    cluster_api_url  TEXT NOT NULL,
    namespace        TEXT NOT NULL,
    node_name        TEXT,
    instancetype     TEXT NOT NULL,

    -- ── Lifecycle ────────────────────────────────────────────────
    status           TEXT NOT NULL DEFAULT 'building',
    power_state      TEXT NOT NULL DEFAULT 'unknown',

    -- ── JSONB — only what belongs here ───────────────────────────
    network          JSONB NOT NULL DEFAULT '{}',
    storage          JSONB NOT NULL DEFAULT '[]',
    placement        JSONB NOT NULL DEFAULT '{}',
    tags             JSONB NOT NULL DEFAULT '{}',

    -- ── Timestamps ───────────────────────────────────────────────
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at     TIMESTAMPTZ,

    UNIQUE (vm_name, cluster_name, namespace)
);
```

# VM Self-Service Platform — Database Migrations

Alembic-based PostgreSQL migration system for the VM Self-Service Platform.  
Runs as a Kubernetes Job before each deployment, integrated with the ArgoCD GitOps workflow.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Database Schema](#database-schema)
- [Quick Start](#quick-start)
- [Migration Versions](#migration-versions)
- [Running Migrations](#running-migrations)
  - [Local Development](#local-development)
  - [Kubernetes (No ArgoCD)](#kubernetes-no-argocd)
  - [Kubernetes (With ArgoCD)](#kubernetes-with-argocd)
  - [Azure DevOps Pipeline](#azure-devops-pipeline)
- [Rollback](#rollback)
- [Adding a New Migration](#adding-a-new-migration)
- [Secrets and Credentials](#secrets-and-credentials)
- [Troubleshooting](#troubleshooting)

---

## Overview

```
┌─────────────────────────────────────────────────────────┐
│                   Deployment Flow                        │
│                                                         │
│  Git Push ──► Migration Job ──► PostgreSQL              │
│                    │                                    │
│                    └── success ──► App Pods Start        │
└─────────────────────────────────────────────────────────┘
```

**Key design decisions:**

- **Alembic** manages all schema changes — every migration has both `upgrade()` and `downgrade()`
- **No credentials in Git** — `DATABASE_URL` is injected at runtime via Vault Agent or Kubernetes Secret
- **Atomic migrations** — each revision runs in a transaction; partial failures auto-rollback
- **Audit trail** — PostgreSQL triggers automatically write to `audit.audit_log` on every INSERT/UPDATE/DELETE
- **Three-layer config** — `config.resolve_config()` resolves global → environment → subscription overrides

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Python | 3.10+ | Runtime |
| Alembic | 1.13+ | Migration framework |
| SQLAlchemy | 2.0+ | Async ORM |
| asyncpg | 0.29+ | Async PostgreSQL driver |
| PostgreSQL | 15+ | Target database |
| kubectl | 1.28+ | Kubernetes CLI (for K8s deployments) |

Install Python dependencies:

```bash
pip install alembic sqlalchemy[asyncio] asyncpg
```

---

## Project Structure

```
db-migrations/
│
├── README.md                              # This file
├── alembic.ini                            # Alembic configuration
│
├── alembic/
│   ├── env.py                             # Async engine setup, DATABASE_URL injection
│   └── versions/
│       ├── 001_create_schemas.py          # Creates platform, config, audit, _internal schemas
│       ├── 002_create_tables.py           # Creates all core tables with indexes
│       ├── 003_create_functions.py        # Creates trigger functions, attaches triggers
│       ├── 004_create_stored_procedures.py# Creates provision_vm, decommission_vm, upsert_config
│       └── 005_seed_data.py               # Seeds default config values
│
├── k8s/
│   └── migration-job.yaml                 # Kubernetes Job + RBAC + Vault annotations
│
└── scripts/
    └── migrate.sh                         # Developer helper CLI
```

---

## Database Schema

Four schemas with distinct responsibilities:

```
┌─────────────────────────────────────────────────────────────────────┐
│ platform                     │ config                               │
│  ├── subscriptions           │  └── config_entries                 │
│  ├── virtual_machines        │       (global / env / subscription)  │
│  └── placement_decisions     │                                      │
├─────────────────────────────────────────────────────────────────────│
│ audit                        │ _internal                            │
│  └── audit_log               │  ├── set_updated_at()               │
│       (immutable, trigger-   │  └── record_audit_event()           │
│        written only)         │       (SECURITY DEFINER)            │
└─────────────────────────────────────────────────────────────────────┘
```

| Schema | Access | Description |
|---|---|---|
| `platform` | Read/Write | Core VM lifecycle — subscriptions, VMs, placement decisions |
| `config` | Read/Write | Runtime config with three-layer resolution |
| `audit` | Read-only | Immutable audit trail — written only via triggers |
| `_internal` | Execute-only | Private trigger functions, not directly callable by app |

---

## Quick Start

```bash
# 1. Clone and set up
git clone <repo>
cd db-migrations

# 2. Set the database URL
export DATABASE_URL=postgresql+asyncpg://user:password@localhost:5432/platform_db

# 3. Apply all migrations
./scripts/migrate.sh upgrade

# 4. Verify
./scripts/migrate.sh current
```

---

## Migration Versions

```
base
 └── 001  create schemas          (platform, config, audit, _internal)
      └── 002  create tables      (subscriptions, virtual_machines, ...)
           └── 003  functions     (set_updated_at, record_audit_event, ...)
                └── 004  procs    (provision_vm, decommission_vm, upsert_config)
                     └── 005  seed data  (default config, env flags)
                          └── HEAD
```

| Revision | Description | Rollback Safe |
|---|---|---|
| 001 | Create schemas and grants | Yes |
| 002 | Create tables, indexes, constraints | Yes — no data yet |
| 003 | Create functions and attach triggers | Yes — CASCADE drops triggers |
| 004 | Create stored procedures | Yes |
| 005 | Seed default config values | Yes — DELETE by created_by |

---

## Running Migrations

### Local Development

Use the helper script:

```bash
# Apply all pending migrations
./scripts/migrate.sh upgrade

# Apply up to a specific revision
./scripts/migrate.sh upgrade 003

# Check current state
./scripts/migrate.sh current

# View full history
./scripts/migrate.sh history

# Check DB is at head (CI-friendly, exits non-zero if not)
./scripts/migrate.sh check

# Preview SQL without running it
./scripts/migrate.sh sql 004
```

Or call Alembic directly:

```bash
alembic upgrade head
alembic current
alembic history --verbose
```

---

### Kubernetes (No ArgoCD)

#### Option A — Pipeline applies Job then Deployment separately

```bash
# 1. Apply the migration Job
kubectl apply -f k8s/migration-job.yaml

# 2. Wait for it to complete
kubectl wait job/db-migration \
  --for=condition=Complete \
  --timeout=300s \
  --namespace=platform-api

# 3. Check it succeeded
if [ $? -ne 0 ]; then
  kubectl logs job/db-migration -n platform-api
  exit 1
fi

# 4. Deploy the app
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment/platform-api -n platform-api
```

#### Option B — Single manifest with init container wait

Deploy both Job and Deployment in one file. The Deployment's init container
uses `kubectl wait` to block the app from starting until the Job completes:

```bash
# Substitute your image tag and apply
export IMAGE_TAG=v1.2.0

sed -e "s/IMAGE_TAG/${IMAGE_TAG}/g" \
    k8s/platform-api-with-migration.yaml | kubectl apply -f -

# Watch the sequence (Job runs → Deployment waits → App starts)
kubectl get pods -n platform-api -w
```

Expected output:

```
NAME                         READY   STATUS      RESTARTS
db-migration-v1-2-0-xk9bz   0/1     Running     0       ← migration running
platform-api-abc12           0/1     Init:0/1    0       ← app blocked
platform-api-def34           0/1     Init:0/1    0       ← app blocked

# Job completes...

db-migration-v1-2-0-xk9bz   0/1     Completed   0       ← migration done
platform-api-abc12           1/1     Running     0       ← app started
platform-api-def34           1/1     Running     0       ← app started
```

---

### Kubernetes (With ArgoCD)

The migration Job in `k8s/migration-job.yaml` already contains the PreSync hook annotation:

```yaml
annotations:
  argocd.argoproj.io/hook: PreSync
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

ArgoCD automatically runs the Job before rolling out any app resources.  
No extra configuration needed — just commit `migration-job.yaml` to your GitOps repo.

---

### Azure DevOps Pipeline

Split into two stages so the deploy stage is blocked until migration succeeds:

```yaml
# azure-pipelines.yml
stages:
  - stage: Migrate
    displayName: "Run Database Migrations"
    jobs:
      - job: RunMigrations
        steps:
          - task: Kubernetes@1
            displayName: "Apply Migration Job"
            inputs:
              command: apply
              arguments: -f k8s/migration-job.yaml

          - task: Kubernetes@1
            displayName: "Wait for Migration"
            inputs:
              command: custom
              customCommand: wait
              arguments: >
                job/db-migration
                --for=condition=Complete
                --timeout=300s
                --namespace=platform-api

  - stage: Deploy
    displayName: "Deploy Application"
    dependsOn: Migrate          # blocked until Migrate stage passes
    condition: succeeded()
    jobs:
      - job: DeployApp
        steps:
          - task: KubernetesManifest@0
            inputs:
              action: deploy
              manifests: k8s/deployment.yaml
```

---

## Rollback

> **Always check current state before rolling back:**
> ```bash
> ./scripts/migrate.sh current
> alembic history --verbose
> ```

### Roll back one migration

```bash
./scripts/migrate.sh downgrade -1

# Or directly:
alembic downgrade -1
```

### Roll back to a specific revision

```bash
# Rolls back everything AFTER 003, leaving 003 in place
./scripts/migrate.sh downgrade 003
```

### Roll back N steps

```bash
alembic downgrade -2   # undo last 2 migrations
alembic downgrade -3   # undo last 3 migrations
```

### Full reset (dev/test only)

```bash
./scripts/migrate.sh downgrade base
```

### Preview rollback SQL without executing

```bash
# Shows SQL that would run to go from revision 004 back to 003
alembic downgrade --sql 003:004
```

### Emergency rollback in Kubernetes

```bash
# Get a shell into a running pod
kubectl exec -it deploy/platform-api -n platform-api -- bash

# Inside the pod
source /vault/secrets/db
alembic current
alembic downgrade -1
alembic current
```

### ⚠️ Rollback warnings

| Situation | Warning |
|---|---|
| Rolling back revision 002 | **Drops all tables — all data is lost** |
| Rolling back in prod | Take a `pg_dump` snapshot first |
| ArgoCD is active | Suspend auto-sync before manual rollback or ArgoCD will re-apply on next sync |
| `downgrade()` is empty | Rollback silently does nothing — always implement and test downgrade() |

---

## Adding a New Migration

### 1. Create the file manually

```bash
# Create the next file in versions/
touch alembic/versions/006_add_network_config.py
```

Follow the naming pattern: `<revision>_<short_description>.py`

```python
"""006 add network config table

Revision ID: 006
Revises: 005
Create Date: 2024-03-15
"""

from alembic import op
import sqlalchemy as sa

revision = "006"
down_revision = "005"    # ← must point to the previous revision
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "network_configs",
        sa.Column("id", sa.UUID(), primary_key=True,
                  server_default=sa.text("gen_random_uuid()")),
        sa.Column("vm_id", sa.UUID(), sa.ForeignKey("platform.virtual_machines.id")),
        sa.Column("vnet_name", sa.String(128), nullable=False),
        sa.Column("subnet", sa.String(64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.text("now()")),
        schema="platform",
    )


def downgrade() -> None:
    op.drop_table("network_configs", schema="platform")
```

### 2. Auto-generate from SQLAlchemy model diff

```bash
# Requires target_metadata set in env.py
alembic revision --autogenerate -m "add network config table"
```

> Always review auto-generated migrations before applying — Alembic may not detect all changes (e.g. stored procedures, custom functions, indexes on expressions).

### 3. Test both directions locally

```bash
# Apply the new migration
alembic upgrade head

# Verify the change in the DB
psql $DATABASE_URL -c "\dt platform.*"

# Roll it back
alembic downgrade -1

# Verify it was undone
psql $DATABASE_URL -c "\dt platform.*"

# Re-apply ready for PR
alembic upgrade head
```

### 4. Rules for new migrations

- Every migration **must** have a working `downgrade()` — never leave it as `pass`
- Use `CREATE INDEX CONCURRENTLY` for large tables to avoid locking
- Add new columns as `nullable=True` or with a `server_default` — never `NOT NULL` without a default on an existing table
- Data migrations: snapshot affected rows to a backup table before transforming
- Test both `upgrade()` and `downgrade()` before raising a PR

---

## Secrets and Credentials

**No credentials are stored in Git or hardcoded.**

`DATABASE_URL` is read from the environment variable at runtime:

```
postgresql+asyncpg://<user>:<password>@<host>:5432/<dbname>
```

| Environment | How credentials are injected |
|---|---|
| Local dev | `export DATABASE_URL=...` in shell |
| Kubernetes + Vault | Vault Agent sidecar writes to `/vault/secrets/db`, sourced in container entrypoint |
| Kubernetes + K8s Secret | `env.valueFrom.secretKeyRef` in Job/Deployment spec |
| Azure DevOps | Pipeline variable group / Azure Key Vault task |

---

## Troubleshooting

### Migration Job fails in Kubernetes

```bash
# Check Job status
kubectl describe job db-migration -n platform-api

# Check Pod logs
kubectl logs job/db-migration -n platform-api

# Check events
kubectl get events -n platform-api --sort-by='.lastTimestamp'
```

---

### `alembic check` fails in CI

The DB has unapplied migrations. Either:

```bash
# Option A: apply missing migrations
alembic upgrade head

# Option B: you have uncommitted migration files not in this branch
alembic history --verbose   # look for [pending] revisions
```

---

### "Can't locate revision" error

```
alembic.util.exc.CommandError: Can't locate revision identified by '006'
```

The revision ID in `down_revision` doesn't match any file. Check your chain:

```bash
alembic history --verbose   # verify all revisions are linked correctly
```

---

### Two developers created revision 006 (branch conflict)

```
ERROR: Multiple head revisions are present
```

Resolve by creating a merge revision:

```bash
alembic merge -m "merge feature branches" <rev_a> <rev_b>
alembic upgrade head
```

---

### Rollback fails on DROP TABLE (data exists)

PostgreSQL will refuse to drop a table with foreign key references from other tables.
The migration `downgrade()` uses `CASCADE` to handle this, but if you've manually added
constraints outside of migrations, you may need to drop them first:

```sql
-- Find blocking constraints
SELECT conname, conrelid::regclass
FROM pg_constraint
WHERE confrelid = 'platform.virtual_machines'::regclass;
```

---

### Check what Alembic version is in the DB

```bash
psql $DATABASE_URL -c "SELECT * FROM alembic_version;"
```

---

### Generate SQL for a revision without running it

```bash
# Offline mode — prints SQL, does not connect to DB
alembic upgrade --sql 004:005    # upgrade SQL from 004 to 005
alembic downgrade --sql 004:003  # downgrade SQL from 004 to 003
```

---

## Related Documentation

- [Alembic Official Docs](https://alembic.sqlalchemy.org/en/latest/)
- [SQLAlchemy Async Docs](https://docs.sqlalchemy.org/en/20/orm/extensions/asyncio.html)
- [DB Migration Design Document](../docs/DB_Migration_Design_v1.0.docx)
- [Platform API README](../README.md)
