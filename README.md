# self-hosted-ci

Run your GitHub Actions jobs on your own machine instead of GitHub's hosted runners: a local
Kubernetes cluster ([k3d](https://k3d.io)) with GitHub's
[Actions Runner Controller](https://github.com/actions/actions-runner-controller) for Linux jobs,
and a hardened Windows runner service for the Windows jobs a Linux cluster cannot run.

Built for one developer's workstation (Windows 11 with Docker Desktop) and tested there daily.
Every piece is declared in a file, every version is pinned, and every `make` target is idempotent,
so the whole thing rebuilds from nothing in about a minute.

- **Linux jobs:** one runner scale set per repository, scaling to zero; a runner pod exists only
  while a job runs and is thrown away after it. Docker-in-Docker, so `services:` containers in
  existing workflows work unchanged.
- **Windows jobs:** [`runners/windows/install-runner.ps1`](runners/windows/install-runner.ps1)
  installs GitHub's runner as a service under a low-privilege account, with the permissions,
  PATH and shell problems of a self-hosted Windows runner already solved
  ([docs/windows-runner.md](docs/windows-runner.md)).
- **The switch:** a workflow opts in with one line and falls back to GitHub's runners when the
  repository variable is absent; OpenTofu writes the variables.

```yaml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
```

## Bring it up

Prerequisites: Windows 11 with Docker Desktop (WSL 2 backend), `kubectl`, `git`, `gh`, and GNU make
(`winget install ezwinports.make`). Everything else is installed at pinned versions by `make tools`.

```bash
cp config.mk.example config.mk   # your GitHub owner, the repositories that get runners, the domain
make tools      # k3d, helm, flux, sops, age, mkcert, opentofu (checksums verified)
make wsl-cap    # once: memory/CPU ceilings for the WSL VM (restarts WSL, stopping every container)
make up         # the cluster from cluster/k3d.yaml, kubectl context k3d-lab
make tls        # a mkcert wildcard certificate as Traefik's default
make hello      # a smoke-test application behind the ingress
make verify     # https://hello.<DOMAIN> through Traefik, the name resolved locally
```

`mkcert -install` (once) makes your browser trust the local CA. For real hostnames in the browser,
point a wildcard such as `*.lab.example.com` at `127.0.0.1`; [`tofu/`](tofu) can create that record
in Cloudflare (`manage_dns = true`).

## Linux runners

The runners authenticate as a GitHub App you create once, by hand, because it is a credential:

1. <https://github.com/settings/apps/new>. Any name and homepage URL; under **Webhook**, clear
   **Active**.
2. **Repository permissions:** Administration **Read and write**; Metadata stays Read-only.
   Nothing else. **Where can this GitHub App be installed:** only on this account.
3. Create it, note the **App ID**, then **Generate a private key**. Keep the `.pem` outside every
   repository.
4. **Install App** on your account, **Only select repositories**: at least every repository in
   `REPOS`. The page it lands on ends in `/settings/installations/<installation id>`.
5. Store it in the cluster (never in git):

   ```bash
   kubectl --context k3d-lab create namespace arc-runners
   kubectl --context k3d-lab -n arc-runners create secret generic github-app \
     --from-literal=github_app_id=<app id> \
     --from-literal=github_app_installation_id=<installation id> \
     --from-file=github_app_private_key=<path to the .pem>
   ```

Then:

```bash
make arc            # the runner controller
make runner-image   # GitHub's runner image plus build tools, pushed to the cluster's registry
make runners        # one scale set per repository in REPOS, named lab-<repo>
make runners-status
```

and set each repository's `CI_RUNNER` variable to its scale set's name (`lab-<repo>`), by hand or
with `tofu/` (`ci_runner_repos`, then `GITHUB_TOKEN=$(gh auth token) tofu apply`).

## Security model

Runners execute whatever a workflow says, so who can reach them matters more than anything else.

- **Runner pods are privileged** (Docker-in-Docker). They get a node of their own (`make
  runner-node` labels and taints it), so a job that escapes its container finds no controller, no
  listener holding the App key and no application beside it.
- **Public repositories** reach these runners only behind fork approval: list them in
  `PUBLIC_REPOS` and `make runners` first sets every fork pull request's run to wait for your
  approval (`make fork-approval`). Keep workflows that skip forks' pull requests as well.
- **The Windows runner has no container around its jobs**, so it serves private repositories only
  (the script refuses a public one), and only for code you have merged: keep Windows jobs off pull
  requests, which may come from branches you have not reviewed.
- **The App key** can change settings, collaborators and branch protection on every repository the
  App is installed on: install it only on your own repositories. If the key may have leaked,
  delete it in the App's settings, generate a new one and recreate the `github-app` secret.
- **Everything the cluster publishes** (80, 443, the API on 6443, the registry on 5000) is bound
  to 127.0.0.1: the registry has no authentication. Every `kubectl` call names the cluster's
  context, so another cluster in your kubeconfig never receives these manifests.

## Windows runner

```powershell
# elevated PowerShell, as yourself (gh must be logged in)
.\runners\windows\install-runner.ps1 -Owner <owner> -Repo <private repo>
```

then set `CI_RUNNER_WINDOWS` (tofu: `ci_runner_windows_repos`) and use
`runs-on: ${{ vars.CI_RUNNER_WINDOWS || 'windows-latest' }}` with `defaults: run: shell: bash`.
What the script does and why is in [docs/windows-runner.md](docs/windows-runner.md).

## Building on it from a private repository

Keep your names, decisions and real values in a private repository, and this one as a git
submodule pinned to a tag:

```bash
git submodule add https://github.com/<owner>/self-hosted-ci vendor/self-hosted-ci
make -C vendor/self-hosted-ci CONFIG=$PWD/config.mk DATA=$PWD/.data up
```

The tofu modules can be called from your own root (`source = "./vendor/self-hosted-ci/tofu/modules/github-runner-vars"`).
Fix reusable things here first, tag, then move the submodule: editing the same files in two
places drifts within weeks. `make scrub WORDS=<private word list>` fails if any tracked file or
commit message here contains a word from your list, for example the names of your private
repositories, before you push a change made from the private side.

## Layout

| Path | What lives there |
|---|---|
| `cluster/k3d.yaml` | the cluster: one server, two agents, the image registry, ports, volumes |
| `infrastructure/` | Traefik's default TLS certificate, the runner controller's values |
| `runners/` | the scale set values (one file for every repository), the runner image, the Windows runner |
| `apps/hello/` | the smoke-test application |
| `tofu/` | modules for the repository variables and the DNS record, and an example root |
| `tools/` | the pinned tool installer and the WSL limits |
| `scripts/` | `scrub-check.sh` |
| `config.mk.example` | the values `make` reads from your `config.mk` |

## Licence

Apache-2.0, see [LICENSE](LICENSE).
