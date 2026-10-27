#!/usr/bin/env bash
# Tests mysql-backup.sh with fake mysqldump/mysql/aws/curl on PATH.
set -uo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK:?}"' EXIT
export PATH="$PWD/test/bin:$PATH" STUB_LOG="$WORK/log" FAKE_S3="$WORK/s3" NO_COLOR=1
unset DATABASE_URL BACKUP_DIR BACKUP_KEEP BACKUP_S3 BACKUP_S3_ENDPOINT BACKUP_PING_URL
URL='mysql://app:p%40ss%22w@db.example.com:3307/shop?ssl-mode=required'
pass=0 fail=0

t() { # t NAME EXPECTED_EXIT -- ARGS...
    local name="$1" want="$2"; shift 3
    : > "$STUB_LOG"
    out=$(./mysql-backup.sh "$@" 2>&1 </dev/null); code=$?
    if [ "$code" = "$want" ]; then pass=$((pass + 1)); echo "ok   $name"
    else fail=$((fail + 1)); echo "FAIL $name (exit $code, want $want)"; echo "$out" | sed 's/^/     /'; fi
}
check() { if eval "$1"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL   $1"; fi; }
has()   { check "grep -qF -- '$1' <<< \"\$out\""; }
logged(){ check "grep -qF -- '$1' \"\$STUB_LOG\""; }
count() { find "$1" -name "$2" 2>/dev/null | wc -l | tr -d ' '; }

D="$WORK/b"
t "help" 0 -- --help;                          has "Usage:"
t "version" 0 -- --version
t "unknown option" 2 -- --nope
t "unknown command" 2 -- explode
t "bad keep" 2 -- --keep x --url "$URL"
t "no url" 2 -- --dir "$D"
t "bad url" 2 -- --url postgres://x@y/z
t "s3-only needs s3" 2 -- --s3-only --url "$URL"

t "backup (custom)" 0 -- --url "$URL" --dir "$D"
logged 'cnf: [client] host="db.example.com" port=3307 user="app" password="p@ss\"w" ssl-mode=REQUIRED'
logged "mysqldump --defaults-extra-file="
check '! grep -q "p@ss" <(grep -v "^cnf:" "$STUB_LOG")'   # password never on a command line
check '[ "$(count "$D" "shop_*.sql.gz")" = 1 ] && [ "$(count "$D" "shop_*.sql.gz.sha256")" = 1 ]'
check '[ "$(count "$D" ".*partial")" = 0 ] && [ ! -d "$D/.shop.lock" ]'
check '[ "$(tail -1 <<< "$out")" = "$(ls "$D"/shop_*.sql.gz)" ]'

DATABASE_URL="$URL" t "backup from DATABASE_URL, --opt=value" 0 -- --dir="$D" --name=other
check '[ "$(count "$D" "other_*.sql.gz")" = 1 ]'

FAIL_MYSQLDUMP=1 t "failed dump writes nothing" 1 -- --url "$URL" --dir "$WORK/f" --ping https://hc.example/x
check '[ "$(find "$WORK/f" -type f | wc -l | tr -d " ")" = 0 ]'
logged "curl -fsS -m 10 --retry 3 -o /dev/null https://hc.example/x/fail"

mkdir "$D/.shop.lock"
t "concurrent run is refused" 1 -- --url "$URL" --dir "$D";  has "Another backup"
rmdir "$D/.shop.lock"

for ts in 20250101-000000 20250102-000000 20250103-000000 20250104-000000; do
    : > "$D/shop_$ts.sql.gz"; : > "$D/shop_$ts.sql.gz.sha256"
done
t "retention keeps newest N" 0 -- --url "$URL" --dir "$D" --keep 2
check '[ "$(count "$D" "shop_*.sql.gz")" = 2 ] && [ "$(count "$D" "shop_2025010[1-3]-*")" = 0 ]'
check '[ "$(count "$D" "other_*.sql.gz")" = 1 ]'      # other names untouched

t "s3 upload, prune and ping" 0 -- --url "$URL" --dir "$D" --keep 1 --s3 s3://bkt/pg/ --s3-endpoint https://r2.example --ping https://hc.example/x
logged "aws --endpoint-url https://r2.example s3 cp"
check '[ "$(count "$FAKE_S3/bkt/pg" "shop_*.sql.gz")" = 1 ] && [ "$(count "$FAKE_S3/bkt/pg" "shop_*.sql.gz.sha256")" = 1 ]'
logged "curl -fsS -m 10 --retry 3 -o /dev/null https://hc.example/x |"

FAIL_AWS=1 t "failed upload keeps local copy" 1 -- --url "$URL" --dir "$WORK/u" --s3 s3://bkt/pg --s3-only
has "local backup was kept"
check '[ "$(count "$WORK/u" "shop_*.sql.gz")" = 1 ]'

t "s3-only removes local copy" 0 -- --url "$URL" --dir "$WORK/o" --s3 s3://bkt/only --s3-only
check '[ "$(count "$WORK/o" "shop_*")" = 0 ]'; has "s3://bkt/only/shop_"

t "list" 0 -- list --dir "$D" --url "$URL";        has "shop_"
t "prune needs a name" 2 -- prune --dir "$D"
t "prune --keep 1" 0 -- prune --dir "$D" --name shop --keep 1
check '[ "$(count "$D" "shop_*.sql.gz")" = 1 ]'

F=$(ls "$D"/shop_*.sql.gz | tail -1)
t "restore needs confirmation without a tty" 2 -- restore "$F" --url "$URL"
t "restore --yes" 0 -- restore "$F" --url "$URL" --yes
logged "mysql --defaults-extra-file="
echo corrupt >> "$F"
t "restore rejects bad checksum" 1 -- restore "$F" --url "$URL" --yes;  has "Checksum mismatch"
S=$(find "$FAKE_S3/bkt/only" -name 'shop_*.sql.gz' | head -1)
t "restore from s3" 0 -- restore "s3://bkt/only/$(basename "$S")" --url "$URL" --yes
has "checksum OK"
G=$(ls "$D"/other_*.sql.gz | head -1)
t "restore another backup" 0 -- restore "$G" --url "$URL" -y
FAIL_MYSQL=1 t "restore failure exits 1" 1 -- restore "$S" --url "$URL" -y 2>/dev/null

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
