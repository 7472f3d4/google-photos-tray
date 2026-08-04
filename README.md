# Google フォト — タスクトレイ常駐

Google フォトの Web アプリ（PWA）を **Windows のタスクトレイ（通知領域）に常駐**させ、
**PC 起動時に自動起動**するための一式です。外部ツールは不要で、Windows 標準の
PowerShell + .NET（NotifyIcon）だけで動きます。

## なぜ常駐させるのか

**パソコン版 Google ドライブの「Google フォトへのバックアップ」機能が 2026/8/10 で終了**したため
（2026/6/15 以降は新規フォルダ追加も不可）、その代替として **Google フォト Web アプリ側の
「フォルダをバックアップ」機能**で自動アップロードを続けるのが公式の推奨です。
この機能は **Web アプリが起動している間だけ**動くので、PC 起動時から常にトレイで動かし続けることで
「フォルダに写真を置けば自動で Google フォトへ上がる」状態を維持します。

## 仕組み

- 専用プロファイルで Chrome を「アプリ表示（`--app`）」で起動 → ウィンドウ管理が確実。
- 起動時はウィンドウを隠してトレイアイコンだけ表示。
- **トレイアイコン**: 左クリックで表示/非表示の切り替え。右クリックで「表示/非表示・開き直す・終了」。

## 使い方

### 初回セットアップ（1 回だけ）

1. `photos_tray_hidden.vbs` をダブルクリック。
2. 専用プロファイルのため、開いたウィンドウで **Google アカウントにログイン**。
3. Google フォトの **設定 →「フォルダをバックアップ」** で、自動アップロードしたい
   PC 内のフォルダを指定する（＝ 旧 Google ドライブのバックアップの代わり）。
4. 設定できたら、**トレイアイコンを左クリックで非表示**にして OK。以後はトレイで動き続けます。

> 2 回目以降は、起動するとウィンドウを出さずトレイのみで静かに常駐します。
> バックアップ状況を見たいときはトレイアイコンを左クリックで表示できます。

### PC 起動時に自動起動する

PowerShell で次を実行（管理者権限は不要）:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_startup.ps1
```

スタートアップに次のショートカットが作られます:
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Google Photos Tray.lnk`

### 自動起動を解除する

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_startup.ps1 -Uninstall
```

## ファイル

| ファイル | 役割 |
|---|---|
| `photos_tray.ps1` | 本体（Chrome 起動 + トレイアイコン管理） |
| `photos_tray_hidden.vbs` | コンソール窓を出さずに本体を起動するランチャー |
| `install_startup.ps1` | スタートアップ登録 / 解除（`-Uninstall`） |

## メモ

- アイコンは Chrome の実行ファイルから取得しています（見た目は Chrome アイコン）。
  Google フォトらしい見た目にしたい場合は `photos_tray.ps1` の `ExtractAssociatedIcon`
  の箇所を `.ico` 指定に変えれば差し替え可能です。
- 別アカウント / 別 URL にしたい場合は `photos_tray.ps1` の `-Url` 既定値を変更してください。
- 専用プロファイルは `%LOCALAPPDATA%\GooglePhotosTray\profile` に作られます。
