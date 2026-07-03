# ClipLocal

**Your clipboard. Yours alone.**

A tiny, privacy-first clipboard history for macOS. It lives in your menu bar, shows a small "✓ Copied" preview in the bottom-right whenever you copy, and keeps a history you can browse, pin, delete, and re-copy.

**100% on-device.** Your clipboard data *never* leaves your Mac — no cloud, no servers, no accounts, no analytics, no third parties. The only network request ClipLocal ever makes is a quick check to see if a newer version exists.

Built by **Arun Thomas**.

---

## Features

- 🔒 **Session-only mode** — history lives in memory and is wiped the moment you quit.
- 💾 **Persistent mode** — history survives restarts, stored **encrypted** in a protected file only your macOS account can read.
- 🛡️ **Skips password-manager copies** by default (copies marked "concealed" are ignored).
- 📌 Pin, delete, and re-copy any item from the menu bar.
- 🧹 One-click "Clear History Now" panic button.
- 🔔 Bottom-right "✓ Copied" preview that fades away.

---

## Install

### Easy way (double-click)

1. **[Download `install-cliplocal.command`](install-cliplocal.command)** (click the file above, then the **Download raw file** button).
2. **Double-click** the downloaded file.
3. If macOS says it's from an unidentified developer, **right-click the file → Open → Open**.
4. Follow the on-screen prompts.

### Reliable fallback (Terminal)

If the double-click doesn't work:

1. Open **Terminal** (press `⌘ + Space`, type `Terminal`, press Enter).
2. Type `sh ` — that's **s**, **h**, then a **space**.
3. **Drag** the downloaded `install-cliplocal.command` file into the Terminal window (its path appears automatically).
4. Press **Enter** and follow the prompts.

> **First time only:** The installer may ask to install Apple's Command Line Tools (a small, official Apple download). Click **Install**, wait for it to finish, then continue. This is what lets your Mac build the app locally — which is also why macOS trusts it and never shows a "damaged app" warning.

After installing, look for the **clipboard icon in your menu bar** (top-right). ClipLocal runs quietly in the background with no Dock icon.

---

## How it works

The installer downloads the app's source code and **builds it right on your Mac**. Because the app is compiled locally rather than downloaded pre-made, macOS Gatekeeper trusts it — no bypassing scary warnings.

---

## Uninstall

1. Quit ClipLocal (menu-bar icon → **Quit ClipLocal**).
2. Drag **ClipLocal** from your Applications folder to the Trash.
3. To remove saved data too, delete this folder:
   `~/Library/Application Support/ClipLocal`

---

## Contact

Questions or feedback? Email **arunthomas04042001@gmail.com**.
