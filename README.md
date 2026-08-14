# Google フォト — タスクトレイ常駐

Google フォトの Web アプリ（PWA）を **Windows のタスクトレイ（通知領域）に常駐**させ、**Windows ログイン時に自動起動**するための一式です。最新安定版のPowerShell Coreと.NETの標準機能を使うため、追加の常駐ツールは必要ありません。

## 仕組み

- `Pictures` と `Videos` の配下をファイルイベントで監視（画像・動画だけを対象）
- 待機中はChromeを起動せず、トレイホストだけが常駐
- メディアの追加・変更を検知したときだけ、専用Chromeを画面外の可視ウィンドウとして起動
- Googleフォトの「バックアップしました / バックアップ完了」を確認できたときだけ、バックグラウンドChromeを終了する
- バックアップエラーや未完了件数を検知した場合は、保留ファイルを同期済み扱いにせず、画面外のChromeで再試行する
- 専用プロファイルがログアウトしていたら画面を自動表示せず、通知だけ出して同期を保留する。「Show」または「Reopen」でログイン画面を表示する
- 「Show」または「Reopen」で表示したChromeは、「Hide」または右上の「×」を押すまで表示を維持する
- トレイアイコンの左クリックで表示 / 非表示を切り替え、右クリックで「表示 / 非表示」「開き直す」「今すぐ同期」「終了」を選択
- 専用プロファイルのため、通常のChromeのウィンドウやログイン状態に影響しない

Google フォトの「フォルダをバックアップ」はWebアプリが動作している間だけ進むため、メディアが増えたときだけWebアプリを起動して同期します。

## 必要環境

- Windows 10 / 11
- 最新安定版のPowerShell Core（`pwsh`。Windows PowerShell 5.1とPreview版は使用しません）
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
4. 設定後はトレイアイコンの「Exit」で初回ウィンドウを閉じる。

専用プロファイルは `%LOCALAPPDATA%\GooglePhotosTray\profile` に保存されます。通常運用では、`C:\Users\<ユーザー名>\Pictures` と `C:\Users\<ユーザー名>\Videos` の配下に画像・動画を保存すると自動同期します。

## Googleからログアウトした場合

メディア同期中にGoogleのサインイン画面を検出しても、専用Chromeは自動表示せず、通知だけを出して保留します。
トレイの「Show」または「Reopen」で専用Chromeを表示し、そのウィンドウで再ログインしてください。
Googleフォト画面への復帰を確認すると、現在の表示状態を保ったまま保留していた同期を自動的に再開します。

再ログインが必要な状態は
`%LOCALAPPDATA%\GooglePhotosTray\authentication-required.json`へ保存されるため、
Windowsへ再サインインした場合もログイン画面を再表示できます。このファイルに入るのは
状態と検出時刻だけです。パスワード、Cookie、トークン、メールアドレスはリポジトリ、
ログ、状態ファイルへ保存しません。専用Chromeプロファイル自体は従来どおりChromeが
ローカル管理します。

認証切れ時に画面が自動表示されないのは仕様です。トレイメニューの「Show」または「Reopen」、
`photos_tray_hidden.vbs`で専用ウィンドウを開いてください。

## Windows ログイン時に自動起動する

最新安定版のPowerShell Coreで、配置先フォルダーへ移動してから実行します。管理者権限は不要です。
インストール済みの安定版`pwsh.exe`をファイルバージョンで比較し、MSI / Microsoft Store
（MSIX）版も含めた最新版を非表示VBSランチャーへ渡すタスクを
タスクスケジューラへ登録します。Windowsログイン後25秒待ってトレイホストだけを
起動し、Chromeはメディア変更時まで起動しません。

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\Google Photos Tray"
Set-Location $installDir
pwsh -NoProfile -File .\install_startup.ps1
```

登録直後に試す場合は`Start-ScheduledTask -TaskName "Google Photos Tray"`を実行して
ください。次回のWindowsログインから、コンソールを表示せずタスクスケジューラ経由で
軽量なメディア監視が始まります。旧方式のスタートアップショートカットが残っている
場合は削除を試みます。残っていても名前付きMutexで二重起動を防ぐため、動作は一重です。

## 自動起動を解除する

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\Google Photos Tray"
Set-Location $installDir
pwsh -NoProfile -File .\install_startup.ps1 -Uninstall
```

解除後も現在起動中のChromeとトレイホストは終了しないため、必要に応じてトレイメニューの「Exit」を選んでください。

## ファイル

| ファイル | 役割 |
|---|---|
| `photos_tray.ps1` | メディア監視、必要時のChrome起動、トレイアイコン管理の本体 |
| `photos_tray_hidden.vbs` | 初回設定・手動表示用のランチャー（待機なし） |
| `photos_tray_startup_hidden.vbs` | タスクスケジューラ用の非表示ランチャー（25秒待機） |
| `resolve_latest_pwsh.vbs` | VBSからPreviewを除く最新版の`pwsh.exe`を選ぶ共通処理 |
| `install_startup.ps1` | 最新安定版PowerShell Coreを使うタスクの登録 / 解除（`-Uninstall`） |

## 設定値を変更する場合

- URLや専用プロファイルの場所を変更する場合は、`photos_tray.ps1` の `-Url` / `-UserDataDir` を指定します。
- 同期完了表示を検知できない場合の無変更タイムアウトは `-SyncQuietSeconds`（既定300秒）で変更できます。
- 再スキャン間隔は `-RescanIntervalSeconds`（既定600秒）で変更できます。ファイルイベントを取りこぼした場合の保険です。
- 専用プロファイルを削除すると、次回起動時にGoogleアカウントへのログインからやり直しになります。
- Chromeの実行ファイルはトレイホスト起動ごとにレジストリと標準配置先から再検出するため、通常のChrome更新後も同じ専用プロファイルを引き継ぎます。

## 起動トラブルの確認

タスクの状態:

```powershell
Get-ScheduledTask -TaskName "Google Photos Tray" | Select-Object TaskName,State
```

起動ログ:

```powershell
Get-Content "$env:LOCALAPPDATA\GooglePhotosTray\logs\startup.log" -Tail 80
```

ログには監視対象、メディア変更、Chromeの必要時起動、終了、再試行、再ログイン要求と
復旧の内容が記録されます。認証情報やChromeのプロファイル内容は記録しません。
既知のメディア状態は `%LOCALAPPDATA%\GooglePhotosTray\media-state.json` に保存されます。

認証画面やバックアップ失敗処理の判定を変更した場合は、最新安定版のPowerShell Coreで回帰テストを実行します。

```powershell
pwsh -NoProfile -File .\tests\Test-AuthenticationDetection.ps1
pwsh -NoProfile -File .\tests\Test-BackupFailureDetection.ps1
pwsh -NoProfile -File .\tests\Test-DisplayState.ps1
pwsh -NoProfile -File .\tests\Test-MediaSyncFailure.ps1
pwsh -NoProfile -File .\tests\Test-StartupTaskDefinition.ps1
```
