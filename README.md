# vps-infra
nginx and certbot for the static sites on the DigitalOcean VPS.

One nginx container serves every site straight from disk, picking the site by hostname (`server_name`). certbot renews the Let's Encrypt certificates every 12 hours, and nginx reloads every 6 hours to pick them up. Both containers use `restart: unless-stopped`, so they come back on their own after a reboot.

## Layout on the VPS

```
~/sites/                    ← this repo
├── docker-compose.yml
├── nginx/conf.d/           ← one .conf per site, plus shared settings
├── certbot/                ← gitignored; Let's Encrypt account and certs
│   ├── conf/
│   └── www/
└── www/                    ← gitignored; one clone per site repo
    ├── rastahorn.com/      ← github.com/dykno/rastahorn.com
    └── withani.net/        ← github.com/dykno/withani.net
```

Each site repo keeps its public files in its own `www/` folder, so nginx's root for a site is `/srv/<site>/www`.

## First-time setup

```bash
git clone git@github.com:dykno/vps-infra.git ~/sites
cd ~/sites
git clone git@github.com:dykno/rastahorn.com.git www/rastahorn.com
git clone git@github.com:dykno/withani.net.git www/withani.net
# Restore certbot/conf from a backup (keep file permissions)
docker compose run --rm --no-deps nginx nginx -t
docker compose up -d
```

## Everyday tasks

**Update a site's content:** `git pull` inside `www/<site>`. Live immediately.

**Change nginx config:** `git pull` here, then:

```bash
docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload
```

**Check certificates:**

```bash
docker compose exec certbot certbot certificates
docker compose exec certbot certbot renew --dry-run
```

**Logs:** `docker compose logs -f nginx` (rotated at 10 MB, 3 files kept).

## Adding a site
1. Create the site repo with its public files in `www/`, then clone it into `~/sites/www/newsite.com`.
2. Add `nginx/conf.d/newsite.com.conf` with **only** the port 80 server block (the ACME challenge location plus the HTTPS redirect). Reload nginx.
3. Issue the certificate:
   ```bash
   docker compose exec certbot certbot certonly --webroot -w /var/www/certbot -d newsite.com -d www.newsite.com
   ```
4. Add the 443 server block (copy `withani.net.conf`), commit, pull on the VPS, and reload nginx.

If a site ever needs a backend (an app server or database), run it in its own Compose project on a shared Docker network and `proxy_pass` to it from that site's conf. Use `resolver 127.0.0.11 valid=10s;` with a variable (`set $backend http://app:3000; proxy_pass $backend;`) rather than an `upstream` block, so nginx still starts when that app is down.
