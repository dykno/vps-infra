# Migration runbook: speedtrap gateway → vps-infra

This is a one-time runbook. It replaces the old setup (the speedtrap.io gateway stack plus the rastahorn-docker and withani-docker stacks) with this repo.

**Downtime:** about a minute, during [Part 4](#part-4-cutover). Everything before that happens while the old sites keep running.

**Rollback:** possible at any point, as long as you haven't done [Part 7](#part-7-clean-up-after-a-week) yet. Nothing in Parts 1–5 modifies the old folders. They're only read and copied.

> Commands assume you SSH in as a user that can run `docker` and `sudo`. If you log in as root, the `sudo` prefixes are harmless.

---

## Part 0: On your laptop, before you SSH in

1. Create an empty `dykno/vps-infra` repo on GitHub, then push everything:
   ```bash
   cd ~/Git/vps-infra && git remote add origin git@github.com:dykno/vps-infra.git && git push -u origin main
   ```
   ```bash
   cd ~/Git/rastahorn.com && git push -u origin static-migration
   ```
   ```bash
   cd ~/Git/withani.net && git push -u origin static-migration
   ```
2. Don't merge the `static-migration` branches yet. `master` stays as the old version until the cutover is verified ([Part 6](#part-6-finish-up)).

---

## Part 1: Pre-flight checks (read-only)

### 1.1 Find the old project folders

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project.working_dir"}}'
```

Write the three folders into shell variables for this session. You'll need them throughout, so if you reconnect, set them again.

```bash
OLD_ST=/path/to/speedtrap.io/speedtrap-web-services   # api-gateway, certbot, py-mongo-*, speedtest-db
OLD_RH=/path/to/rastahorn                             # rastahorn-web, rastahorn-php
OLD_WA=/path/to/withani                               # withani-web
```

### 1.2 Tools and disk space

```bash
docker compose version     # need Compose v2 ("docker compose", not "docker-compose")
git --version
df -h ~                    # need room for the backup tarball (roughly the size of the three folders)
sudo du -sh "$OLD_ST" "$OLD_RH" "$OLD_WA"
```

- **If `docker compose` doesn't exist:** install the plugin with `sudo apt-get install docker-compose-plugin`.
- **If the VPS can't clone over SSH:** either clone over `https://` (public repos only) or add a deploy key.

### 1.3 Make sure the new setup won't drop any hostnames

List every hostname the current gateway serves:

```bash
docker exec api-gateway nginx -T 2>/dev/null | grep -E '^\s*server_name' | sort -u
```

You should see only `speedtrap.io`, `api.speedtrap.io`, `rastahorn.com` and `withani.net` (plus their `www.` versions).

**Stop here if anything else shows up** (for example `enduro.rastahorn.com`). It isn't in vps-infra yet, so add a conf for it first.

### 1.4 Check the certificates

```bash
sudo ls "$OLD_ST/data/certbot/conf/renewal/"
sudo grep -H -E '^(authenticator|webroot_path)' "$OLD_ST"/data/certbot/conf/renewal/*.conf
docker exec certbot certbot certificates
```

You should see:
- renewal configs for `rastahorn.com.conf`, `withani.net.conf` and `speedtrap.io.conf`
- all of them using `authenticator = webroot` with `webroot_path = /var/www/certbot`. The new setup uses that same path, so renewals keep working without any changes.

Note the expiry dates. **If any certificate expires within the next few days, renew it first** (`docker exec certbot certbot renew`) and don't cut over during the renewal.

### 1.5 Check for host-level automation

```bash
crontab -l; sudo crontab -l; ls /etc/cron.d
systemctl list-unit-files --state=enabled | grep -i -E 'docker|compose|speedtrap|rastahorn|withani'
```

Look for anything that references the old folders, such as a cron job or systemd unit that starts the stacks. Note it down; it gets removed in [Part 7](#part-7-clean-up-after-a-week).

Also confirm Docker itself starts at boot:

```bash
systemctl is-enabled docker
```

This must print `enabled`. If it doesn't, run `sudo systemctl enable docker`.

---

## Part 2: Back up everything

```bash
STAMP=$(date +%F)
sudo tar czf ~/pre-migration-$STAMP.tgz "$OLD_ST" "$OLD_RH" "$OLD_WA"
ls -lh ~/pre-migration-$STAMP.tgz
```

The tarball includes the certbot account and certificates, the Docker secrets and the Mongo data files.

**Optional:** make a readable export of the speedtrap Mongo data while the database is still running:

```bash
docker exec speedtest-db sh -c 'mongodump --username "$(cat /run/secrets/speedtest-db_root_username)" --password "$(cat /run/secrets/speedtest-db_root_password)" --authenticationDatabase admin --archive' > ~/speedtrap-mongo-$STAMP.archive
ls -lh ~/speedtrap-mongo-$STAMP.archive
```

**Copy the backups off the VPS.** Run this from your laptop:

```bash
scp 'vps:~/pre-migration-*.tgz' 'vps:~/speedtrap-mongo-*.archive' ~/Backups/
```

---

## Part 3: Build the new setup next to the old one

The old containers keep serving traffic throughout this part.

### 3.1 Clone the repos

```bash
git clone git@github.com:dykno/vps-infra.git ~/sites
git clone git@github.com:dykno/rastahorn.com.git ~/sites/www/rastahorn.com
git clone git@github.com:dykno/withani.net.git ~/sites/www/withani.net
```

These clone `master`, the old version, on purpose: you compare against it in the next step.

### 3.2 Find live edits that never made it into git

First, find which folders the running site containers serve from:

```bash
for c in rastahorn-web rastahorn-php withani-web; do echo "== $c"; docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' $c; done
```

Then copy the files that are actually live out of the containers. This works whether the files are bind-mounted or built into the image:

```bash
rm -rf /tmp/live && mkdir -p /tmp/live
docker cp rastahorn-php:/var/www /tmp/live/rastahorn
docker cp withani-web:/var/www /tmp/live/withani
diff -rq -x .DS_Store /tmp/live/rastahorn ~/sites/www/rastahorn.com/www
diff -rq -x .DS_Store /tmp/live/withani  ~/sites/www/withani.net/www
```

How to read the output:
- **"Only in /tmp/live/…" or "Files … differ":** something exists only on the server. Use `diff` on that file to see the change, then commit it to the site repo (on your laptop, on the `static-migration` branch) before going further. For a `.php` page, apply the change to the matching `.html` page instead.
- **`license.txt`** showing up only in the live rastahorn copy is expected. It now sits at the repo root.
- **`uploads/` in withani is expected too.** It holds the resume PDF and isn't tracked in git. Copy it over:
  ```bash
  cp -a /tmp/live/withani/uploads ~/sites/www/withani.net/www/
  ls ~/sites/www/withani.net/www/uploads/
  ```

If nothing shows up in `/tmp/live/withani/uploads`, look for the file on disk with `sudo find / -name 'matthiew_morin_resume.pdf' 2>/dev/null`. If it doesn't exist anywhere, the Resume link is already broken today. Fix that separately.

### 3.3 Switch the site clones to the new branch

```bash
git -C ~/sites/www/rastahorn.com checkout static-migration
git -C ~/sites/www/withani.net checkout static-migration
git -C ~/sites/www/rastahorn.com log --oneline -1
git -C ~/sites/www/withani.net log --oneline -1
```

If you committed fixes in 3.2, `git pull` in each clone after pushing them from your laptop.

### 3.4 Copy the certificates and drop speedtrap's

```bash
sudo cp -a "$OLD_ST/data/certbot" ~/sites/certbot
sudo rm -rf ~/sites/certbot/conf/renewal/speedtrap.io.conf ~/sites/certbot/conf/live/speedtrap.io ~/sites/certbot/conf/archive/speedtrap.io
sudo ls -l ~/sites/certbot/conf/live/rastahorn.com/
```

`cp -a` matters here. The files under `live/` are symlinks into `archive/`, and `-a` keeps them as symlinks with their permissions.

### 3.5 Test the new config without starting it

```bash
cd ~/sites
docker compose pull
docker compose run --rm --no-deps nginx nginx -t
docker compose run --rm --no-deps --entrypoint certbot certbot certificates
```

`run` doesn't publish ports, so this doesn't clash with the running gateway.

What to expect:
- `nginx -t` prints **"syntax is ok"** and **"test is successful"**.
- `certificates` lists **only** `rastahorn.com` and `withani.net`.

**Don't continue until both checks pass.**

---

## Part 4: Cutover

Run these back to back. Downtime starts at the first command and ends when the second finishes.

```bash
cd "$OLD_ST" && docker compose down
cd ~/sites && docker compose up -d
```

Then stop the old site containers. Nothing routes to them anymore.

```bash
cd "$OLD_RH" && docker compose down
cd "$OLD_WA" && docker compose down
```

Confirm only the new containers are running:

```bash
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
cd ~/sites && docker compose logs --tail 20 nginx
```

You should see `sites-nginx-1` and `sites-certbot-1`, both `Up`, with nginx bound to `0.0.0.0:80` and `:443`. The nginx log should show no `[emerg]` lines.

**If nginx isn't up, roll back now** ([Part 8](#part-8-rollback)) and debug afterward.

---

## Part 5: Verify

### 5.1 From the VPS

```bash
for u in http://rastahorn.com/ https://rastahorn.com/ https://www.rastahorn.com/ https://rastahorn.com/index.php https://rastahorn.com/board.php https://rastahorn.com/td4w/ https://rastahorn.com/tdfw/ https://rastahorn.com/kickball/teams.php https://rastahorn.com/kickball/images/home.jpg https://rastahorn.com/privacy/ https://rastahorn.com/support/ https://rastahorn.com/warzone/ http://withani.net/ https://withani.net/ https://www.withani.net/ https://withani.net/uploads/matthiew_morin_resume.pdf; do
  printf '%-55s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$u")"
done
```

Expected:
| URL | Result |
|---|---|
| `http://…` | `301` to `https://…` |
| `/tdfw/` | `301` to `/td4w/` |
| everything else | `200` |

Check the iOS redirect, and make sure the privacy and support pages are not redirected:

```bash
IOS='Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)'
for u in https://rastahorn.com/ https://rastahorn.com/board.php https://rastahorn.com/td4w/ https://rastahorn.com/privacy/ https://rastahorn.com/support/; do
  printf '%-40s %s\n' "$u" "$(curl -s -A "$IOS" -o /dev/null -w '%{http_code} %{redirect_url}' "$u")"
done
```

Expected: the first three return `302` to `apps.apple.com`. `/privacy/` and `/support/` return `200`.

Check the certificates being served, and that renewal works end to end:

```bash
for d in rastahorn.com withani.net; do echo | openssl s_client -connect $d:443 -servername $d 2>/dev/null | openssl x509 -noout -subject -enddate; done
cd ~/sites && docker compose exec certbot certbot renew --dry-run
```

Expected: each subject matches its domain, and the dry run ends with **"Congratulations, all simulated renewals succeeded"**.

### 5.2 From a browser (laptop and phone)

- [ ] rastahorn.com: the horn plays, and so do `/board.html`, `/td4w/` and `/warzone/`.
- [ ] Every kickball page: the header image and nav highlight load, and the Home, League Info and Schedule images show.
- [ ] On an iPhone, rastahorn.com opens the App Store, while `rastahorn.com/privacy/` and `/support/` load normally.
- [ ] withani.net: the fonts and background images load, and the Resume link opens the PDF.

### 5.3 Reboot test

This is the problem the whole migration is meant to fix, so test it directly:

```bash
sudo reboot
```

After a minute, SSH back in and check:

```bash
docker ps --format '{{.Names}}\t{{.Status}}'
curl -s -o /dev/null -w '%{http_code}\n' https://rastahorn.com/ https://withani.net/
```

Both containers should be `Up` and both sites should return `200`, without you doing anything.

---

## Part 6: Finish up

Once everything in Part 5 passes, do this on your laptop:

```bash
cd ~/Git/rastahorn.com && git checkout master && git merge --ff-only static-migration && git push && git push origin --delete static-migration develop
```
```bash
cd ~/Git/withani.net && git checkout master && git merge --ff-only static-migration && git push && git push origin --delete static-migration
```

Then on the VPS:

```bash
git -C ~/sites/www/rastahorn.com checkout master && git -C ~/sites/www/rastahorn.com pull
git -C ~/sites/www/withani.net checkout master && git -C ~/sites/www/withani.net pull
```

---

## Part 7: Clean up (after a week)

Only do this once you're confident you won't roll back.

```bash
docker network rm internal-network
docker image prune -a          # removes old mongo, python, php:7-fpm and the custom-built images
sudo rm -rf "$OLD_ST" "$OLD_RH" "$OLD_WA"   # the tarball from Part 2 is your copy
rm -rf /tmp/live
```

Then:
- Remove any cron jobs or systemd units you found in step 1.5.
- In DNS, delete the `speedtrap.io`, `www.speedtrap.io` and `api.speedtrap.io` records, or let the domain lapse.
- Archive `dykno/speedtrap.io` on GitHub.
- On your laptop, delete `~/Git/rastahorn-docker` and `~/Git/withani-docker`.

---

## Part 8: Rollback

Use this any time before Part 7. The old folders were never modified, so bringing them back up restores the old setup exactly.

```bash
cd ~/sites && docker compose down
cd "$OLD_WA" && docker compose up -d
cd "$OLD_RH" && docker compose up -d
cd "$OLD_ST" && docker compose up -d
docker ps --format '{{.Names}}\t{{.Status}}'
```

The order matters: withani, then rastahorn, then speedtrap. The old gateway exits on startup if the site containers aren't up yet.

The old certificates are still valid even if the new certbot renewed copies in the meantime. Let's Encrypt doesn't revoke a certificate when you renew it.
