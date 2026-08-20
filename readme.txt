============================================================
 dsh web AUTOSTART + HIDDEN WINDOW + CRASH AUTO-RESTART
 (DeepSeek Harness Web GUI)
============================================================

WHAT THIS DOES
--------------
A Windows helper that, on logon, starts `dsh web` with a hidden
console window and keeps it alive: if dsh web crashes or is killed
accidentally, this launcher restarts it automatically a few seconds
later. It is a separate helper OUTSIDE dsh; it does not need to be
a dsh plugin (see the "why not a plugin" note at the bottom).

FILES
-----
  dsh-web-launcher.ps1   the supervisor (hidden launch + restart loop)
  start-dsh-web.vbs      hidden logon entry that runs the supervisor
  install.cmd            install/uninstall/stop/start helper
  readme.txt             this file

INSTALL (autostart on login)
----------------------------
  1. Double-click  install.cmd     (installs to your Startup folder)
  That renders start-dsh-web.vbs into
    %APPDATA%\...\Programs\Startup
  so it runs hidden at every logon.
  Start it immediately (no reboot) by double-clicking start-dsh-web.vbs,
  or run:  install.cmd -start

CHECK IT IS UP
--------------
  Open http://127.0.0.1:3080 in a browser. If the GUI loads, it works.
  See logs\launcher-*.log and logs\dsh-web-stdout.log / -stderr.log.

CONTROL
-------
  install.cmd            install / enable autostart
  install.cmd -start     clear the "stopped" sentinel, resume supervision
  install.cmd -pause     pause auto-restart; keep the current dsh web running
  install.cmd -stop      stop dsh web and prevent auto-restart (one-off)
  install.cmd -restart   request an immediate supervised restart
  install.cmd -uninstall remove the Startup entry (does NOT stop dsh web)

CUSTOMIZATION
-------------
  If your dsh web runs on another port or host, edit the parameters at the
  top of dsh-web-launcher.ps1 (defaults: port 3080).
  To change the crash-restart delay, edit -RestartDelay (default 2 s).

  --- Want it to come back up FAST? ---
  The crash-restart delay (2 s by default) is the wait before the launcher
  relaunches dsh web after a crash. Lowering it makes recovery quicker.
  But the real cost is dsh web's COLD START (loading plugins, sqlite, the
  frontend) which takes several seconds no matter what. To make everyday
  life feel faster, keep dsh web RUNNING (that is "常驻/warm") so you rarely
  hit a cold start at all:
    * Don't -stop it; let it stay supervised. Only a crash triggers a restart.
    * Avoid editing plugin files that FORCE a full restart (see the "three
      tiers" section below) - with the dsh-chat live-read change, editing
      public/*.html and gui.js never needs a restart.
  If you change -RestartDelay, also re-install the autostart? No - install.cmd
  just renders the vbs; the delay lives in the ps1, so editing the ps1 is
  enough (the vbs calls the ps1 at logon).

NOTES / LIMITATIONS
-------------------
  * The supervisor launches `dsh web` in the background with a hidden
    window; it cannot be launched while another instance already holds
    the same port. If port 3080 is already in use, start that instance
    first or change the port in the launcher.
  * If you already start dsh web some other way (a terminal, a Task
    Scheduler entry), don't also enable this autostart, or you will have
    two instances competing for port 3080.
  * This helper supervises the PROCESS, not your profile edits. To make
    page/plugin edits show up without restarting dsh web, see the answers
    for "page changes still need a restart" below.

============================================================
WHY "PAGE CHANGES STILL NEED A RESTART" - THREE TIERS
============================================================
Changes fall into different tiers; only some require a restart:

  TIER 1 - cordis.patch.yml  -> HOT-RELOADS (no restart)
     The profile's patch file ($DSH_HOME/profiles/web/cordis.patch.yml)
     is watched and re-applied live, even in the web profile (the boot
     layer re-instantiates the HMR watching service for the user patch
     file regardless of the bundled "hmr disabled" row). Editing it (adding/removing
     plugins, changing a plugin's config) takes effect without restart.

  TIER 2 - static files served by frontend-static (e.g. the main SPA dist)
     -> read from disk on EVERY request, so NO server restart either.
     The frontend-static host does readFile per request with no cache
     header. You just need a hard browser refresh (Ctrl+F5) if the
     browser cached an old copy.

  TIER 3 - a plugin's SERVER code, and assets read at module load
     -> REQUIRES restart (still true in general)
     Any plugin that reads its page assets at module top-level
       (const x = readFileSync('...html'))
     caches them once; editing them won't show until the module is
     re-imported (restart dsh web, or reload the plugin entry).

     NOTE FOR dsh-chat (this project): its public/*.html and gui.js are
     NOW read from disk on EVERY request (the live-read change), so
     editing THOSE files needs no restart at all - just a browser
     refresh. Only still-true-tier-3 for dsh-chat: editing
     index.mjs (server code) needs one plugin reload/restart to take
     effect.

SO, TO SHOW EDITS WITHOUT RESTARTING
------------------------------------
  * Static dist files (files served from the built frontend folder):
    save then hard-refresh the browser - no restart needed.
  * dsh-chat pages (public/index.html, public/gui.js, free-chat.html):
    already live-read - save, refresh browser, done. No restart.
  * dsh-chat server code (index.mjs): edit + ONE plugin reload/restart
    (touch cordis.patch.yml or restart dsh web).
  * Other plugins that read assets at module load: either
      (a) touch/save cordis.patch.yml after each edit so the loader
          re-imports the plugin module, or
      (b) change the plugin to read its assets per-request (recommended
          for local dev) - this is exactly what we did for dsh-chat.
  * Server logic / new NPM deps / code in any index.mjs: restart dsh web.

============================================================
WHY NOT A DSH PLUGIN?
============================================================
dsh plugins can expose HTTP routes, browser UI, etc. - but a plugin runs
AFTER dsh web is already up. Autostart and "hide the console, restart on
crash" are PROCESS-LEVEL concerns that have to wrap dsh web itself,
before/around it. That is exactly what this helper does, which is why it
lives outside the dsh profile as a normal PowerShell/VBS helper rather
than a dsh plugin.
