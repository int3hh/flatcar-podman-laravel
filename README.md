# Flatcar + Podman Quadlets — Laravel stack

A Flatcar Container Linux VM that runs a Laravel app (PHP-FPM, Nginx, queue
workers, scheduler) plus PostgreSQL as **rootless Podman quadlets** under the
`symfony5` user. Application images are built in CI and shipped to the host with
`podman image scp`; the host starts and updates them automatically.

## Layout

```
flatcar/
├── flatcar_production_qemu.sh   # QEMU launcher (upstream Flatcar wrapper)
├── build.sh                     # config.bu -> config.ign (Butane)
├── config.bu                    # Butane source (edit this)
├── config.ign                   # compiled Ignition (generated; boot with this)
├── flatcar_fresh.img            # pristine image — boot THIS for first boot
├── flatcar_production_qemu_image.img  # already-booted working image
└── configs/                     # everything referenced by config.bu
    ├── symfony5.pub             # SSH pubkey for the symfony5 user
    ├── *.env                    # credentials / app + php config (mode 0600)
    ├── *.network *.volume       # quadlet networks & volumes
    ├── *.container              # quadlet services
    └── laravel-image-update.*   # auto-update path + service (user units)
```

## Build

```bash
./build.sh          # config.bu + configs/  ->  config.ign
```

`build.sh` uses a native `butane` if present, otherwise the `quay.io/coreos/butane`
container via `podman`. It always passes `--files-dir .` (required so the
`*_local` / `contents.local` references in `config.bu` resolve) and `--strict`.

> **Always edit `config.bu` and files in `configs/`, then rebuild.** Never edit
> `config.ign` by hand — it is overwritten.

## Boot

Ignition only runs on a **fresh first boot**, so boot the pristine image:

```bash
./flatcar_production_qemu.sh -I flatcar_fresh.img -i config.ign -f 8080:80
```

- SSH: `ssh -p 2222 symfony5@localhost`
- HTTP (nginx): `http://localhost:8080` (host 8080 → guest 80 via `-f 8080:80`)

The console auto-logs in as `core` (Flatcar's `flatcar.autologin` getty) — that
is unrelated to `symfony5`, which is SSH-key only.

## Architecture

- **Rootless** Podman under `symfony5` (UID 1000). Quadlets live in
  `/etc/containers/systemd/users/1000/` and are run by the per-user generator.
- **Linger** is enabled (`/var/lib/systemd/linger/symfony5`) so the user services
  start at boot without an active login.
- Nginx binds host ports 80/443 rootless via
  `net.ipv4.ip_unprivileged_port_start=80`.
- Two networks: `laravel-app` (nginx ↔ php) and `laravel-database` (php/workers ↔
  postgres). PostgreSQL publishes no host port (internal only).
- Containers resolve each other by name — the PHP container **must** be `php`
  (nginx config: `fastcgi_pass php:9000`); the DB **must** be `pgsql`
  (`DB_HOST=pgsql`).

### Services

| Unit (`systemctl --user`) | Image | Built by CI | Notes |
|---|---|---|---|
| `postgres.service` | `docker.io/library/postgres:18-alpine` | no | data on `systemd-pgdata` volume |
| `php.service` | `localhost/laravel-app:latest` | **yes** | PHP-FPM :9000, runs migrations (AUTORUN) |
| `nginx.service` | `localhost/laravel-nginx:latest` | **yes** | publishes 80/443 |
| `queue-default.service` | `localhost/laravel-app:latest` | **yes** | `queue:work --queue=default` |
| `queue-high.service` | `localhost/laravel-app:latest` | **yes** | `queue:work --queue=high` |
| `scheduler.service` | `localhost/laravel-app:latest` | **yes** | `schedule:work` |

## CI: shipping images with `podman image scp`

CI builds the images and copies them straight into `symfony5`'s rootless store.
**Image names must match the `Image=` in the quadlets exactly.**

One-time setup on the CI runner (defines the SSH connection):

```bash
podman system connection add flatcar ssh://symfony5@YOUR_HOST
```

Build and ship on each release:

```bash
# names must be localhost/laravel-app and localhost/laravel-nginx
podman build -t laravel-app:latest   -f .docker/php/Dockerfile   .
podman build -t laravel-nginx:latest -f .docker/nginx/Dockerfile .docker/nginx

podman image scp localhost/laravel-app:latest   flatcar::
podman image scp localhost/laravel-nginx:latest flatcar::
```

That's all CI does — no remote `systemctl` calls needed.

## How start + auto-update works (no manual restarts)

1. **First start / image not present yet.** Each CI service has `Restart=always`
   and `StartLimitIntervalSec=0`. Until its image exists the unit fails and
   retries every 10s forever; the first successful `podman image scp` makes the
   next retry succeed. Services come up on their own.
2. **Updates to a running service.** Each CI service has `AutoUpdate=local`. The
   user-level `laravel-image-update.path` watches the image store
   (`~/.local/share/containers/storage/overlay-images/images.json`), which
   `podman image scp` rewrites on every upload. That triggers
   `laravel-image-update.service` → `podman auto-update`, which restarts every
   container whose same-named local image changed onto the new image.

Manual trigger (equivalent to what the path unit does):

```bash
ssh -p 2222 symfony5@localhost 'systemctl --user start laravel-image-update.service'
# or:
ssh -p 2222 symfony5@localhost 'podman auto-update'
```

## Operating it

All container units are **user** units — use `systemctl --user` as `symfony5`:

```bash
systemctl --user list-units 'laravel*' 'postgres*' 'php*' 'nginx*' 'queue*' 'scheduler*'
systemctl --user status php.service
systemctl --user restart nginx.service
journalctl --user -u php.service -f
podman ps
podman images
```

Check linger / auto-update wiring:

```bash
loginctl show-user symfony5 | grep Linger        # Linger=yes
systemctl --user status laravel-image-update.path
```

## Configuration & secrets

- `configs/symfony5.pub` — authorized SSH key. Swap this file and rebuild to
  rotate access (this is the only file to touch for credential redeploys).
- `configs/postgres.env` — `POSTGRES_USER/PASSWORD/DB`. **Change the password.**
- `configs/laravel.env` — the Laravel app `.env`. Set `APP_KEY`
  (`php artisan key:generate --show`), `APP_ENV=production`, `APP_DEBUG=false`,
  and keep `DB_USERNAME/PASSWORD/DATABASE` matching `postgres.env`.
- `configs/php.env` — PHP/OPcache tuning + AUTORUN flags (workers override
  `AUTORUN_ENABLED=false` in their unit).

After any change: `./build.sh`, then redeploy onto a fresh image.

## Gotchas

- **Ignition runs once.** Editing configs only affects a *fresh* first boot, not
  an already-booted image. Re-provision from `flatcar_fresh.img`.
- **Image names matter.** `AutoUpdate=local` matches by image name; CI tags must
  be exactly `localhost/laravel-app:latest` / `localhost/laravel-nginx:latest`.
- **subuid/subgid.** Rootless Podman needs ranges for `symfony5`; Flatcar's
  `useradd` normally assigns them automatically. Verify once after first boot:
  `grep symfony5 /etc/subuid /etc/subgid`.
- **policy.json.** Podman refuses to pull/run any image without
  `/etc/containers/policy.json` ("no policy.json file found"). This image ships
  without one, so `config.bu` writes a permissive default (`configs/policy.json`).
- **`-I flatcar_fresh.img`** boots from the pristine copy; omit it and you boot
  the already-used image which won't re-run Ignition.
