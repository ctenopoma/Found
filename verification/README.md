# PoC 検証環境

`docs/pre-verification.md` の**検証A / B / C** を Linux + コンテナだけで再現するための環境。
本番の Windows AD / ファイルサーバを用意する前に、Fess の権限フィルタが成立するかを最短で確かめる。

## 構成

| サービス | 役割 | 公開ポート |
|---|---|---|
| `samba-ad` | テスト用 AD ドメインコントローラ (`POC.LOCAL`) | 389 / 636 / 88 |
| `fileserver` | AD 参加の SMB ファイルサーバ。ACL 付き共有 `\\fs1\share` | 445 |
| `opensearch` | Fess のインデックスストア | (内部) |
| `fess` | クロール + 全文検索 + 権限フィルタ | 8080 |

### テスト用 AD アカウント

| ユーザー | パスワード | グループ | 見えるべき共有 |
|---|---|---|---|
| `alice` | `Alice#2026` | `grp_sales` | `sales_case` のみ |
| `bob` | `Bob#2026` | `grp_eng` | `eng_case` のみ |
| `svc_fess` | `Svc#Fess2026` | 両方 | クロール用サービスアカウント |

→ **検証A の合格基準**：alice の検索では `quote.txt` だけ、bob の検索では `design.txt` だけがヒットすること。

## 起動

```bash
cd verification
docker compose up -d --build

# DC の provision とドメイン参加が完了するまで初回は数分かかる
docker compose logs -f samba-ad fileserver
```

## 検証手順

### 検証B: Linux → SMB アクセス
```bash
# fileserver がドメイン参加できたか
docker compose exec fileserver net ads testjoin
# サービスアカウントで共有を一覧
docker compose exec fileserver smbclient -L //fs1.poc.local -U 'svc_fess%Svc#Fess2026'
```

### 検証C: LDAP 認証 / グループ取得（オンプレAD前提）
```bash
# LDAP bind とグループ所属(memberOf)の取得 — アプリ/Fess の認証もこの経路
docker compose exec samba-ad ldapsearch -x -H ldap://localhost \
  -D 'svc_fess@poc.local' -w 'Svc#Fess2026' \
  -b 'dc=poc,dc=local' '(sAMAccountName=alice)' memberOf

# 参考: samba-tool / winbind での確認
docker compose exec samba-ad samba-tool user list
docker compose exec samba-ad samba-tool group listmembers grp_sales
docker compose exec fileserver wbinfo --user-groups=alice
```

> Fess 側は **管理画面 > 全般 > LDAP** に `ldap://dc1.poc.local`、ベース DN
> `dc=poc,dc=local`、バインド用 `svc_fess@poc.local` を設定して LDAP 認証を有効化する。

### 検証A: Fess の ACL 取得 + 権限フィルタ 〔最重要〕
1. `http://localhost:8080/admin` (初期 admin/admin) で管理画面へログイン
2. **クローラ > ファイルシステム** に以下を登録
   - パス: `smb://svc_fess:Svc%23Fess2026@fs1.poc.local/share/`
   - ※ Fess の SMB クローラは `jcifs` ベース。認証情報とパーミッション取得を有効化
3. **権限の取得を有効化**（ファイル ACL → ロール/ラベルへのマッピング設定）
4. クロール実行 → インデックス確認
5. Fess の認証連携（LDAP/AD）を設定し、alice / bob でログインして検索結果が出し分けされるか確認

> Fess 側の SMB-ACL→ロール変換と LDAP 認証は GUI 設定。詳細は
> https://fess.codelibs.org/14.0/admin/fileconfig-guide.html を参照。
> 本 PoC の主目的は「この出し分けが実際に再現できるか」を判定すること。

## 注意・既知の制約

- **時刻同期**：Kerberos は時刻ズレに敏感。ホストの時刻がずれていると参加・認証に失敗する。
- **privileged**：Samba AD DC / メンバーはコンテナ内で多数のサービスを動かすため `privileged: true` が必要。
- **ポート445**：ホストの 445 を SMB で使うため、Windows 環境では既存の SMB と衝突しうる。
  衝突する場合は compose の `fileserver.ports` を `1445:445` 等に変更する。
- **イメージタグ**：Fess / OpenSearch のタグは環境に合わせて更新すること（compose 冒頭参照）。
- 本環境は**検証専用**。本番 AD・本番共有では使用しない。

## クリーンアップ
```bash
docker compose down -v
```
