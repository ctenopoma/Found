#!/bin/bash
# Samba AD ドメインコントローラの provision とテストユーザー/グループ作成。
set -e

DOMAIN="${DOMAIN:-POC.LOCAL}"
NETBIOS="${DOMAIN_NETBIOS:-POC}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Passw0rd!}"
REALM_LOWER="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')"

if [ ! -f /var/lib/samba/.provisioned ]; then
  echo "[samba-ad] provisioning domain ${DOMAIN} ..."
  rm -f /etc/samba/smb.conf

  samba-tool domain provision \
    --use-rfc2307 \
    --realm="${DOMAIN}" \
    --domain="${NETBIOS}" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass="${ADMIN_PASSWORD}"

  cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

  # --- テストユーザー / グループ (検証A の権限出し分け用) ---
  # alice -> grp_sales,  bob -> grp_eng
  export SAMBA_ADMIN_PASS="${ADMIN_PASSWORD}"
  samba-tool group add grp_sales
  samba-tool group add grp_eng
  samba-tool user create alice 'Alice#2026' --given-name=Alice --surname=Sales
  samba-tool user create bob   'Bob#2026'   --given-name=Bob   --surname=Eng
  samba-tool group addmembers grp_sales alice
  samba-tool group addmembers grp_eng   bob

  # クロール用サービスアカウント (検証B)
  samba-tool user create svc_fess 'Svc#Fess2026'
  samba-tool group addmembers grp_sales svc_fess
  samba-tool group addmembers grp_eng   svc_fess

  touch /var/lib/samba/.provisioned
  echo "[samba-ad] provision done. users: alice/bob/svc_fess  groups: grp_sales/grp_eng"
fi

cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf || true
echo "[samba-ad] starting samba ..."
exec samba -i --debuglevel=1
