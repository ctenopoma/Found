#!/bin/bash
# AD ドメインへ参加し、ACL 付きの検証用共有フォルダ/ファイルを用意する。
set -e

DOMAIN="${DOMAIN:-POC.LOCAL}"
NETBIOS="${DOMAIN_NETBIOS:-POC}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Passw0rd!}"
DC_HOST="${DC_HOST:-dc1.poc.local}"
REALM_LOWER="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')"

# Kerberos 設定 (時刻同期前提。検証B の留意点)
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${DOMAIN}
    dns_lookup_realm = false
    dns_lookup_kdc = true
EOF

echo "[fileserver] waiting for DC ${DC_HOST} ..."
for i in $(seq 1 30); do
  if host "${DC_HOST}" >/dev/null 2>&1; then break; fi
  sleep 3
done

if [ ! -f /var/lib/samba/.joined ]; then
  echo "[fileserver] joining domain ${DOMAIN} ..."
  echo "${ADMIN_PASSWORD}" | net ads join -U Administrator --no-dns-updates || {
    echo "[fileserver] join failed — DC 起動完了を待って再起動してください"; exit 1; }
  touch /var/lib/samba/.joined
fi

# --- 検証A 用: 案件フォルダと ACL の出し分け ---
#   sales_case : grp_sales のみ読める (alice OK / bob NG)
#   eng_case   : grp_eng   のみ読める (bob OK / alice NG)
mkdir -p /srv/share/sales_case /srv/share/eng_case
echo "sales project document - quote and contract" > /srv/share/sales_case/quote.txt
echo "engineering design spec and drawings"        > /srv/share/eng_case/design.txt

# NTFS 互換 ACL を付与 (継承 ACL を検証B のクロールで取得できるか確認する)
setfacl -R -m group:grp_sales:rx /srv/share/sales_case || true
setfacl -R -m group:grp_eng:rx   /srv/share/eng_case   || true
# 既定の other を拒否
chmod -R 750 /srv/share/sales_case /srv/share/eng_case || true

echo "[fileserver] starting winbind + smbd ..."
winbindd
exec smbd --foreground --no-process-group --debuglevel=1
