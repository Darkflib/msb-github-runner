# msb-github-runner

Self-hosted, ephemeral GitHub Actions runners where every job runs in its own
[microsandbox](https://github.com/superradcompany/microsandbox) microVM.

```
docker container (msb-runner, /dev/kvm)
 └─ msb-runner.sh  ── keeps POOL_SIZE slots filled
     ├─ slot 1: POST generate-jitconfig → msb run actions-runner (1 job) → VM destroyed → repeat
     └─ slot 2: ...
```

- **One job per VM.** Each runner is registered with a single-use JIT config, so
  it takes one job and exits. Nothing survives into the next job: no
  workspace, no Docker cache, no cached credentials.
- **Kernel isolation.** Jobs run under their own guest kernel, not as containers on
  the host kernel.
- **Network.** By default the VM can reach only the public internet. Private and LAN
  ranges are blocked, and so is `169.254.169.254` (cloud metadata).
- **Docker in jobs.** `dockerd` starts inside the VM (`ENABLE_DOCKER=1`), so
  `container:`/`services:` jobs and `docker build` don't need the host socket.
- The guest is the stock `ghcr.io/actions/actions-runner` image. The start
  script is injected at boot with `msb --script-path`, so there's no custom image
  to maintain.

## Setup

1. Pick an auth method:
   - **GitHub App (recommended):** see [GitHub App setup](#github-app-setup) below.
   - **Fine-grained PAT** with the same permission, set as `GITHUB_TOKEN`.
2. Create the config: `cp .env.example .env`, then edit it.
3. Start it: `docker compose up -d --build && docker compose logs -f`

The first start pulls the ~1.8 GB runner image into the `msb-data` volume.
After that, VMs boot from the cache.

Target the runners from workflows with `runs-on: [self-hosted, msb]`.

## GitHub App setup

### 1. Create the app

Open the creation page for wherever your repos live:

- **Org:** `https://github.com/organizations/<ORG>/settings/apps/new`
- **Personal account** (only for an `owner/repo` target): `https://github.com/settings/apps/new`

Fill in the form:

- **GitHub App name:** anything unique, e.g. `msb-runners-<org>`.
- **Homepage URL:** anything, e.g. your org URL.
- **Webhook:** untick **Active**. The controller polls GitHub, so it doesn't need webhooks.
- **Where can this GitHub App be installed?** Only on this account.

### 2. Set permissions

Grant only the one permission that matches your `GITHUB_TARGET`:

| `GITHUB_TARGET` | Permission |
|---|---|
| `my-org` (org-level runners) | **Organization permissions → Self-hosted runners: Read and write** |
| `owner/repo` (one repo) | **Repository permissions → Administration: Read and write** |

`Metadata: Read-only` gets added automatically. Leave everything else as **No access**.

Click **Create GitHub App**.

### 3. Note the App ID and generate a key

- On the app's **General** page, copy the **App ID**, which is a number. It is not the Client ID.
- Scroll to **Private keys**, click **Generate a private key**, and a `.pem` file downloads.

Copy the key to the host as `secrets/app.pem` and restrict it:

```bash
chmod 600 secrets/app.pem
```

### 4. Install the app

- In the app's left sidebar, click **Install App**, then **Install** next to your org or account.
- **Org target:** "All repositories" is fine. The runner permission is org-scoped anyway,
  and step 5 controls which repos can use the runners.
- **Repo target:** choose **Only select repositories** and pick that repo.

You don't need the installation ID: the controller looks it up. If you want to set
`GITHUB_APP_INSTALLATION_ID` anyway, it's the number at the end of the URL after you
install (`.../installations/<ID>`).

### 5. Create a runner group (org targets only, recommended)

Go to **Org Settings → Actions → Runner groups → New runner group**:

- **Name:** e.g. `msb`.
- **Repository access:** Selected repositories, then pick the repos that may use these runners.
- **Public repositories:** tick **Allow public repositories** if any of those repos are public.
  **This is off by default, including for the Default group.** Without it, jobs from
  public repos will just sit queued.
- After saving, the group ID is the number at the end of the URL (`.../runner-groups/<ID>`).

### 6. Configure `.env`

```ini
GITHUB_TARGET=my-org            # or owner/repo
GITHUB_APP_ID=123456
GITHUB_APP_KEY_FILE=/secrets/app.pem
RUNNER_GROUP_ID=2               # from step 5; 1 = Default
RUNNER_PREFIX=msb-test-vx1
# leave GITHUB_TOKEN unset — if set, it overrides the App
```

### 7. Start and check

```bash
docker compose up -d --build && docker compose logs -f
```

It's working when the logs show `slot 1: booting msb-test-vx1-1-...`. The runners
should also appear as **Idle** under **Settings → Actions → Runners** for the org or repo.

### Common errors in the logs

| Error | Cause |
|---|---|
| `401` on `/installation` | Wrong `GITHUB_APP_ID`, or the key doesn't belong to this app. |
| `404` on `/orgs/.../installation` | The app isn't installed on that org or repo (step 4), or there's a typo in `GITHUB_TARGET`. |
| `403` on `generate-jitconfig` | Missing permission (step 2). If you added a permission after installing, an org owner must accept it: **Org Settings → GitHub Apps → Configure → review request**. |
| `404` on `generate-jitconfig` with a group ID | Wrong `RUNNER_GROUP_ID`. |
| Runners idle but jobs stay queued | `runs-on` labels don't match, or the runner group doesn't allow that repo or public repos (step 5). |

## Tuning

| Var | Default | Notes |
|---|---|---|
| `POOL_SIZE` | 2 | Number of idle runners kept warm. Size it to host RAM ÷ `VM_MEMORY`. |
| `VM_CPUS` / `VM_MEMORY` | 2 / 4G | Per job. |
| `JOB_MAX_DURATION` | 6h | Hard kill on the VM. |
| `RUNNER_PREFIX` | msb | Must be unique per host. Used to clean up stale registrations at start and stop. |
| `MSB_NET_ARGS` | `--net public --net-rule deny@169.254.169.254` | For example, add `--net-rule allow@10.0.0.5:tcp:443` for an internal cache. |
| `MSB_EXTRA_ARGS` | | Passed straight to `msb run` (e.g. `--root-disk ...`). |

## Security notes for public repos

Microsandbox stops a malicious job from persisting or reaching your LAN. It
doesn't stop the job from using whatever that job is given. So:

- Put these runners in a **runner group** limited to the repos that need them.
- Keep *Require approval for all outside collaborators* on for fork PRs.
- Use `permissions:` to keep `GITHUB_TOKEN` minimal. Don't expose secrets to `pull_request_target`.
