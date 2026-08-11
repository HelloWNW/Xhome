**日本語** | [English](README.en.md)

# Xhome — エクストリーム帰宅

Raspberry Pi Zero W から **映像・音声・GPS** をモバイル回線で配信し、
公開ウェブサイト上で「いま どこを歩いているか」をリアルタイムに見せるための
自作ライブ配信システムです。

徒歩の長距離移動を丸ごと中継し、走行ログを地図に描き、
すべてを録画としてあとから GPS 付きで再生できます。

```
┌──────────────┐   RTMP/LTE   ┌─────────────────┐   HLS    ┌──────────────┐
│ Raspberry Pi │ ───────────▶ │  配信サーバー    │ ───────▶ │  ウェブサイト │
│  Zero W      │              │  (Docker+Caddy) │          │  (静的ホスト) │
│              │              │                 │          │              │
│ カメラ        │              │ ・音声処理       │          │ ・映像        │
│ I2S マイク    │              │ ・HLS 生成       │          │ ・地図/GPS    │
│ GPS (UART)   │              │ ・録画          │          │ ・録画再生     │
│ LTE モデム    │              │ ・状態監視       │          │ ・PWA        │
└──────────────┘              └─────────────────┘          └──────────────┘
```

---

## 特徴

| | |
|---|---|
| **低遅延配信** | 1 秒 HLS セグメント。実測エンドツーエンド 約 4 秒 |
| **音声同期** | 映像と音声のずれ 12〜19 ms |
| **音声処理** | ゲイン・ハイパスフィルタ・RNN ノイズ除去・リミッター |
| **GPS 連動地図** | 現在地、歩いた軌跡、目的地までの推定ルート |
| **録画 + GPS 同期** | 過去の任意の時点を再生すると、地図もその時刻の位置に追従 |
| **自動復旧** | 配信が固まった場合にウォッチドッグが自動再起動 |
| **PWA 対応** | iPhone のホーム画面に追加可能。復旧時に通知 |
| **多言語** | 日本語 / 英語（アクセス元の国から自動判定） |

---

## ディレクトリ構成

```
pi/                     Raspberry Pi 側
  bin/                  各種スクリプト
    xhome-broadcast.sh    カメラ + マイク → RTMP 送出
    xhome-watchdog.sh     固まった配信の検知と再起動
    xhome-lte-up.sh       LTE (QMI raw-IP) セッション管理
    xhome-miclevel.sh     マイクのレベル確認（配線診断用）
  systemd/              サービス定義
  etc/                  asound.conf / config.txt 追記分

server/                 配信サーバー側（Windows + Docker）
  scripts/
    transcode.sh          音声処理 + HLS 生成
    archive.sh            録画（5 分単位の MPEG-TS）
    gps-pull.ps1          Pi の gpsd から位置を取得
    status-collect.ps1    各コンポーネントの死活監視
    archive-index.ps1     録画の再生用プレイリスト生成
    viewers.ps1           視聴者数の集計
  caddy/
    Caddyfile.example     配信オリジンの設定

web/                    公開サイト（静的ホスティング）
  public/
    index.html            本体（単一ファイル）
    config.example.js     設置ごとの設定（要コピー・編集）
    manifest.webmanifest  PWA
    sw.js                 Service Worker
```

---

## セットアップ

### 1. Raspberry Pi

```bash
# 必要なパッケージ
sudo apt install -y ffmpeg rpicam-apps gpsd libqmi-utils

# 設定ファイル（認証情報はここにのみ書く）
sudo cp xhome.env.example /etc/xhome.env
sudo chmod 600 /etc/xhome.env
sudo nano /etc/xhome.env          # RTMP_URL を設定

# スクリプトとサービス
sudo cp pi/bin/*.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/xhome-*.sh
sudo cp pi/etc/asound.conf /etc/asound.conf
sudo cp pi/systemd/*.service /etc/systemd/system/
cat pi/etc/config.txt.snippet | sudo tee -a /boot/firmware/config.txt

sudo systemctl daemon-reload
sudo systemctl enable --now xhome-broadcast xhome-watchdog
sudo reboot
```

### 2. 配信サーバー

RTMP を受ける ingest（MediaMTX など）と Docker が必要です。

```powershell
# 環境変数を設定（server.env.example 参照）
setx RTMP_SOURCE "rtmp://ingest:1935/live?user=USER&pass=PASSWORD" /M
setx APP_DIR     "C:\broadcast" /M
setx ARCHIVE_DIR "D:\xhome" /M

# 変換コンテナ（音声処理 + HLS）
docker run -d --name xhomeTranscodeWorker --restart unless-stopped `
  -v C:\broadcast:/app -v C:\broadcast\hlsout:/hlsout -v C:\broadcast\models:/models `
  --entrypoint sh jrottenberg/ffmpeg:8.1-nvidia2404 /app/transcode.sh

# 録画コンテナ
docker run -d --name xhomeArchiver --restart unless-stopped `
  -v C:\broadcast:/app -v D:\xhome:/archive `
  --entrypoint sh jrottenberg/ffmpeg:8.1-nvidia2404 /app/archive.sh
```

`server/caddy/Caddyfile.example` の内容を Caddy に取り込み、
`gps-pull.ps1` / `status-collect.ps1` / `archive-index.ps1` / `viewers.ps1` を
タスクスケジューラで起動時実行に登録します。

ノイズ除去モデル（RNNoise）は別途取得してください:

```bash
curl -o models/sh.rnnn https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn
```

### 3. ウェブサイト

```bash
cp web/public/config.example.js web/public/config.js
# config.js を編集：配信オリジンの URL、出発地・目的地の座標など
```

静的ホスティング（Cloudflare Pages など）に `web/public` を配置するだけです。

---

## 設定

すべての設置固有の値は **コード外** にあります。

| 場所 | 内容 |
|---|---|
| `/etc/xhome.env` | Pi の RTMP 送出先と認証情報 |
| 環境変数（サーバー） | ソース URL、各ディレクトリ、Pi のアドレス |
| `web/public/config.js` | 配信オリジン、座標、地点名、パスコードのハッシュ |

`config.js` の `passSha256` は **UI を隠すだけ** で、配信 URL 自体は保護しません。
本当に保護したい場合は、オリジンの手前に認証（Caddy の basic_auth、
Cloudflare Access など）を置いてください。

---

## 実装メモ

小さなハードウェアで安定配信させるまでに踏んだ地雷の記録です。

### ALSA の period size が音切れの原因だった

48 kHz で既定の `period_size 32` は **毎秒約 1500 回** の DMA 割り込みを発生させ、
Pi Zero のシングルコアを飽和させます。`dsnoop` で 1024 に変更すると
割り込みは毎秒約 47 回まで下がり、増える遅延は約 21 ms だけです。

### `-thread_queue_size` は「秒」である

ALSA 入力に対するこの値は実質バッファ秒数になります。2048 は
**43.7 秒の恒久的な遅延**を生みました。256 が実用的な下限です。

### MBIM は Pi Zero では使えない

`cdc_ncm` のアグリゲーションが `dwc_otg` の TX ウォッチドッグを踏み、
パケットロス 100 % になります。QMI raw-IP なら安定します。

### プロセスが生きていても配信は死ぬ

RTMP の送出が詰まると ffmpeg は write でブロックし、カメラ側も
stdout でブロックします。両方«生きたまま»配信だけが止まるため、
systemd からは正常に見えます。ウォッチドッグは
**インターフェースの送信バイト数**と**カメラプロセスの生死**の両方を見ます。

### 「音が出ている」ことはデバイスが開けることでは確認できない

I2S のデータ線が外れていても録音自体は成功し、全サンプルがゼロの
完全な無音データが取れてしまいます。起動時チェックでは
**ゼロ以外のサンプルが存在するか**まで検証します。

### 映像なしの配信は「正常」に見えてしまう

カメラ取得に失敗しても ffmpeg は音声のみで配信を続けます。
約 100 kbps 出ているためビットレート監視では検知できません。
カメラプロセスそのものを監視する必要があります。

---

## 動作環境

- Raspberry Pi Zero W（ARMv6、シングルコア、512 MB）
- Raspberry Pi Camera Module（imx219）
- I2S MEMS マイク（`googlevoicehat-soundcard` オーバーレイ利用）
- GPS モジュール（UART / NMEA）
- LTE モデム（QMI 対応）※任意
- 配信サーバー：Docker が動く環境
- 公開サイト：任意の静的ホスティング

---

## ライセンス

MIT License — [LICENSE](LICENSE) を参照してください。
