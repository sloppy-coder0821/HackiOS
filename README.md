# HackiOS (monorepo)

iOS 16.5 を QEMU (`virt`, aarch64) および Qualcomm スマホの上で動かすプロジェクト。
6つのリポジトリを1つにまとめたもの。clone 1発でコード一式が揃う。

| ディレクトリ | 内容 |
|---|---|
| `hakios-xnu-kernel/` | 本体：XNU カーネル＋自作ドライバ、ブートローダー、ユーザ空間、QEMU 起動スクリプト |
| `hakios-uefi/` | 実機用 UEFI ファームウェアの差分 |
| `hakios-sm7325/` | POCO X5 Pro 5G (redwood) のデバイス固有ファイル |
| `hakios-metal/` | Metal ドライバ (開発中) |
| `hackios-xnu-userland/` | ポインタ（ユーザ空間は本体の `userland/` に統合済み） |
| `hackios-web/` | プロジェクトサイト |

各ディレクトリの詳細は中の README を参照（本体は `hakios-xnu-kernel/README.md`）。

## QEMU で動かす (Linux)

コード自体はこの clone で完結。iOS 本体のファイルは Apple の公開サーバから
取得する仕組みのため、初回のみダウンロード＋イメージ生成が必要
（約 12GB のディスク。要求：`qemu-system-aarch64`、`edk2-aarch64`、
`7-Zip 23以降`、`python3`、Cコンパイラ）。
**まず前提チェック**（不足があればインストール方法を表示して止まる）：

```sh
git clone https://github.com/sloppy-coder0821/HackiOS.git
cd HackiOS/hakios-xnu-kernel
tools/check-host.sh && sysimage/fetch.sh && REST=1 userland/build.sh
mkdir -p logs
qemu/run-fast.sh 0 -display gtk > logs/qemu.log   # 無制限セッションで起動
```

- `&&` でつなげること（`fetch.sh` が失敗したら次に進まない。これが重要）
- `7z` は 7-Zip 23 以降が必須（Ubuntu の `p7zip-full` は古くて APFS を読めない。`7zip` パッケージを使う）
- ロック画面まで数分。マウス長押し＝指、`H`＝Home、`L`＝電源
- 終わるときは `qemu/stop.sh`。画面キャプチャは `qemu/screendump.sh`

2回目以降は `qemu/run-fast.sh 0 -display gtk` の1コマンドだけ。

## QEMU で動かす (Windows 11 + WSL2)

ネイティブ Windows 版は作らない（後述）。WSL2 上の Ubuntu で Linux と同じ手順が動く：

```powershell
wsl --install -d Ubuntu-24.04
```

Ubuntu を開いて：

```sh
sudo apt update && sudo apt install -y qemu-system-arm qemu-efi-aarch64 7zip python3 build-essential
git clone https://github.com/sloppy-coder0821/HackiOS.git
cd HackiOS/hakios-xnu-kernel
tools/check-host.sh && sysimage/fetch.sh && REST=1 userland/build.sh
mkdir -p logs
qemu/run-fast.sh 0 -display gtk > logs/qemu.log
```

WSL2 固有の注意：

- **メモリ**：ゲストが 7GB 必要なため、Windows 側 `%USERPROFILE%\.wslconfig` に
  `[wsl2]` / `memory=12GB` を設定し、`wsl --shutdown` 後に起動すること
  （既定の 50% では足りないマシンが多い）
- **画面**：WSLg があれば `-display gtk` でウィンドウ表示。
  なければ `QEMU_DISPLAY=vnc=:0 qemu/run-fast.sh 0 > logs/qemu.log`＋
  Windows 側 VNC ビューワ、または `-display none`＋`qemu/screendump.sh`
- `check-host.sh` は WSL2 を検出すると上記を表示する

## 同梱の快適化

- `qemu/run-fast.sh`：高速プリセット（SMP=8、TB 1024MB、framebuffer 軽量化）。`0` で無制限
- `userland/rc.jobs.qemufast`：`RC_JOBS=rc.jobs.qemufast userland/build.sh` で対話用軽量イメージ
- `tools/check-host.sh`：起動前の前提条件チェック（WSL2 対応）
- カーネル boot-args：`fbscale=1`（描画ピクセル9分の1、レイアウト維持）、`fb_hz=30`、
  `ca_vbl=1`、`touch_lat=1`（タッチ/FPS計測）
- `userland/var/mobile/Library/Preferences/com.apple.Accessibility.plist`：
  初回起動から透明度・モーション削減（live確認済み）
- 分割リポジトリ（更新用）：`hakios-xnu-kernel` 他6件が同アカウントに個別にもある

## virtio-gpu（開発中：QEMU 側の真の高速化）

x86ホストではTCGエミュレーションが律速（約10fpsが天井）のため、
表示をホスト側に出す `xnu/files/bsd/dev/hakios.virtio_gpu.c` を開発中：

- Phase 1: デバイス検出・ハンドシェイク・スキャンアウト情報取得（完了）
- Phase 2: 2Dリソースのカラーバーテストパターン表示（完了、QEMU画面で確認）
- Phase 3: iOSフレームバッファの present 経路（作業中：panel/present API 実装済み、表示側接続が次）
- Phase 4: virgl 3D + ゲスト Mesa（将来）

試すには（カーネル再ビルド後）：`QEMU_GPU=1 qemu/run-fast.sh ...`
（`-device virtio-gpu-device` が付き、`virtio_gpu=1` がカーネルに渡る）。

## なぜネイティブ Windows 版を作らないか

起動スクリプト群が Linux 前提で書かれており、移植は作り直し級になる：

- `/proc/meminfo`・`nproc` によるリソース検出
- `os.copy_file_range` によるスパース reflink での 12GB RAM イメージ作成（Windows 非対応）
- EDK2 ファームウェアのパス探索（Linux 配置前提）
- カーネルビルドの theos/cctools ツールチェーン（Linux/macOS 前提）

WSL2 なら上記すべてがそのまま動き、性能も TCG である点では同等。
ネイティブ移植より WSL2 手順の維持に注力する。
