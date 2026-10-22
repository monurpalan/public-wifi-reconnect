# Public WiFi Reconnect

A small Windows app for public Wi-Fi that logs you out every few minutes. It notices when the internet actually stops and reconnects you, so you don't have to keep clicking "reconnect" yourself.

A lot of municipal, cafe and campus networks drop your session on a timer, often every 10 to 15 minutes. The Wi-Fi still shows as connected, but nothing loads until you reconnect by hand. This app does that part for you.

![platform](https://img.shields.io/badge/platform-Windows-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## What it does

- Checks the connection by pinging 8.8.8.8 and 1.1.1.1, instead of trusting the Windows "connected" icon.
- Ignores short blips of a few seconds, since most of those fix themselves.
- Does one clean reconnect when the internet is really gone.
- Backs off when the network is having a bad spell, so it never gets stuck in a reconnect loop.
- Logs every event to wifi-log.csv: when it dropped and how long it was out.
- Uses whatever network you are on, so there is nothing to set up.

## What it does not do

- It does not crack passwords, change your MAC address, or get past any login.
- It will not help on networks with a captive portal (a login page or an SMS code). It only covers the case where reconnecting is enough.
- Windows only.

## Install

1. Download `wifi-reconnect.ps1` and `START.bat` into the same folder.
2. Connect to your Wi-Fi.
3. Double-click `START.bat`. If Windows warns you, click "More info" then "Run anyway". If the file was blocked after download, right-click it, open Properties, and tick "Unblock".

A small window opens and handles the rest. Close the window to stop it.

## Settings

Open `wifi-reconnect.ps1` and change the values at the top:

| Setting | Default | What it does |
|---|---|---|
| `FailsNeeded` | `4` | Seconds the internet must stay down before reconnecting. Lower reacts faster but reconnects more often. |
| `BaseCooldownSn` | `20` | How long to stay quiet after a reconnect. |
| `MaxCooldownSn` | `120` | Longest back-off when the network keeps failing. |
| `CheckHosts` | `8.8.8.8, 1.1.1.1` | Addresses it pings to test the connection. |
| `Ssid` | empty | Leave empty to use the current network, or set it by hand. |

## FAQ

**Is it safe? Does it send my data anywhere?**
Everything runs on your own PC. It only pings two public DNS servers to check the connection, then reconnects your Wi-Fi. It sends no data anywhere, and the full source is in `wifi-reconnect.ps1`.

**Networks with a login page?**
Not supported. This only works on networks where reconnecting is enough.

**Can it start automatically with Windows?**
Yes. Put a shortcut to `START.bat` in your Startup folder: press Win+R, type `shell:startup`, and drop the shortcut there.

## License

[MIT](LICENSE)
