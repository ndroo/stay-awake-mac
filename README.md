# Stay Awake

Stay Awake is a tiny native macOS menu-bar app that prevents your Mac from going to sleep without changing System Settings or leaving a Terminal window open.

[Download the latest release](https://github.com/ndroo/stay-awake-mac/releases/latest/download/Stay-Awake.zip)

## Features

- Keep your Mac awake indefinitely.
- Keep it awake for a custom number of hours, including decimals such as `1.5`.
- Optionally prevent the screen saver and display sleep during an active session.
- See the remaining time from the menu bar.
- End a session immediately with **Allow Sleep Now**.
- Restore an unfinished session when the app is reopened.
- No network connection, administrator access, or Accessibility permission required.

## Install

1. Download and unzip [Stay-Awake.zip](https://github.com/ndroo/stay-awake-mac/releases/latest/download/Stay-Awake.zip).
2. Drag **Stay Awake.app** into your Applications folder.
3. Open the app. A moon icon will appear in the menu bar.

The downloadable app is ad-hoc signed but is not notarized by Apple. If macOS blocks the first launch, Control-click **Stay Awake.app**, choose **Open**, and confirm. On some macOS versions, you may instead need to open **System Settings → Privacy & Security** and select **Open Anyway** after the first blocked attempt.

## Use

Click the moon icon in the menu bar, then choose:

- **Prevent Sleep Indefinitely** to remain awake until you stop the session or quit the app.
- **Prevent Sleep for Custom Hours…** to enter a duration.
- **Also Prevent Screen Saver & Display Sleep** to keep the screen active during sleep-prevention sessions.
- **Allow Sleep Now** to end the current session.

The icon changes to a sun while a session is active.

## How it works

Stay Awake uses Apple's IOKit power-management assertions. A normal session prevents idle system sleep while still allowing the display to turn off. The optional screen setting also prevents idle display sleep and periodically reports user activity to suppress the screen saver.

The app does not simulate keyboard or mouse input, modify your permanent power settings, collect data, or connect to the internet.

## Limitations

Stay Awake prevents sleep caused by inactivity. Your Mac can still sleep when you:

- close a MacBook's lid;
- choose Sleep from the Apple menu;
- run critically low on battery; or
- encounter a thermal or other system safety condition.

## Build from source

Requirements:

- macOS 13 or newer
- Xcode Command Line Tools or Xcode

```bash
git clone https://github.com/ndroo/stay-awake-mac.git
cd stay-awake-mac
./build.sh
```

The script creates a universal Apple Silicon and Intel app at `dist/Stay Awake.app` and a distributable archive at `dist/Stay-Awake.zip`.

## License

[MIT](LICENSE)
