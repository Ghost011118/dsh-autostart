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
setup.cmd -pause     pause auto-restart but leave the current dsh web running
setup.cmd -start     resume supervision (clear the stop sentinel)
setup.cmd -restart   request an immediate supervised restart
setup.cmd -control   open the on-demand lightweight control panel
setup.cmd -uninstall remove autostart (does NOT stop a running dsh web)
```

---

## 📦 Files

| File | Purpose |
| --- | --- |
| `setup.cmd` | **one-click entry** — double-click to use |
| `start-dsh-web.vbs` | hidden logon entry (starts the supervisor at logon) |
| `dsh-web-launcher.ps1` | the supervisor: hidden start, adopt existing, crash restart, sentinel control |
| `control-dsh.cmd` / `dsh-control.ps1` | on-demand control panel; closing it leaves no tray/UI process resident |
| `install.cmd` | fine-grained install/uninstall (`-start` / `-stop` / `-uninstall`) |
| `readme.txt` / `说明.txt` | detailed usage docs |
| `logs/` `run/` | runtime directories (auto-created, git-ignored) |

---

## ⚙️ Customization

Edit the parameters at the top of `dsh-web-launcher.ps1`:

- `-Port`: port, default `3080`;
- `-RestartDelay`: crash-restart delay in seconds, default `2`.

Changes take effect immediately — no reinstall needed.

## Update-aware restart and safe pause

Every five seconds, the supervisor checks a small, explicit set of files: the
installed DSH `package.json` and `lib/bin.js`; the web profile's `cordis.yml`,
`cordis.patch.yml`, `package.json`, and `pnpm-lock.yaml`; and only the
`package.json` plus declared main entry of direct web-profile dependencies.
It never recursively scans `node_modules`, sessions, storages, profiles, or
logs. A changed fingerprint must remain stable for two checks before DSH is
restarted, avoiding a restart in the middle of an npm/pnpm update.

`-pause` only disables supervision and leaves the current DSH process running.
`-stop` is deliberately stronger: it stops the tracked DSH and pauses future
restarts. `-start`, `-pause`, `-stop`, `-restart`, and `-status` return quickly.

---

## 🔒 Notes / limitations

- This tool does **process-level supervision** — it wraps `dsh web`, it is not a
  dsh plugin.
- If you already run `dsh web` on a different port/host, unify it first to avoid
  two instances competing for the port.
- If another autostart / scheduled task already manages `dsh web`, don't enable
  this one on top.

## Supervisor robustness

Before it launches `dsh web`, `dsh-web-launcher.ps1`:

- **Locates `dsh`'s bin.js automatically** — it resolves the `dsh` shim on the
  PATH first, then falls back to a global install or the npx cache, so a
  non-global install never leaves the supervisor unable to find the entry point;
- **Pins `DSH_HOME`** — if unset in the environment it is set explicitly to
  `~/.dsh`, so dsh reads the correct user-data root (and its `.credentials.yaml`)
  regardless of the session/logon context the guard was spawned from;
- **Exports `DEEPSEEK_API_KEY` as a fallback** — if `~/.dsh/.credentials.yaml`
  carries the key but the outer environment does not, it is injected into the
  launched process, giving dsh a second reliable source beside the credentials
  seam.

All of this cuts down on the intermittent “`no API key`” errors that manual or
multi-instance startup can otherwise cause.

`setup.cmd` / `install.cmd` now **render** (instead of copy) the autostart entry
`start-dsh-web.vbs`: the generated Startup file embeds the **absolute launcher
path** of this install directory. A plain copy used to make the vbs look for
`dsh-web-launcher.ps1` *inside* the Startup folder, where it never lived, so
autostart silently did nothing — the root cause of “I always have to restart it
manually”. That is now fixed.

---

## License

MIT — use, modify, redistribute freely.
