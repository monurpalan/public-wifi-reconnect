# Public WiFi Reconnect

A small Windows app for public Wi-Fi that logs you out every few minutes. It notices when the internet actually stops and reconnects you, so you don't have to keep clicking "reconnect" yourself.

A lot of municipal, cafe and campus networks drop your session on a timer, often every 10 to 15 minutes. The Wi-Fi still shows as connected, but nothing loads until you reconnect by hand. This app does that part for you.

![platform](https://img.shields.io/badge/platform-Windows-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## What it does

- Checks the connection the way Windows itself does (a small HTTP request to `msftconnecttest.com`), with a ping to 8.8.8.8 and 1.1.1.1 as a fallback, instead of trusting the Windows "connected" icon. Networks that block ping no longer cause reconnect loops.
- Ignores short blips of a few seconds, since most of those fix themselves.
- Does one clean reconnect when the internet is really gone.
- Backs off when the network is having a bad spell, so it never gets stuck in a reconnect loop.
- Logs every event to wifi-log.csv: when it dropped and how long it was out.
- Uses whatever network you are on and follows you when you switch networks, so there is nothing to set up.
- Reconnects with the right Windows Wi-Fi profile, even when its name differs from the network name (e.g. "Cafe 2").
- Spots login pages: when the network wants you to sign in, it tells you instead of reconnecting for nothing.
- Minimizes to the system tray; the tray dot shows the status (green / yellow / red / orange for a login page).

## What it does not do

- It does not crack passwords, change your MAC address, or get past any login.
- It will not log you in on networks with a captive portal (a login page or an SMS code). It detects the page and lets you know, but signing in is up to you.
- Windows only.

## Install

1. Download `wifi-reconnect.ps1` and `START.bat` into the same folder.
2. Connect to your Wi-Fi.
3. Double-click `START.bat`. If Windows warns you, click "More info" then "Run anyway". If the file was blocked after download, right-click it, open Properties, and tick "Unblock".

A small window opens and handles the rest. Minimize it to send it to the tray; close the window (or choose Exit from the tray menu) to stop it.

## Settings

Open `wifi-reconnect.ps1` and change the values at the top:

| Setting | Default | What it does |
|---|---|---|
| `DownSecondsNeeded` | `4` | Seconds the internet must stay down before reconnecting. Lower reacts faster but reconnects more often. |
| `BaseCooldownSn` | `20` | How long to stay quiet after a reconnect. |
| `MaxCooldownSn` | `120` | Longest back-off when the network keeps failing. |
| `ProbeUrl` | `http://www.msftconnecttest.com/connecttest.txt` | Page it loads to test the connection. |
| `CheckHosts` | `8.8.8.8, 1.1.1.1` | Addresses it pings when the probe page is blocked. |
| `ManualSsid` | empty | Leave empty to follow the current network, or set a network name by hand. |

## FAQ

**Is it safe? Does it send my data anywhere?**
Everything runs on your own PC. To check the connection it loads Microsoft's connectivity test page (the same one Windows uses) and pings two public DNS servers, then reconnects your Wi-Fi. It sends no data anywhere, and the full source is in `wifi-reconnect.ps1`.

**Networks with a login page?**
It cannot sign you in. When it sees a login page it shows "LOGIN PAGE" and a tray notification, and stops reconnecting until you have signed in from a browser.

**Can it start automatically with Windows?**
Yes. Put a shortcut to `START.bat` in your Startup folder: press Win+R, type `shell:startup`, and drop the shortcut there.

## License

[MIT](LICENSE)
