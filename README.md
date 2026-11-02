<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/icon-dark.png">
    <img src="assets/icon.png" width="128" alt="Spoof icon">
  </picture>
</p>

<h1 align="center">Spoof</h1>

<p align="center">Set your iPhone's location from your Mac.</p>

<p align="center">
  <a href="https://github.com/danielrltan/spoof/releases/latest/download/Spoof.dmg">
    <img src="assets/download.png" width="400" alt="Download for Mac">
  </a>
</p>

<p align="center"><sub>Free. No Xcode needed. Needs an Apple silicon Mac on macOS 26, an iPhone on iOS 17.4 or newer and a cable.</sub></p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/screenshot-dark.png">
    <img src="assets/screenshot.png" alt="Spoof planning a trip across Paris">
  </picture>
</p>

## Set up once

1. Open `Spoof.dmg` and drag Spoof to Applications.
2. Open Spoof. Your Mac blocks it the first time because it isn't notarized by Apple. Click **Done**, not Move to Trash. Then go to **System Settings > Privacy & Security** and click **Open Anyway**.
3. Plug in your iPhone, unlock it and tap **Trust**.
4. On the iPhone, go to **Settings > Privacy & Security > Developer Mode**, turn it on and restart. If it isn't there, keep the iPhone plugged in with Spoof open and look again.

Keep the iPhone unlocked the first time you use Spoof after each restart of the phone.

## Use it

1. Search in the sidebar or click the map.
2. Click **Teleport** to jump there, or **Walk**, **Bike** or **Drive** to travel there by road.
3. Click **Real GPS** at the top right when you're done. Your phone can take a minute to find itself again.

You can unplug after a teleport and the location stays. Keep the phone plugged in during a trip, or turn on **Cable-free trips** at the bottom of the sidebar first.

To plan a longer trip, click **Start trip here** or **Add stop**, then choose how you travel, how long each leg takes and how long you stay.

## Good to know
- Driving routes and speed limits come from [OpenStreetMap](https://www.openstreetmap.org/copyright) through the public [Valhalla](https://valhalla.github.io/valhalla/) server, so the start and end of each drive are sent there. Walking and cycling routes come from Apple Maps.
- To talk to your iPhone, Spoof uses [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) and downloads Apple's developer disk image from a [community mirror](https://github.com/doronz88/DeveloperDiskImage). If your Mac has Xcode 27 or newer, Spoof uses Xcode's tools instead.

## Build it yourself

Building Spoof needs Xcode 27, even though running it doesn't.

```sh
brew install xcodegen
pip install dmgbuild
scripts/release.sh
```

That builds `Spoof.dmg`, with the helper from `helper/` inside it.

`cli/spoof.swift` is a command-line version that does need Xcode: `swiftc cli/spoof.swift -o spoof`, then `./spoof set "Paris"`.

Spoof is under the [MIT License](LICENSE). The helper in `helper/` is a separate program under the [GPL-3.0](helper/LICENSE), because pymobiledevice3 is.
