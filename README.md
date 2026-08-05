# Google フォト — タスクトレイ常駐

Google フォトの Web アプリ（PWA）を **Windows のタスクトレイ（通知領域）に常駐**させ、**Windows ログイン時に自動起動**するための一式です。PowerShell と .NET の標準機能を使うため、追加の常駐ツールは必要ありません。

## 仕組み

- 専用プロファイルで Google Chrome をアプリ表示（`--app`）として起動
- 初回起動時はウィンドウを表示し、2回目以降はウィンドウを隠してトレイだけで常駐
- トレイアイコンの左クリックで表示 / 非表示を切り替え
- 右クリックで「表示 / 非表示」「開き直す」「終了」を選択
- 専用プロファイルのため、通常のChromeのウィンドウやログイン状態に影響しない

Google フォト Web アプリの「フォルダをバックアップ」を有効にしておくと、アプリを常駐させたまま指定フォルダーのバックアップを継続できます。

## 必要環境

- Windows 10 / 11
- Google Chrome がインストール済みであること
- Google フォトを利用できるGoogleアカウント

## 配置先

長期運用では、リポジトリやダウンロードフォルダーではなく、次のユーザー単位の配置先を推奨します。管理者権限は不要です。

```text
C:\Users\<ユーザー名>\AppData\Local\Programs\Google Photos Tray
```

リポジトリのファイルをこのフォルダーへコピーしてから、以降の操作をこの配置先で行ってください。スタートアップ登録は実行したファイルの場所を記録するため、後からフォルダーを移動しないでください。

## 初回セットアップ

1. `photos_tray_hidden.vbs` をダブルクリックする。
2. 開いた専用Chromeウィンドウで Google アカウントにログインする。
3. Google フォトの設定から「フォルダをバックアップ」を開き、自動アップロードするPC内のフォルダーを指定する。
4. 設定後はトレイアイコンを左クリックしてウィンドウを隠す。

専用プロファイルは `%LOCALAPPDATA%\GooglePhotosTray\profile` に保存されます。初回設定が完了する前にPCを再起動した場合は、トレイアイコンの「Reopen」でウィンドウを開いて設定を続けてください。

## Windows ログイン時に自動起動する

PowerShell で、配置先フォルダーへ移動してから実行します。管理者権限は不要です。Windows のタスクスケジューラに `Google Photos Tray` タスクを登録し、非表示のVBSランチャー経由でログイン後25秒待って起動します。ChromeやWindowsの初期化が間に合わない場合は、最大3回まで自動再試行します。

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\Google Photos Tray"
Set-Location $installDir
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_startup.ps1
```

登録直後に試す場合は `photos_tray_hidden.vbs` を実行してください。次回のWindowsログインから、コンソールを表示せずタスクスケジューラ経由でトレイ常駐します。旧方式のスタートアップショートカットが残っている場合は削除を試みます。残っていても名前付きMutexで二重起動を防ぐため、動作は一重になります。

## 自動起動を解除する

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\Google Photos Tray"
Set-Location $installDir
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_startup.ps1 -Uninstall
```

解除後も現在起動中のChromeとトレイホストは終了しないため、必要に応じてトレイメニューの「Exit」を選んでください。

## ファイル

| ファイル | 役割 |
|---|---|
| `photos_tray.ps1` | Chrome起動とトレイアイコン管理の本体 |
| `photos_tray_hidden.vbs` | 手動起動用のランチャー（待機なし） |
| `photos_tray_startup_hidden.vbs` | タスクスケジューラ用の非表示ランチャー（25秒待機） |
| `install_startup.ps1` | タスクスケジューラへの登録 / 解除（`-Uninstall`） |

## 設定値を変更する場合

- URLや専用プロファイルの場所を変更する場合は、`photos_tray.ps1` の `-Url` / `-UserDataDir` を指定します。
- 専用プロファイルを削除すると、次回起動時にGoogleアカウントへのログインからやり直しになります。

## 起動トラブルの確認

タスクの状態:

```powershell
Get-ScheduledTask -TaskName "Google Photos Tray" | Select-Object TaskName,State
```

起動ログ:

```powershell
Get-Content "$env:LOCALAPPDATA\GooglePhotosTray\logs\startup.log" -Tail 80
```

ログにはChromeの検出、起動待ち、トレイアイコン表示、起動失敗の内容が記録されます。認証情報やChromeのプロファイル内容は記録しません。
