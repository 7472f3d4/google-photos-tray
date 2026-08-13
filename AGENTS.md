# Codex作業規約

## 正式ブランチとpush先

- リモートで統合・公開する唯一のブランチは`main`です。
- 作業用のローカルブランチは作成できますが、非`main`のリモートブランチへpushしません。
- push前に`origin/main`を取得し、既存変更を確認したうえで、プロジェクト固有のビルド・テストを実行します。
- 通常のpushは`git push origin HEAD:refs/heads/main`を使います。認証情報やアカウント名はこのファイルに保存しません。
- force push、mainの削除、履歴の書き換えは、ユーザーが明示的に許可した場合だけ行います。

## 新しいCodex環境・アカウントでの再適用

クローン直後、またはCodexアカウント／作業環境が変わったときに、リポジトリルートで次を一度実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\codex\Install-MainOnlyPushPolicy.ps1
```

このスクリプトは、ローカルのpre-pushフックを設定し、`git push origin`の既定refspecを現在のHEADから`origin/main`へ向けます。認証は現在のGitHub/Git設定を使用し、資格情報を記録・送信しません。既存のpre-pushフックがあれば`.git/hooks/pre-push.previous`へ退避して、main検査後に引き継ぎます。

フックはmain以外のrefへのpushとmainの削除を拒否します。これはローカル保護なので、適用済みかをpush前に確認してください。GitHub側のブランチ保護を変更する処理は含みません。

## 作業開始と完了

1. `git status -sb`で既存のユーザー変更を確認し、無断で破棄しない。
2. `git fetch origin --prune`後にmainとの差分とPRを確認する。
3. mainへ統合する変更は重複適用せず、秘密情報や生成物を混入させない。
4. 検証結果（コマンド、警告、エラー、未検証事項）を作業報告に残す。
5. push後に`git rev-parse HEAD`と`git rev-parse origin/main`が一致することを確認する。

