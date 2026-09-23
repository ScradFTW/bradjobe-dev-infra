# bradjobe-dev-infra

Terraform for the `bradjobe-dev` GCP project — the migration target for
bradjobe.dev, moving off a single Linode VPS onto Cloud Run + one GKE
cluster + one GCE VM.

**Nobody runs `terraform apply` from a laptop.** Every change to this repo
is applied by Cloud Build, using a dedicated `terraform-infra` service
account (`iam.tf`) that no human identity can impersonate: open a PR and
Cloud Build posts a `terraform plan` as a check; merge to `main` and Cloud
Build runs `terraform apply -auto-approve`. See `cloudbuild-terraform.yaml`
and "Bootstrap" below for how that pipeline itself gets stood up.

## Architecture

```
                         ┌─ Cloud DNS (bradjobe-dev-zone) ─┐
                         │  bradjobe.dev / www  → LB IP    │
                         │  llm.bradjobe.dev    → GKE IP   │
                         └──────────────────────────────────┘

  bradjobe.dev, www.bradjobe.dev                    llm.bradjobe.dev
          │                                                 │
          ▼                                                 ▼
  Global External HTTPS LB                          GKE Ingress (gce class)
  (lb.tf: url_map, route_rules)                      + ManagedCertificate
          │                                                 │
   ┌──────┼───────────────┬───────────────┐                 ▼
   ▼      ▼               ▼               ▼          bradjobe-llm-cluster
Cloud Run  Cloud Run   Cloud Run      ccaas-vm        (zonal, 2x Spot T4
(static:   (APIs:      (static:       (GCE instance,   nodes, taint-only)
 site,      genre-      shared         Docker+nginx,   → qwen-llm Deployment
 ai-hub,    classifier, ai-tools       dockerode        (llama-server +
 ai-tools,  image-      SPA served     manages sandbox   nginx CORS sidecar)
 pose-      classifier, at 5 paths)    + egress-proxy
 tracker)   agent-orch)                containers)
```

Path routing on the main LB (`lb.tf`, `google_compute_url_map.main`):

| Path                                                                 | Backend              |
|-----------------------------------------------------------------------|-----------------------|
| `/genre-classifier/api/*`                                            | Cloud Run: genre-classifier |
| `/image-classifier/api/*`                                            | Cloud Run: image-classifier |
| `/agent-demo/api/*`                                                  | Cloud Run: agent-orchestrator |
| `/status/api/agent-stats` → rewritten to `/stats`                    | Cloud Run: agent-orchestrator |
| `/status/api/genre-stats` → rewritten to `/stats`                    | Cloud Run: genre-classifier |
| `/status/api/image-stats` → rewritten to `/stats`                    | Cloud Run: image-classifier |
| `/ai/*`                                                              | Cloud Run: ai-hub |
| `/pose-tracker/*`                                                    | Cloud Run: pose-tracker |
| `/ccaas/*`, `/sites/*`                                               | ccaas-vm (GCE instance group) |
| `/agent-demo/*`, `/genre-classifier/*`, `/image-classifier/*`, `/llm-testing/*`, `/status/*` | Cloud Run: ai-tools (shared SPA) |
| everything else                                                      | Cloud Run: bradjobe-site |

`llm.bradjobe.dev` (its own GKE Ingress, **not** part of the LB above) →
the `qwen-llm` Service in `bradjobe-llm-cluster`.

`electionmap.bradjobe.dev` is a second host rule on the same LB, with its
own managed cert: every path goes to Cloud Run `electionmap`, which talks to
the Cloud SQL Postgres instance `electionmap-db` (`electionmap.tf`).

## What's deliberately NOT in this repo

The nginx-layer interactions-tracking plugin (`/var/www/interactions`,
`beacon.js`, the `resume-notify` email alerter) and the `ip_watch.py`
visitor-IP alerting cron were built specifically to stay out of any public
repo. This migration doesn't change that: they're not represented here,
and this repo is public, matching your other app repos. If you want them
migrated too, they should land in a **separate, private** repo/pipeline —
happy to build that as its own piece, deliberately kept out of this one.

## Repos this connects to

Each of these gets a `cloudbuild.yaml` (added via PR, see the migration
plan) and a `google_cloudbuild_trigger` (`cloudbuild_triggers.tf`) that
deploys on push to `main`:

- `bradjobe.dev` → Cloud Run `bradjobe-site`
- `demos-ui` → Cloud Run `ai-hub` (package `ai-hub`) and `ai-tools` (package `ai-tools`), independently triggered via `included_files`
- `llm-testing-deploy` → Cloud Run `genre-classifier`, `image-classifier`, `agent-orchestrator`, independently triggered via `included_files`
- `pose-tracker` → Cloud Run `pose-tracker`
- `ccaas` → `ccaas-vm` (builds 3 images: backend, sandbox, egress-proxy; redeploys over an IAP SSH tunnel)
- `qwen-llm-gke` (new repo) → `bradjobe-llm-cluster` (`kubectl apply`)
- `canelect` → Cloud Run `electionmap` (see "Election Map" below)

## Bootstrap (one-time, manual — run once, in order)

Terraform can't create the thing that lets Terraform run, so this handful
of steps happens once, by hand, before the first push to `main`. None of
it is "running terraform against real infra" — it's `gcloud`/console
setup that the self-hosted pipeline then takes over from.

1. **Enable the APIs Cloud Build itself needs to exist**, and create the
   state bucket:
   ```sh
   gcloud config set project bradjobe-dev
   gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
     iam.googleapis.com cloudbuild.googleapis.com storage.googleapis.com \
     secretmanager.googleapis.com run.googleapis.com container.googleapis.com \
     compute.googleapis.com artifactregistry.googleapis.com dns.googleapis.com

   gcloud storage buckets create gs://bradjobe-dev-tfstate \
     --location=northamerica-northeast1 --uniform-bucket-level-access
   gcloud storage buckets update gs://bradjobe-dev-tfstate --versioning
   ```

2. **Create the `terraform-infra` service account by hand once**, so step
   3's Cloud Build trigger has something to run as (Terraform normally
   owns this account — see `iam.tf` — but it can't create the identity
   it needs to first apply itself):
   ```sh
   gcloud iam service-accounts create terraform-infra \
     --display-name="Cloud Build — terraform apply for bradjobe-dev-infra"

   for role in run.admin container.admin compute.admin artifactregistry.admin \
     dns.admin secretmanager.admin iam.serviceAccountAdmin iam.serviceAccountUser \
     resourcemanager.projectIamAdmin storage.admin serviceusage.serviceUsageAdmin \
     cloudbuild.builds.editor cloudbuild.connectionAdmin logging.logWriter; do
     gcloud projects add-iam-policy-binding bradjobe-dev \
       --member="serviceAccount:terraform-infra@bradjobe-dev.iam.gserviceaccount.com" \
       --role="roles/$role"
   done
   ```
   (Terraform will import/reconcile this same account on its first apply —
   no drift, `iam.tf` defines the identical account + roles.)

3. **Install the Cloud Build GitHub App** on the `ScradFTW` account:
   Cloud Console → Cloud Build → Repositories (2nd gen) → "Create Host
   Connection" → GitHub → authorize the app, grant it access to all 8
   repos this project touches (`bradjobe.dev`, `demos-ui`,
   `llm-testing-deploy`, `pose-tracker`, `ccaas`, `qwen-llm-gke`,
   `canelect`, `bradjobe-dev-infra`). This step is inherently interactive (GitHub
   OAuth consent) and can't be scripted.

   This single step does more than it looks like: the console flow
   creates the `google_cloudbuildv2_connection` itself (named
   `scradftw-github`) *and* a Secret Manager secret holding its GitHub
   token, already granted to Cloud Build's service agent. `cloudbuild.tf`
   has a matching `import` block for `google_cloudbuildv2_connection.github`
   (the google provider has no data source for this resource type, only
   `resource` — importing it, with config matching its real values, is
   the only way to reference it from Terraform) — so Terraform adopts and
   manages it going forward, it just didn't create it.

4. **Register this repo with that connection**, and tell Terraform about
   the resource that creates so its first apply doesn't try to create a
   duplicate:
   ```sh
   gcloud builds repositories create bradjobe-dev-infra \
     --connection=scradftw-github --region=northamerica-northeast1 \
     --remote-uri=https://github.com/ScradFTW/bradjobe-dev-infra.git
   ```
   `cloudbuild.tf` has a matching `import` block for
   `google_cloudbuildv2_repository.infra` — the first real `terraform
   apply` (step 6) reconciles onto this resource instead of failing with
   "already exists". This is the only repo that needs this: the other 6
   have no chicken-and-egg problem, since nothing has to exist before
   Terraform creates their `google_cloudbuildv2_repository` resources
   normally.

5. **Create the one bootstrap trigger** that lets push-to-main on *this*
   repo start applying itself (after this, `cloudbuild_triggers.tf`'s
   `terraform_apply_on_main` resource takes over managing its own
   trigger — this manual one and the Terraform-managed one converge to
   the same config, so there's nothing to clean up):
   ```sh
   gcloud builds triggers create github \
     --name=terraform-apply-on-main --region=northamerica-northeast1 \
     --repository=projects/bradjobe-dev/locations/northamerica-northeast1/connections/scradftw-github/repositories/bradjobe-dev-infra \
     --branch-pattern="^main$" --build-config=cloudbuild-terraform.yaml \
     --substitutions=_TF_COMMAND="apply -auto-approve" \
     --service-account=projects/bradjobe-dev/serviceAccounts/terraform-infra@bradjobe-dev.iam.gserviceaccount.com
   ```

6. **Push this repo's `main` branch.** The trigger from step 5 fires,
   applies everything in this repo (VPC, GKE, Cloud Run shells, the ccaas
   VM, the LB, DNS zone, Cloud Armor, the *other* 8 app triggers +
   `terraform_plan_on_pr`) — the very first real `terraform apply`, and
   the last one anyone runs by hand.

7. **Point the registrar's nameservers at Cloud DNS.** After step 6,
   `terraform output name_servers` (visible in the Cloud Build log, or
   `gcloud dns managed-zones describe bradjobe-dev-zone`) gives you the 4
   nameservers to set at your registrar. See "Cutover" below for timing.
   Then **verify the registrant email** Namecheap sends: if it isn't
   verified within 15 days, Namecheap suspends the domain by swapping its
   nameservers at the registry for `failed-whois-verification.namecheap.com`.
   The Namecheap dashboard keeps showing the Cloud DNS nameservers while
   that happens, so the outage looks like a DNS problem.

8. **Let `terraform-infra` manage the LLM cluster's budget.** Budgets live
   on the billing account, not the project, so the project-level roles in
   step 2 don't cover them and Terraform can't grant this to itself. A
   billing account admin runs this once:
   ```sh
   gcloud billing accounts add-iam-policy-binding 01BB9E-1216C2-6D366A \
     --member="serviceAccount:terraform-infra@bradjobe-dev.iam.gserviceaccount.com" \
     --role="roles/billing.costsManager"
   ```

## Cutover

DNS is moving from the registrar to Cloud DNS (per your choice), so the
records that matter are already correct in Cloud DNS *before* you touch
nameservers — flipping them is what actually redirects traffic, and it's
close to atomic (bounded mostly by the registrar's own propagation, not a
TTL you control beforehand):

1. Run bootstrap steps 1–6. Confirm `https://<load-balancer-ip>` serves
   the migrated site correctly using `curl --resolve` against the LB IP
   and `llm-ingress-ip` before touching DNS at all — this is the point to
   catch a routing/env-var mistake, while the Linode box is still live
   and serving real traffic.
2. Deploy every app repo at least once (merge each repo's CI/CD PR — see
   the migration plan) so Cloud Run/GKE are serving real images, not the
   `hello` placeholder.
3. Switch nameservers at the registrar (bootstrap step 7). Expect
   anywhere from minutes to ~48h for full propagation depending on the
   registrar and resolvers' cached NS TTLs.
4. Once you've confirmed traffic is flowing through GCP (check Cloud Run
   request logs / GCLB logs), decommission the Linode VPS. Not before —
   keep it as a fallback until GCP has visibly served real traffic for a
   few days.

## Secrets

The one exception is `electionmap-database-url`: Terraform generates and
writes that one itself, through a write-only argument that keeps the value
out of state (see "Election Map").

Terraform creates empty Secret Manager secrets for ccaas
(`secrets.tf`) — it never writes values into them. Populate them once,
out of band:

```sh
echo -n "<value>" | gcloud secrets versions add ccaas-google-oauth-client-id --data-file=-
echo -n "<value>" | gcloud secrets versions add ccaas-google-oauth-client-secret --data-file=-
echo -n "$(openssl rand -hex 32)" | gcloud secrets versions add ccaas-session-secret --data-file=-
echo -n "you@example.com" | gcloud secrets versions add ccaas-allowed-emails --data-file=-
```

The ccaas VM's service account can read these (`secrets.tf`); wiring them
into the running container as environment variables at deploy time is the
ccaas repo's `cloudbuild.yaml`'s job (`gcloud secrets versions access` in
the SSH redeploy step), not Terraform's.

## Cost estimate (very approximate, northamerica-northeast1)

| Resource | ~Monthly |
|---|---|
| GKE cluster management fee | $0 (first zonal cluster/billing account is free) |
| 2x Spot `n1-standard-2` + T4 | ~$60–90 (Spot T4 pricing varies; on-demand equivalent is ~3x this) |
| `ccaas-vm` (e2-medium, always-on) | ~$25 |
| Cloud Run (8 services, scale-to-zero, low traffic) | ~$0–10 |
| Cloud SQL `electionmap-db` (db-f1-micro, 10GB SSD, backups) | ~$10–13 |
| Global external HTTPS LB (forwarding rules + data processed) | ~$18+ |
| Cloud NAT (ccaas-vm's + GKE nodes' internet egress) | ~$32 gateway + ~$0.045/GB processed |
| Cloud DNS zone | ~$0.20 + queries |
| Artifact Registry storage | ~$1–2 |
| **Total** | **roughly $140–200/mo**, dominated by the GPU nodes, Cloud NAT, and the always-on LB/VM |

The single biggest lever if this needs to come down further: drop the GPU
node pool to 0 nodes when not actively demoing it (interviews, portfolio
reviews) and scale back to 2 with `gcloud container clusters resize` —
Terraform's `llm_gpu_node_count` var reflects the steady-state you want
long-term, not a knob for day-to-day toggling.

### LLM cluster spending cap

`llm_budget_guard.tf` caps `bradjobe-llm-cluster` at `llm_monthly_budget`
(default $100 CAD/month, gross of credits). Billing admins get emails at
50%, 90% and 100%. At 100%, a Cloud Function scales every node pool to 0,
which takes llm.bradjobe.dev offline until the pools are resized. Billing
data lags a few hours, so the actual shutdown lands a few hours after the
cap is crossed. The function re-applies on every budget update for the
rest of the month, so to restore early, raise `llm_monthly_budget` first
and then resize the pools (commands at the top of that file). Otherwise it
comes back with the next `terraform apply` after the month rolls over.

## Election Map

`electionmap.tf` runs the `canelect` repo (anonymous Canadian election
prediction maps, Next.js) at `https://electionmap.bradjobe.dev`. Unlike
the other Cloud Run services it has a database: Cloud SQL Postgres
`electionmap-db`, reached over the Cloud SQL connector's unix socket, with
`DATABASE_URL` injected from Secret Manager.

Terraform creates everything, including the app's database user. It
generates the password itself and passes it to Cloud SQL and to the
`electionmap-database-url` secret through write-only arguments
(`password_wo`, `secret_data_wo`), so the password never appears in state
or plan output. That's also why this repo needs Terraform 1.11 or newer
(`versions.tf`; the pipeline runs 1.16). To rotate it, bump
`local.electionmap_db_password_version` in `electionmap.tf` and merge.

Ordering matters the first time, since `terraform apply` creates a Cloud
Build repository resource that points at the GitHub repo:

1. **Create `ScradFTW/canelect` on GitHub and push the app.**
2. **Grant the Cloud Build GitHub App access to it**: GitHub → Settings →
   Applications → Google Cloud Build → Configure → Repository access → add
   `canelect`.
3. **Merge this repo's change.** The apply creates the Cloud SQL instance
   (allow ~10 minutes), the database and user, the `DATABASE_URL` secret,
   the service (running the `hello` placeholder), the cert, the DNS record
   and the `electionmap-deploy-on-main` trigger. The managed cert
   provisions on its own once Google sees the DNS record, usually within
   an hour. The app creates its `maps` table on first use.
4. **Deploy the app**: push to `canelect`'s `main`, or run
   `gcloud builds triggers run electionmap-deploy-on-main --region=northamerica-northeast1 --branch=main`.

**Connecting to the database** (admin or debugging), from a machine with
`gcloud` access. The credentials come from the secret Terraform wrote:
```sh
cloud-sql-proxy bradjobe-dev:northamerica-northeast1:electionmap-db --port 5433 &
psql "$(gcloud secrets versions access latest --secret=electionmap-database-url \
  | sed -E 's#@localhost/([^?]*).*#@127.0.0.1:5433/\1#')"
```

## Rollback

Every resource here is additive to what's already running on Linode —
nothing in this repo touches the existing VPS. If a Cloud Build apply
produces something wrong, the fix is a normal revert PR (which itself
plans and applies through the same pipeline), not a manual console
change. If DNS has already cut over and something is badly broken,
reverting the registrar's nameservers back to the original
`dns1/dns2.registrar-servers.com` is the fastest way back to the old VPS
while you fix forward.
