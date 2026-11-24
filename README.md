# What’s in My Background

A native macOS dashboard for the LaunchAgents you maintain. Your account runs jobs from other apps too, so process ownership alone cannot identify your scripts. Add a job to the watchlist once; the main window shows its state and schedule without mixing in vendor helpers. The watchlist stays on this Mac.

## Run

Requires macOS 14 or later and the Xcode Command Line Tools. No packages, administrator password, network connection or background helper required.

```sh
bash scripts/build-app.sh
open 'dist/What’s in My Background.app'
```

For regular use, drag the built app to `~/Applications`. The build is ad-hoc signed for local use, not notarized for distribution. Open the app from Finder or Spotlight.

The curtain fox is original vector artwork in [Resources/CurtainFox.svg](Resources/CurtainFox.svg). The build renders it at the native Finder and Dock icon sizes using macOS tools.

## Manage a job

Add an installed job from `~/Library/LaunchAgents` that you recognize. Adding or forgetting a label only changes your watchlist; neither starts nor stops the job. The app refreshes when it becomes active, every 15 seconds while active, or when you press Command-R. Scheduled jobs can be loaded without having a running process.

- **Stop until login** unloads the job from your login session. This prevents `KeepAlive` from immediately relaunching it and pauses scheduled runs. The startup file stays installed for the next login.
- **Load now** registers a stopped job again. `launchd` decides whether to run it immediately or wait for its schedule.
- **Remove from startup** unloads the job and moves its plist to `~/Library/Application Support/WhatsInMyBackground/Removed Startup Items/`. It does not delete the script, logs or configuration.
- **Restore startup** returns the archived plist to `~/Library/LaunchAgents` and loads the job. It won't overwrite a new file that already uses its name.

Only user-owned, directly installed job definitions can be managed. System daemons, jobs in other users’ sessions, arbitrary shell processes, cron jobs and app-managed login items are outside this app's scope. Nothing runs as root. Keep the original installer or source for any jobs you want to reproduce on another Mac.

## Verify the safeguards

Run `bash scripts/test-guards.sh` in a macOS login session. It uses a disposable directory and checks that an untracked job, a conflicting archive and a symlink substituted after selection cannot be archived. It does not load or stop any services.
