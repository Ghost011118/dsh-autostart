# dsh-autostart — autostart + hidden window + crash auto-restart for `dsh web`

A Windows helper kit that makes the **DeepSeek Harness web UI** (`dsh web`,
default `http://127.0.0.1:3080`) just work:

- 🚀 **Autostart on logon**: starts hidden at every login — no console black box.
- ♻️ **Crash auto-restart**: relaunches `dsh web` ~2s after it exits unexpectedly.
- 🪄 **One-click adoption**: if you already run `dsh web` another way, running this
  tool ADOPTS that instance and supervises it, so a crash restarts it.
- 🧩 **Edit pages without restart**: the companion `dsh-chat` plugin reads its
  `public/*` static pages fresh from disk on every request, so edits show up on
  a browser refresh — no dsh restart, no interrupting an in-flight chat.

> Pure PowerShell / VBS / cmd. No build step, no dsh-plugin dependency.
> Download and double-click.

---

## ✨ Usage (portable — clone & double-click)

> Prerequisite: Node.js installed, and `dsh web` (DeepSeek Harness) usable.

**One-click setup (recommended)**

1. Download / clone this repo anywhere;
2. **Double-click `setup.cmd`** — it will:
   - put `start-dsh-web.vbs` into your Startup folder (autostart on logon);
   - start the supervisor in the background (hidden window);
   - ADOPT your running `dsh web` if any;
   - verify `http://127.0.0.1:3080` is reachable.

From then on `dsh web` is supervised: autostart on logon, restart on crash.

**Commands** (from a cmd in this folder)

```
setup.cmd            one-click: configure + start supervision
setup.cmd -stop      stop dsh web and disable auto-restart
setup.cmd -start     resume supervision (clear the stop sentinel)
setup.cmd -uninstall remove autostart (does NOT stop a running dsh web)
```

---

## 📦 Files

| File | Purpose |
| --- | --- |
| `setup.cmd` | **one-click entry** — double-click to use |
| `start-dsh-web.vbs` | hidden logon entry (starts the supervisor at logon) |
| `dsh-web-launcher.ps1` | the supervisor: hidden start, adopt existing, crash restart, sentinel control |
| `install.cmd` | fine-grained install/uninstall (`-start` / `-stop` / `-uninstall`) |
| `readme.txt` / `说明.txt` | detailed usage docs |
| `logs/` `run/` | runtime directories (auto-created, git-ignored) |

---

## ⚙️ Customization

Edit the parameters at the top of `dsh-web-launcher.ps1`:

- `-Port`: port, default `3080`;
- `-RestartDelay`: crash-restart delay in seconds, default `2`.

Changes take effect immediately — no reinstall needed.

---

## 🔒 Notes / limitations

- This tool does **process-level supervision** — it wraps `dsh web`, it is not a
  dsh plugin.
- If you already run `dsh web` on a different port/host, unify it first to avoid
  two instances competing for the port.
- If another autostart / scheduled task already manages `dsh web`, don't enable
  this one on top.

---

## License

MIT — use, modify, redistribute freely.
