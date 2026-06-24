# 事前検証計画 (PoC)

実装に着手する前に、設計の前提が成立するかを検証する。
優先度は「ここで詰まると設計全体が崩れる」順。**上から順に検証する。**

## 検証一覧と優先度

| ID | 検証内容 | リスク | 依存 | 合否の一言基準 |
|---|---|---|---|---|
| **A** | Fess が SMB の ACL を取得し AD 権限で検索フィルタできるか | **最大** | B, C | alice/bob で検索結果が出し分けされる |
| B | Linux(Fess) → Windows SMB への認証アクセス | 大 | — | サービスアカウントで共有のファイルを読める |
| C | LDAP 認証とグループ取得（オンプレAD） | 大 | — | bind 成功し memberOf が取れる |
| D | アプリサーバ(Linux) → SMB へのフォルダ書き込みと ACL 継承 | 中 | B | テンプレ通りに ACL 付きフォルダを作れる |
| E | Fess REST API 連携（クロール登録・起動・検索） | 中 | B | API でクロール起動と検索ができる |
| F | Tauri 実現性（認証・配布・署名） | 小（後回し可） | C | 内蔵 WebView で認証フローが回る |

### 検証の順序（依存関係）

```
C (LDAP認証) ─┐
              ├─→ A (権限フィルタ) ─→ E (API連携)
B (SMB到達)  ─┘
D (書き込み) は B の後、A と並行可能
F は最後
```

推奨：**B → C を並行で固め → A を通す → D / E → F**。

### 共通の前提条件（全検証の前に確認）

- [ ] **時刻同期**：全サーバの時刻ズレが 5 分以内（Kerberos の許容差）。NTP を構成
- [ ] **名前解決**：アプリ/Fess サーバから DC・ファイルサーバの名前が IP に変換できる
   （以下をアプリ・Fess サーバ上で実行。IP が返れば OK）
   ```bash
   nslookup dc1.poc.local    # DC（認証サーバ）の名前解決
   nslookup fs1.poc.local    # ファイルサーバの名前解決
   ```
   > IP がわかっている場合は `nslookup` を省略し、以下の疎通確認を IP 直指定で実施してもよい。
- [ ] **疎通**：必要な通信経路ごとにポートが開いているか確認する（下表＋コマンド）

| 確認元 | 確認先 | 用途 | ポート |
|---|---|---|---|
| アプリ・Fessサーバ | DC（`dc1.poc.local`） | LDAP | 389 |
| アプリ・Fessサーバ | DC（`dc1.poc.local`） | LDAPS | 636 |
| アプリ・Fessサーバ | ファイルサーバ（`fs1.poc.local`） | SMB | 445 |
| クライアント（ブラウザ） | Fessサーバ | Fess UI/API | 8080 |

```bash
# アプリ・Fessサーバ上で実行する
nc -vz dc1.poc.local 389    # DC への LDAP
nc -vz dc1.poc.local 636    # DC への LDAPS
nc -vz fs1.poc.local 445    # ファイルサーバへの SMB

# クライアント（PC）から実行する
# ブラウザで http://<Fessサーバip>:8080 を開いて画面が返るか確認
```

> PoC を `verification/` のコンテナで行う場合は、まず `docker compose up -d --build` で
> 全サービスを起動し、`docker compose logs -f samba-ad fileserver` で provision とドメイン
> 参加の完了を確認してから各検証に進む。

---

## 検証B: Linux → Windows SMB 認証アクセス

**目的**：クロール用サービスアカウントでファイルサーバの共有を読めることを確認する。
権限フィルタ（A）以前に「そもそもファイルを読めるか」を切り分ける。

### 手順

1. **疎通とポート確認**
   ```bash
   nc -vz fs1.poc.local 445        # 445 が開いているか
   nslookup fs1.poc.local          # 名前解決
   ```

2. **匿名・認証なしで共有一覧（到達確認）**
   ```bash
   smbclient -L //fs1.poc.local -N
   ```
   → 共有名 `share` が見えれば SMB レイヤは到達。`NT_STATUS_*` エラーならポート/プロトコルを疑う。

3. **サービスアカウントで共有一覧**
   ```bash
   smbclient -L //fs1.poc.local -U 'POC\svc_fess%Svc#Fess2026'
   ```

4. **実ファイルの読み取り**
   ```bash
   smbclient //fs1.poc.local/share -U 'POC\svc_fess%Svc#Fess2026' \
     -c 'cd sales_case; get quote.txt -'
   ```
   → `quote.txt` の中身が表示されれば読める。

5. **SMB プロトコルバージョンの確認**（本番ファイルサーバが SMB1 無効の場合の互換性）
   ```bash
   smbclient //fs1.poc.local/share -U 'POC\svc_fess%Svc#Fess2026' \
     -m SMB3 -c 'ls'
   ```

6. **（任意）CIFS マウント**
   ```bash
   sudo mount -t cifs //fs1.poc.local/share /mnt/share \
     -o username=svc_fess,password='Svc#Fess2026',domain=POC,vers=3.0
   ls -la /mnt/share
   ```

### 合格基準
- [ ] サービスアカウントで `share` を一覧でき、`sales_case/quote.txt` を読める
- [ ] SMB3 で接続できる

### トラブルシュート
| 症状 | 原因の候補 | 対処 |
|---|---|---|
| `NT_STATUS_LOGON_FAILURE` | 資格情報誤り / 時刻ズレ | パスワード・NTP 確認 |
| `NT_STATUS_CONNECTION_REFUSED` | 445 閉塞 | FW / `nc -vz` |
| `protocol negotiation failed` | SMB バージョン不一致 | `-m SMB2`/`SMB3` で再試行。Fess 側は検証A手順1の `jvm.crawler.options` で `jcifs.smb.client.maxVersion=SMB311` を設定 |

---

## 検証C: LDAP 認証とグループ取得（オンプレAD）

**目的**：アプリ / Fess が AD の LDAP に bind してユーザー認証でき、`memberOf` から
所属グループを取得できることを確認する。検証 A の権限フィルタの前提。

### 手順

1. **匿名 / サービスアカウントで bind 確認**
   ```bash
   # サービスアカウントで bind し、alice の memberOf を取得
   ldapsearch -x -H ldap://dc1.poc.local \
     -D 'svc_fess@poc.local' -w 'Svc#Fess2026' \
     -b 'dc=poc,dc=local' '(sAMAccountName=alice)' \
     dn sAMAccountName memberOf objectSid
   ```
   → `memberOf: CN=grp_sales,...` が返れば成功。

2. **対象ユーザー自身での bind（認証成立の確認）**
   ```bash
   ldapsearch -x -H ldap://dc1.poc.local \
     -D 'alice@poc.local' -w 'Alice#2026' \
     -b 'dc=poc,dc=local' '(sAMAccountName=alice)' dn
   ```
   → bind 失敗（`Invalid credentials`）でなければ alice 本人認証が通っている。

3. **LDAPS(636/TLS) の確認**（本番では平文 LDAP を避けたい）
   ```bash
   LDAPTLS_REQCERT=never ldapsearch -x -H ldaps://dc1.poc.local:636 \
     -D 'svc_fess@poc.local' -w 'Svc#Fess2026' \
     -b 'dc=poc,dc=local' '(sAMAccountName=alice)' dn
   ```
   → 成功すれば LDAPS 可。本番では `REQCERT=never` をやめ、社内 CA 証明書を信頼ストアへ。

4. **ネストグループの確認**（グループのグループがある場合）
   ```bash
   # LDAP_MATCHING_RULE_IN_CHAIN でネストを含めて展開
   ldapsearch -x -H ldap://dc1.poc.local \
     -D 'svc_fess@poc.local' -w 'Svc#Fess2026' \
     -b 'dc=poc,dc=local' \
     '(member:1.2.840.113556.1.4.1941:=CN=alice,CN=Users,DC=poc,DC=local)' dn
   ```

5. **Fess の LDAP 認証設定**
   - 管理画面 **全般 > LDAP**（または「ユーザー > LDAP」）に以下を設定
     - URL: `ldap://dc1.poc.local:389`（本番は `ldaps://...:636`）
     - ベース DN: `dc=poc,dc=local`
     - バインド DN: `svc_fess@poc.local` / パスワード
     - ユーザー検索フィルタ: `(sAMAccountName=%s)`
     - グループ属性: `memberOf`
   - alice / bob でログインできることを確認

### 合格基準
- [ ] サービスアカウントで bind でき、対象ユーザーの `memberOf` が取れる
- [ ] 対象ユーザー本人の ID/パスワードで bind 成功（= 認証として使える）
- [ ] LDAPS の可否が判明している
- [ ] Fess に alice / bob でログインできる

### 確認しておく設計パラメータ（本番値を控える）
- ベース DN、ユーザー/グループの OU 構造
- ログイン ID に使う属性（`sAMAccountName` / `userPrincipalName`）
- ネストグループの有無 → 解決方式の決定

---

## 検証A 〔最優先〕Fess の ACL 取得 + AD 権限フィルタ

**目的**：「全文検索はできるが権限が漏れる」を防ぐ。**ここが NG なら社内利用不可**。最重要。

検証 B（読める）と C（認証・グループ取得）が通った前提で実施する。

### 前提データ（PoC 環境に自動投入済み）
| 共有パス | ACL（読める） | alice(grp_sales) | bob(grp_eng) |
|---|---|---|---|
| `share/sales_case/quote.txt` | grp_sales | ○ | × |
| `share/eng_case/design.txt` | grp_eng | × | ○ |

### 手順

1. **Fess のファイルクロール設定を登録**（管理画面 **クローラ > ファイルシステム**）
   - 名前: `poc-share`
   - パス: `smb://fs1.poc.local/share/`
     > **重要（SMB バージョン）**：必ず `smb://` スキームを使う。`smb1://` は
     > **SMB1 専用クライアント**（旧 jcifs）に切り替わり、SMB1 を無効化した本番
     > サーバには接続できない。Fess はスキームでクライアントを選ぶ：
     > - `smb://`  → jcifs-ng（**SMB2/SMB3** 対応）
     > - `smb1://` → 旧 jcifs（**SMB1 のみ**）
   - 認証情報は **クローラ > ファイル認証** で登録する（設定パラメータ欄ではない）
     - ホスト名: `fs1.poc.local` / ポート: `445` / スキーム: `SAMBA`
     - ユーザー: `svc_fess` / パスワード / ドメイン: `POC`
     > ホストは URL から取得されるため、設定パラメータ欄に
     > `client.smb1.server.host=...` のようなキーは**書かない**（実在しない）。

   > **SMB3 必須サーバへの接続（最重要・本番の定番ハマりどころ）**
   > jcifs-ng の既定は `minVersion=SMB1` / `maxVersion=SMB210`（= SMB2.1 止まり）。
   > 本番サーバが SMB1 無効 / SMB3 必須だと negotiate に失敗する。Fess の SMB
   > クライアントは jcifs プロパティを **`System.getProperties()`** から読み、かつ
   > **クロールは別 JVM プロセス**で動くため、クロール設定欄ではなく
   > `app/WEB-INF/classes/fess_config.properties` の **`jvm.crawler.options`** に
   > JVM オプションとして渡す（ここを間違えると効かない）。
   > ```properties
   > jvm.crawler.options=...既存の値はそのまま...\
   > -Djcifs.smb.client.minVersion=SMB202\n\
   > -Djcifs.smb.client.maxVersion=SMB311\n\
   > ```
   > - `minVersion=SMB202`：SMB1 ネゴシエーションを打ち切る
   > - `maxVersion=SMB311`：SMB3.1.1 まで許可
   > - 署名必須サーバで弾かれる場合は `-Djcifs.smb.client.ipcSigningEnforced=false` も検討
   >
   > 設定後は Fess を再起動してから再クロールする。検証Bで `smbclient -m SMB3` が
   > 通っていれば、サーバ側は SMB3 で待っている＝この設定で到達できるはず。

2. **権限（ACL）取得を有効化**
   - クロール設定で、ファイルの許可情報を**ロール / 仮想ホスト（permission）**として
     取り込む設定を ON にする
   - Fess は SMB の ACL（許可 SID/グループ）をドキュメントの `allow` フィールドに格納する

3. **クロールを実行**（管理画面 **システム > スケジューラ > Default Crawler** を今すぐ実行）
   - ログ（**システム情報 / クロール結果**）で `sales_case/quote.txt`、`eng_case/design.txt`
     の 2 件がインデックスされたか確認

4. **インデックス上の権限フィールドを確認**（OpenSearch に直接問い合わせ）
   ```bash
   curl -s 'http://localhost:9200/fess.search/_search?q=quote' \
     | jq '.hits.hits[]._source | {url, allow, role}'
   ```
   → `allow` にグループ（grp_sales 相当の SID / ロール）が入っていれば ACL 取得成功。

5. **ユーザー別の検索出し分けを確認**（本検証の核心）
   - **alice** でログイン → 検索語 `document` 等で検索
     → `quote.txt` がヒットし `design.txt` はヒットしないこと
   - **bob** でログイン → 同じ検索
     → `design.txt` がヒットし `quote.txt` はヒットしないこと
   - **管理者 / 全権ユーザー** → 両方ヒットすること

   API でも確認可能：
   ```bash
   # alice のトークン/セッションで検索 (ログイン後の access_token を使用)
   curl -s 'http://localhost:8080/api/v1/documents?q=document' \
     -H 'Authorization: Bearer <alice_access_token>' | jq '.data[].url'
   ```

### 合格基準
- [ ] クロールで ACL（`allow`/ロール）がインデックスに格納される
- [ ] alice は sales_case のみ、bob は eng_case のみが検索ヒットする
- [ ] 権限のないファイルは**検索結果にもスニペットにも出ない**（情報漏れなし）

### 不合格時の代替案（設計判断に直結）
1. **SID→ロール マッピングを明示設定**：Fess の「ロール」を AD グループに手動対応づけ
2. **クロール時にフォルダ単位でロール付与**：案件フォルダ＝ロールの粒度で運用（テンプレートと整合）
3. それでも不可なら、**アプリ側で検索後フィルタ**（Fess 結果を memberOf で再フィルタ）を検討
   → ただし二重管理になるため最終手段

---

## 検証D: Linux → SMB フォルダ書き込みと ACL 継承

**目的**：アプリがテンプレートに従いフォルダを生成でき、正しい ACL が付くことを確認する。
作成フォルダが検証 A のクロールと整合する（適切な権限で検索される）ことまで見る。

### 手順

1. **書き込み権限のあるアカウントで接続**
   ```bash
   smbclient //fs1.poc.local/share -U 'POC\svc_fess%Svc#Fess2026' \
     -c 'mkdir new_case_2026; cd new_case_2026; mkdir 01_見積; mkdir 02_契約; ls'
   ```
   → テンプレート構造（`01_見積` / `02_契約` …）が作成できること。

2. **ACL の継承確認**（CIFS マウント + getfacl）
   ```bash
   sudo mount -t cifs //fs1.poc.local/share /mnt/share \
     -o username=svc_fess,password='Svc#Fess2026',domain=POC,vers=3.0,acl
   getfacl /mnt/share/new_case_2026/01_見積
   ```
   → 親フォルダの ACL が継承されているか確認。

3. **作成フォルダを再クロールして検索可能性を確認**
   - 検証 A の手順 3〜5 を再実行し、新規フォルダ配下のファイルが
     正しい権限で検索されること

### 合格基準
- [ ] テンプレート通りの階層フォルダを作成できる
- [ ] 親 ACL が子フォルダに継承される
- [ ] 作成フォルダが検証 A と同じ権限ルールで検索される

### 設計メモ
- 本番では「誰の権限でフォルダを作るか」（サービスアカウント vs ユーザー委任）を決める
- 文字コード（日本語フォルダ名）の SMB/Linux 間の扱いを確認（`iocharset=utf8`）

---

## 検証E: Fess REST API 連携

**目的**：アプリからクロール設定の登録・起動・検索を API で制御できることを確認する。

### 手順

1. **アクセストークン発行**（管理画面 **全般 > API アクセストークン** で作成）

2. **検索 API**
   ```bash
   curl -s 'http://localhost:8080/api/v1/documents?q=design' \
     -H 'Authorization: Bearer <token>' | jq '.record_count, .data[].url'
   ```

3. **クロール起動 / ジョブ制御**（管理用 API、バージョンにより異なる）
   ```bash
   # スケジューラ経由でジョブを起動する想定。API 仕様はバージョンを確認
   curl -s -X POST 'http://localhost:8080/api/admin/scheduler/<job_id>/start' \
     -H 'Authorization: Bearer <admin_token>'
   ```

4. **ラベル / ファセット取得**（案件種別での絞り込み UI に使う）
   ```bash
   curl -s 'http://localhost:8080/api/v1/documents?q=*&facet.field=label' \
     -H 'Authorization: Bearer <token>' | jq '.facet'
   ```

### 合格基準
- [ ] API で検索結果（件数・URL）が取得できる
- [ ] API でクロールを起動できる（or スケジューラ連携の方式が確定する）
- [ ] ファセット（ラベル/案件種別）が取得でき、アプリ UI で使える見込みが立つ

---

## 検証F: Tauri 実現性（後回し可）

**目的**：デスクトップ配信（Tauri）での認証・配布が成立するかを確認する。

### 手順
1. **認証フロー**：Tauri 内蔵 WebView でアプリの LDAP ログイン画面を開き、
   セッション/トークンを保持できるか
2. **ローカル連携**：検索結果からエクスプローラで該当フォルダを開く（`\\fs1\share\...` を起動）
3. **配布**：社内配布（MSI/インストーラ）とコード署名、自動更新の運用確認

### 合格基準
- [ ] WebView で認証フローが完結する
- [ ] 検索結果 → ローカルのフォルダ/ファイルを開ける
- [ ] 署名済みインストーラを社内配布できる目処が立つ

---

## PoC のゴール（マイルストーン）

1. **第1マイルストーン**：検証 B + C を通す（基盤の到達性・認証）
2. **第2マイルストーン**：**検証 A を通す**（= プロジェクト続行可否の判定点）
3. **第3マイルストーン**：検証 D + E（アプリ実装の前提を確定）
4. 検証 F は Web 版が固まってから

PoC 環境の構築・操作手順は [`../verification/README.md`](../verification/README.md) を参照。
