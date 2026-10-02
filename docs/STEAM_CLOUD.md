# Steam Cloud saves

Madeira syncs the save files of installed Steam games with the signed-in
account's Steam Cloud. It uses the app's own Steam connection (the one the
library and downloads use, `docs/STEAM_LIBRARY.md`), so it only ever runs
while no game session holds the account.

`env.MADEIRA_STEAM_CLOUD = 0` turns the feature off.
`env.MADEIRA_STEAM_CLOUD_AUTO = 0` keeps the comparison and the game page
but copies nothing in either direction unless the user asks there.

## When it runs

- Once when Madeira starts, for every installed Steam game.
- When a Steam game's details page opens, and on its **Sync now** button.

Madeira cannot close a game: the user leaves one by quitting the app. So
there is no sync at exit. What was played is uploaded at the next start.

## What it does

1. Asks Steam for the app's cloud file list (`Cloud.GetAppFileChangelist`).
2. Maps each cloud path to a file of Madeira Dock's Wine prefix, through
   the `%Root%` placeholder of the path and the app's `ufs` product info:
   `GameInstall` is the game's folder, `WinAppDataLocalLow` and its
   siblings are under the Windows user folder (the one Wine names after
   `$USER`), and a path with no placeholder is under Steam's
   `userdata/<account>/<app>/remote`. Names are matched without regard to
   case. A path that would leave its folder is refused.
3. Compares SHA-1 and size, and also lists files matching the app's save
   patterns that the cloud does not have.
4. Looks each file up in its record of what was last identical on both
   sides (`steam-cloud-sync.json` in Application Support):
   - changed on one side only, or new on one side: copied to the other;
   - changed on both, or different with no record: **left alone**. The
     start-up check names the games, and the game's page shows each such
     save with both dates and sizes and asks which side to keep;
   - present in the record but now missing on one side: left alone (never
     deleted on the other side, never brought back).

## Safety

- A downloaded file is checked against the SHA-1 in Steam's list before
  anything is written.
- A file a download replaces is first copied to
  `Application Support/Madeira/steam-cloud-backups/<app>/<time>/`.
- Steam keeps no copy of a cloud file an upload replaces, which is why an
  upload over a differing cloud file only happens on the user's choice or
  when the record shows the cloud copy is the one this device last synced.
- Nothing is ever deleted in the cloud.

## Limits

- No sync while a game runs, and none between pressing Play and the game
  starting: a cloud save newer than the device's that had not come down yet
  becomes a choice at the next start.
- A game whose Windows saves are redirected by a `rootoverrides` entry for
  Windows is compared and downloaded, but new device files there are not
  uploaded.
- Encrypted cloud files are not supported.
- Log tag `[steam-cloud]`: App IDs, counts, and save file names under
  their Steam folder names. Never account data or the Windows user name.
