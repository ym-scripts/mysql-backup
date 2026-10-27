# mysql-backup

[![CI](https://github.com/ym-scripts/mysql-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/ym-scripts/mysql-backup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Back up a MySQL or MariaDB database on a schedule and restore it with one command.** Backups go to a local folder and, optionally, to S3 or any S3-compatible storage (Cloudflare R2, Backblaze B2, MinIO). Old backups are deleted automatically.

```bash
npx github:ym-scripts/mysql-backup --url "$DATABASE_URL" --keep 14 --s3 s3://my-bucket/db
```

It's a single bash script. Every backup is:

- **checked** before it's kept: the gzip must be valid and the dump must end with mysqldump's `Dump completed` marker,
- **checksummed** (a `.sha256` file is stored next to it and verified before any restore),
- **written atomically**, so a failed run never leaves a half-written file that looks like a backup,
- **locked**, so two cron runs can't overlap.

## Requirements

- bash 3.2+ (macOS's bash is fine), `gzip`
- The MySQL or MariaDB client (`mysqldump`/`mysql`, or `mariadb-dump`/`mariadb`)
  - macOS: `brew install mysql-client` (or use the one that comes with Herd, DBngin or MySQL)
  - Debian/Ubuntu: `sudo apt install mysql-client` or `mariadb-client`
- For S3: the [AWS CLI](https://aws.amazon.com/cli/) with credentials (`aws configure`, or the `AWS_*` environment variables)

## Usage

```bash
mysql-backup [backup] [options]          # create a backup (default)
mysql-backup list [options]              # list backups, oldest first
mysql-backup prune [options]             # apply --keep without backing up
mysql-backup restore FILE [options]      # restore a local file or s3:// URI
```

Run it without installing:

```bash
npx github:ym-scripts/mysql-backup --help
curl -fsSL https://raw.githubusercontent.com/ym-scripts/mysql-backup/main/mysql-backup.sh | bash -s -- --help
```

Or install it as a command:

```bash
curl -fsSL https://raw.githubusercontent.com/ym-scripts/mysql-backup/main/mysql-backup.sh -o ~/.local/bin/mysql-backup
chmod +x ~/.local/bin/mysql-backup
```

### Options

| Option              | Env var              | Default       | Description                                                                                           |
| ------------------- | -------------------- | ------------- | ----------------------------------------------------------------------------------------------------- |
| `-u`, `--url URL`   | `DATABASE_URL`       |               | `mysql://user:pass@host:3306/db?ssl-mode=required`                                                    |
| `-d`, `--dir DIR`   | `BACKUP_DIR`         | `./backups`   | Local backup folder                                                                                   |
| `-k`, `--keep N`    | `BACKUP_KEEP`        | `7`           | Keep the newest N backups. `0` keeps everything.                                                      |
| `--name NAME`       |                      | database name | File name prefix                                                                                      |
| `--s3 URI`          | `BACKUP_S3`          |               | Also upload to `s3://bucket/prefix`                                                                   |
| `--s3-endpoint URL` | `BACKUP_S3_ENDPOINT` |               | Endpoint for S3-compatible storage                                                                    |
| `--s3-only`         |                      |               | Delete the local copy after a successful upload                                                       |
| `--ping URL`        | `BACKUP_PING_URL`    |               | Request `URL` on success and `URL/fail` on failure ([Healthchecks.io](https://healthchecks.io) style) |
| `-y`, `--yes`       |                      |               | `restore`: skip the typed confirmation                                                                |
| `-q`, `--quiet`     |                      |               | Only print errors and the backup path                                                                 |

The credentials are written to a private (`chmod 600`) temporary option file passed with `--defaults-extra-file`, so the password never appears in the process list. The file is deleted when the script exits. If the URL has no password, your `~/.my.cnf` is used.

Dumps use `--single-transaction --quick --routines --triggers --no-tablespaces --hex-blob` and `utf8mb4`. This gives a consistent snapshot of InnoDB tables without locking them, and works without the `PROCESS` privilege that managed databases often don't grant.

Backups are named `<name>_<UTC timestamp>.sql.gz`, for example `shop_20261027-020000.sql.gz`. The full path is printed on stdout, so you can capture it with `file=$(mysql-backup ...)`.

### Exit codes

| Code | Meaning                                                                 |
| ---- | ----------------------------------------------------------------------- |
| `0`  | Success                                                                 |
| `1`  | Backup, upload or restore failed, or the restore was cancelled          |
| `2`  | Usage or setup error (bad option, missing tool, no terminal to confirm) |

## Restoring

```bash
mysql-backup list --dir ./backups --url "$DATABASE_URL"
mysql-backup restore ./backups/shop_20261027-020000.sql.gz --url "$TARGET_URL"
mysql-backup restore s3://my-bucket/db/shop_20261027-020000.sql.gz --url "$TARGET_URL"
```

You'll be asked to type the target database name. The dump is piped into `mysql` and stops at the first error. Each table in the dump is dropped and recreated (`DROP TABLE IF EXISTS`). Tables in the target that aren't in the backup are left alone.

**Test your restores.** A backup you've never restored is a hope, not a backup. Restore into a scratch database every so often.

## Scheduling

**cron** (daily at 02:00, keep two weeks, upload to R2):

```cron
0 2 * * * DATABASE_URL='mysql://…' AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… /home/me/.local/bin/mysql-backup -q --dir /var/backups/mysql --keep 14 --s3 s3://backups/mysql --s3-endpoint https://<account>.r2.cloudflarestorage.com --ping https://hc-ping.com/<uuid> >> /var/log/mysql-backup.log 2>&1
```

**GitHub Actions:**

```yaml
on:
  schedule: [{ cron: "0 2 * * *" }]
  workflow_dispatch:
jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - run: sudo apt-get install -y mysql-client
      - run: npx -y github:ym-scripts/mysql-backup#v0.1.0 --s3-only --s3 s3://my-bucket/db --keep 30
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          AWS_DEFAULT_REGION: us-east-1
```

## Laravel

Point it at your app's database with the same values as your `.env`:

```bash
set -a; . ./.env; set +a
mysql-backup --url "mysql://$DB_USERNAME:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_DATABASE" --dir storage/backups
```

URL-encode special characters in the password (`@` → `%40`, `/` → `%2F`, `:` → `%3A`).

## Security notes

- Backups contain all your data. Use a private bucket with encryption at rest, and restrict who can read it.
- Prefer environment variables or a `.env` file with `chmod 600` to putting the URL in your crontab.
- Use a read-only database role for backups if your provider supports one.

## Development

```bash
bash test/run.sh     # 50 checks against fake mysqldump/mysql/aws/curl, no database needed
```

CI also runs a real backup and restore against MySQL 8.4 and MariaDB 11.

## License

[MIT](LICENSE) © Aghogho Meyoron
