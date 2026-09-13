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
   Connection" → GitHub → authorize the app, grant it access to all 7
   repos this project touches (`bradjobe.dev`, `demos-ui`,
   `llm-testing-deploy`, `pose-tracker`, `ccaas`, `qwen-llm-gke`,
   `bradjobe-dev-infra`). This step is inherently interactive (GitHub
   OAuth consent) and can't be scripted.

   This single step does more than it looks like: the console flow
   creates the `google_cloudbuildv2_connection` itself (named
   `scradftw-github`) *and* a Secret Manager secret holding its GitHub
   token, already granted to Cloud Build's service agent. `cloudbuild.tf`
   deliberately has no `resource` for either — only a `data
   "google_cloudbuildv2_connection"` reading `scradftw-github` by name.
   Terraform never owns this connection's lifecycle.

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
| Cloud Run (7 services, scale-to-zero, low traffic) | ~$0–10 |
| Global external HTTPS LB (forwarding rules + data processed) | ~$18+ |
| Cloud NAT (ccaas-vm's + GKE nodes' internet egress) | ~$32 gateway + ~$0.045/GB processed |
| Cloud DNS zone | ~$0.20 + queries |
| Artifact Registry storage | ~$1–2 |
| **Total** | **roughly $130–185/mo**, dominated by the GPU nodes, Cloud NAT, and the always-on LB/VM |

The single biggest lever if this needs to come down further: drop the GPU
node pool to 0 nodes when not actively demoing it (interviews, portfolio
reviews) and scale back to 2 with `gcloud container clusters resize` —
Terraform's `llm_gpu_node_count` var reflects the steady-state you want
long-term, not a knob for day-to-day toggling.

## Rollback

Every resource here is additive to what's already running on Linode —
nothing in this repo touches the existing VPS. If a Cloud Build apply
produces something wrong, the fix is a normal revert PR (which itself
plans and applies through the same pipeline), not a manual console
change. If DNS has already cut over and something is badly broken,
reverting the registrar's nameservers back to the original
`dns1/dns2.registrar-servers.com` is the fastest way back to the old VPS
while you fix forward.
