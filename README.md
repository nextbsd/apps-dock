# Dock

The Dock (`Dock.app`, formerly `DockWM.app`) is a small GNUstep/AppKit
dock-style window manager shell inspired by WindowMaker.

It supports two inputs:

- Dropping application bundles or executable paths from GNUstep tools such as
  apps-gworkspace onto the dock.
- Discovering small X11 top-level windows, including common WindowMaker
  dockapps, and reparenting them into an X11 dock host.

The Dock has no Settings or Quit items of its own for now: right-clicking
its top tile shows nothing, and an app's menu has no Settings…. Where this
README names a tab of **Settings** (Dock, Appearance, Behavior,
Applications, Extras), that is the Dock's Settings window, which nothing
opens until its settings find a home. They are still read from the `Dock`
defaults domain (`DockAllowsGaps`, `DockKeepsMissingApplications`,
`DockExtrasHidden`, …; `GSUseIconManager` in `NSGlobalDomain` and in an
app's own domain): set one with `defaults write` and restart the Dock.

The Dock's look is a desktop setting, `NBDockStyle` (Workspace Preferences →
Desktop → Dock style, resolved as nextbsd-theme's `NBDesktopSettings.h`
says: the user's choice in `NSGlobalDomain`, else the theme's default):
`nextstep`, a tile (common_Tile) behind each icon and no separators, the
NextBSD theme's default; `mac`, separators between the sections on a
see-through, rounded panel; or `tiling`, clear, with the separators. The Dock
follows a change at once (`org.nextbsd.DesktopSettingsChanged`).

## NextBSD WindowServer

The Dock also runs on NextBSD's WindowServer (the `nextbsd` GNUstep backend),
where there is no X display. Running apps are found with `kern.proc` where
`/proc` isn't mounted. The X11 dock host and dockapps are X11-only.

What X11DockManager does under X11, `WSDockManager` does here, through
WindowServer's Dock connection (`WS_CONNECT_DOCK`, see "The Dock" in
apps-windowserver's README). It's built when pkg-config finds
`WindowServerClient`; elsewhere the Dock is built for X11 alone.

- **Window lists:** an app's menu starts with its windows, front to back,
  the key window checked and minimized ones marked with a diamond; choosing
  one brings it forward, or restores it. The Restore submenu lists the
  minimized windows, as under X11. WindowServer tells the Dock when the
  list changes, so nothing is polled, and an app that puts up its first
  window gets its Dock item right away.
- **Activating an app** brings its windows forward; if all of them are
  minimized, it restores them.
- **Minimized windows in the Dock:** with WindowServer's `MinimizeIntoDock`
  default on, minimized windows become Dock items after the running apps,
  each a live preview of the window with its app's icon in the corner, and
  one click restores it. WindowServer then draws no tiles of its own. The
  Dock's Hide Miniwindows setting is for X11 only.
- **GSIconManager** is registered again: app badges (`NSDockTile`) and
  attention requests (`-requestUserAttention:`) reach the Dock. Asked where
  to put an app icon window or miniwindow, the Dock answers with the
  window's own frame.
- **Layout:** the Dock is a column or row on one screen edge, the right
  edge unless set otherwise (see "Placement" below). Along it, top to
  bottom in a column or left to right in a row: the Workspace tile, pinned
  apps, running apps, minimized windows (each section set off by a
  separator, turned across a row), a flexible gap that takes drops, the
  status area for Dock extras, and the Recycler last, at the bottom of a
  column or the right end of a row. When the column or row is full, tiles
  shrink.
- **Position on screen** (`DockAlignment`): **Centered** (`center`, the default, as on
  macOS) puts the Dock in the middle of its edge, as long as what's in it,
  so it grows and shrinks as apps launch and quit, extras come and go and
  a drop slot opens; a separator sets the extras and the Recycler off from
  the apps, and the flexible gap is just that. **Start of Edge** (`start`)
  fills the whole edge from its start, as before. Centering is for the
  Mac menu style, where the extras are in the menu bar: in the NeXT menu
  style the Dock always fills its edge with the extras at its end, as
  before, and switching the style moves between the two at once. Either
  way the strip the
  Dock reports to WindowServer is its thickness along the whole edge.
  `defaults write Dock DockAlignment start` and a restart of the Dock
  work too.
- **Placement:** the desktop setting `NBDockPosition` (`right`, `left`,
  `top` or `bottom`) picks the edge, looked up as nextbsd-theme's
  `NBDesktopSettings.h` does, for the window mode in effect
  (`NBWindowMode`: stacking or tiling each keep their own,
  nextbsd/nextbsd-theme#8): the user's choice for the mode
  (`NBModeSettings` in `NSGlobalDomain`; in stacking, a plain
  `NBDockPosition` from before counts too), then the active theme's
  `NBModeDefaults` for the mode, then its plain `NBDockPosition`, then the
  right edge. In the NextBSD theme that's the right edge while stacking and
  the bottom while tiling; switching mode in Workspace Preferences moves the
  Dock at once. Change it in
  **Workspace Preferences → Desktop → Dock position** (nextbsd/apps-workspace#54),
  including "Use theme default", which moves the Dock at once. The Dock
  listens for the distributed notification
  `org.nextbsd.DesktopSettingsChanged` (its userInfo's `key` and effective
  `value`), which Workspace posts. `defaults write NSGlobalDomain
  NBModeSettings '{ tiling = { NBDockPosition = top; }; }'` and a restart
  of the Dock work as well.
  `DockPlacement` stays the X11 (Gershwin) setting: there the left and
  right placements (0 to 3) are top or centred, Top Center (4) and Bottom
  Center (5) the rest, and the Dock follows the `DockPlacement` Workspace
  writes beside `NBDockPosition` live too.
  On every edge, menus and Dock extras' panels open beside their tile
  toward the middle of the screen, tooltips point back at the tile, and
  icons bounce away from the edge, into the screen.
- **The Dock's edge for WindowServer:** the Dock reports the edge it fills
  and its thickness (`ws_dock_set_edge()`, on servers with
  `WS_SERVER_DOCK_EDGE`) when it connects and whenever either changes, so
  that window tiling can keep that strip free. `wsctl dock list` shows it.
  A Mac-style menu bar (nextbsd/libs-back#3) isn't built yet; when it is,
  a Dock on the top edge will sit directly below it.

### Dock extras

Dock extras are small status tools in the status area, like Window
Maker's dockapps and macOS's menu extras. Each is a loadable bundle,
`Name.dockextra`, that the Dock loads at start from `~/Library/DockExtras`,
`/Local/Library/DockExtras` and `/System/Library/DockExtras` (the first
bundle with a given `CFBundleIdentifier` wins). Extras run inside the
Dock's process; a misbehaving one is removed by taking it out of the
folder. The interface is in `DockExtra.h`:

- The bundle's principal class conforms to `DockExtra`:
  `-initWithDockHost:`, `-isAvailable` (NO: nothing to show, so no tile),
  `-drawInRect:` (a square of the Dock's cell size), `-toolTip` and
  `-menuForEvent:`; optionally `-dockExtraOpen:` (double-click),
  `-scrollWheel:` and `-dockExtraWillUnload`.
- The Dock is its `DockExtraHost`: the extra calls `-dockExtraNeedsDisplay:`
  when its tile should be drawn again (from its own timer or
  notification; the Dock never polls it) and
  `-dockExtraAvailabilityDidChange:` when its hardware comes or goes.
  `-dockExtra:panelFrameForSize:` places a panel beside the tile, toward
  the middle of the screen, whichever edge the Dock is on.
- `Info.plist`: `CFBundleIdentifier`, `CFBundleName` (shown in the
  settings) and `DockExtraDefaultPosition` (a number: the order until the
  user moves it).
- `DockExtraDrawPlate()` draws the dark rounded plate the bundled extras
  share.

A click shows the extra's menu beside its tile (click to open, click to
choose); an extra that opens something on a double-click gets its menu
once no second click comes. The scroll wheel goes to the extra. Dragging
an extra moves it within the status area; it can't be dragged out of it
or onto the Recycler. The order is saved as `DockExtrasOrder`. Each extra
can be hidden in **Settings → Extras** (`DockExtrasHidden`).

**In the Mac menu style** (`NSMacintoshInterfaceStyle`, the menu bar along
the top) the extras leave the Dock and go into the menu bar, as macOS's
ControlCenter puts its items there (#41): each one is its own
`NSStatusItem` (public `NSStatusBar` API; on WindowServer the backend makes
it a status item slot, nextbsd/libs-back#41, apps-windowserver#97), drawn in
the bar's text colour, left to right Input, Bluetooth, Wi-Fi, Sound,
Battery, then the clock as text ("Thu 19 Nov 00:18", following its 24-hour,
seconds and date settings) at the right end. A click drops the extra's menu
below it, the one its tile's right-click shows, ending with "Open …
Settings"; panels it opens (the calendar, a Wi-Fi password) go below the bar
at its right end. Switching the menu style in Workspace Preferences moves
them between the Dock and the menu bar at once, and a centred Dock shrinks
or grows with them. Hiding an extra (**Settings → Extras**, or a settings
app's "Show … in Dock") hides it from the menu bar.

The order comes from WindowServer's status item priorities, larger further
right: apps' items 0, the system's 1000, the clock 2000. Each extra takes
1000 plus its `DockExtraMenuBarPosition` (Info.plist; else its
`DockExtraDefaultPosition`), so the extras keep their order whichever one
comes or goes, and the extra with `DockExtraMenuBarPriority = clock` takes
2000. The priority goes to the backend's documented
`-[NSStatusItem setStatusItemPriority:]` when it has one. An extra draws
itself there with the optional `-statusItemTitle` (words) or
`-drawStatusItemInRect:color:` and `-statusItemWidthForHeight:` (a glyph);
otherwise the Dock draws its tile in one colour, without the plate. A glyph
also gets an alternate image in the highlighted text colour, for while its
menu is open.

As on macOS, an extra appears by itself only where its hardware is (a
battery, a Wi-Fi radio, a Bluetooth controller, a sound device, two
keyboard layouts or more); the clock is always there. Its menu gives the
quick controls and ends with **Open X Settings…**, which opens the
settings app with the rest (`Bluetooth.app`, `Energy.app`,
`Keyboard.app`, `DateTime.app`, `Sound.app`; `Network.app` once it exists) from
`~/Applications`, `/System/Applications`, `/Local/Applications` or
`/Network/Applications`, or brings it forward when it's running. While
the app isn't installed the item isn't there. Extras add it with
`DockExtraAddSettingsItem()` (`DockExtra.h`).

#### Showing and hiding extras from the settings apps

The settings apps' **Show X in Dock** checkboxes (nextbsd/apps-settings)
turn extras on and off, live, the way macOS's "Show X in menu bar" does.
The Dock owns the list (`DockExtrasSettings.h` has the names):

- **Where:** the Dock's defaults domain `Dock`, key `DockExtrasHidden`,
  an array of the hidden extras' `CFBundleIdentifier`s. An extra that
  isn't in it is shown.
- **Asking:** another app doesn't write the list while the Dock runs; it
  posts the distributed notification `org.nextbsd.Dock.SetExtraHidden`
  with userInfo `identifier` (string) and `hidden` (boolean). The Dock
  loads or unloads the extra at once and saves the list.
- **Answer:** whenever the list changes, or a request comes in, the Dock
  posts `org.nextbsd.Dock.ExtrasChanged` with userInfo `hidden` (the new
  list), so every checkbox (and the Dock's own Settings → Extras) follows.
- **No Dock:** an app that hears no answer within two seconds writes
  `DockExtrasHidden` itself; the Dock reads it when it starts.

The identifiers: `org.nextbsd.dockextra.wifi`, `.bluetooth`, `.battery`,
`.sound`, `.input`, `.clock`. apps-settings' `Shared/NBDockExtra` is the
apps' side.

The status area exists only where the Dock fills its screen edge (on
WindowServer), so extras are loaded there only. It runs along the Dock,
down a column or across a row; nothing in it assumes the right edge.

For screenshots and testing, `defaults write Dock DockExtrasTestData
YES` makes extras whose hardware is missing show made-up data (marked
"[test data]" in their tooltips). A dictionary instead of YES sets the
values: `BatteryPercent`, `BatteryCharging`, `BatteryOnAC`, `WiFiSSID`,
`WiFiRSSI`, `WiFiConnected`.

The extras that ship with the Dock are built from `Extras/` and installed
into `$(GNUSTEP_LIBRARY)/DockExtras` with it.

Bundled extras:

- **Wi-Fi** (`WiFi.dockextra`): signal bars for the network wland has
  joined, or empty bars when it hasn't; the network in the tooltip. The
  state is wland's `State:/Network/Interface/<if>/AirPort` in
  SystemConfiguration, watched with SCDynamicStore notifications. The
  menu lists the networks of the last scan (scanned again when the menu
  opens, if the list is older than 20 seconds) and joins one: open
  networks directly, secured ones after asking for the passphrase in a
  panel. Scanning, joining and disconnecting go through `wlan(8)`, the
  supported way for the desktop to drive wland. WPA-Enterprise networks
  are listed but joined with `wlan connect --eap`. No radio: no tile.

- **Bluetooth** (`Bluetooth.dockextra`): the Bluetooth rune, dimmed while
  Bluetooth is off, with a dot when a device is connected (named in the
  tooltip). The menu turns Bluetooth on or off and lists the paired
  devices, the connected ones checked: choosing one connects or
  disconnects it. **Open Bluetooth Settings…** opens Bluetooth.app for
  pairing, nearby devices and headset audio. It talks to bluetoothd as
  Bluetooth.app does, over its MIG interface (`org.nextbsd.bluetooth`,
  with `BTClient.c` and `mig/` copied from apps-settings), and follows its
  `org.nextbsd.bluetooth.*` notify(3) keys and `State:/Bluetooth`. No
  controller or no bluetoothd: no tile (it looks again every 10 seconds).

- **Input** (`Input.dockextra`): the keyboard layout in use by its short
  name (EN, ΕΛ, РУ); the menu lists the layouts and switches to the one
  chosen, through WindowServer (`WS_MSG_SET_KEYBOARD_LAYOUT`), and follows
  `WS_EVENT_KEYBOARD_LAYOUT`, so the switching shortcut shows at once.
  Shown with two layouts or more. Keyboard.app sets the layouts. (It was
  built with Keyboard.app in apps-settings before.)

- **Battery** (`Battery.dockextra`): the charge as a battery glyph, a
  bolt on the power adapter, and the percentage (**Show Percentage**,
  `DockExtraBatteryShowsPercentage`); the tooltip has the time remaining
  or until full, and the menu the power source and condition. The data is
  IOPowerSources (`IOPSCopyPowerSourcesInfo`) from powerd; changes come as
  the notify(3) keys powerd posts, the ones
  `IOPSNotificationCreateRunLoopSource` listens to, so nothing is polled.
  No battery (desktops, VMs): no tile.

- **Sound** (`Sound.dockextra`): a speaker showing the volume and mute
  of the output the system plays to: a kernel device (`pcmN`, through its
  mixer) or a Bluetooth headset, which bluetoothd plays to through a
  `virtual_oss` (`/dev/dsp.btN`). A headset is shown by its name, and its
  volume is its own (AVRCP absolute volume, set through bluetoothd);
  mute, and the volume of a headset without absolute volume (6 dB
  steps), are its `virtual_oss`'s. The extra reads the devices with
  `SNAudio.c`, copied unchanged from Sound.app (nextbsd/apps-settings
  `Sound/`), and bluetoothd's MIG stubs from the Bluetooth extra's `mig/`.
  A click opens a panel with a volume slider, Mute and the output; the
  right-click menu has Mute, volume steps, the outputs and **Open Sound
  Settings…**. Scrolling over the tile changes the volume. bluetoothd's
  notifications bring a headset at once; OSS posts nothing, so the volume
  is read every 1.5 seconds. With no output at all there's no tile, and
  it looks again every 10 seconds. A headset takes the output when it
  connects; choosing a kernel device sets `hw.snd.default_unit`, which
  needs root for now. A headset's `virtual_oss` that has lost the headset
  answers nothing, and anything opening its devices would wait with it,
  so every call to one runs in a child process and is given up on after
  400 ms: the Dock never waits on it.

- **Date and clock** (`Clock.dockextra`): the time with the day and
  date, digital or analog, fitted to the cell. A click shows a month
  calendar (the arrows, the scroll wheel or Page Up/Down change the
  month; Escape or another click on the tile closes it); the right-click
  menu sets digital or analog, 24-hour, seconds and the date
  (`DockExtraClockAnalog`, `DockExtraClock24Hour`,
  `DockExtraClockShowsSeconds`, `DockExtraClockShowsDate`). It wakes on
  the minute, or the second, from a timerfd armed for the wall clock's
  next boundary with `TFD_TIMER_CANCEL_ON_SET`, so setting the clock
  redraws it at once. Time zone changes come from notify(3)
  (`com.apple.system.timezone`, which Date & Time.app's helper posts),
  and from `/etc/localtime`'s change time, read on each tick. The zone
  is the one `/var/db/zoneinfo` names, made GNUstep's default: GNUstep's
  own guess comes from ICU, which never looks again. Date &
  Time.app's Clock tab sets the same four keys and posts the distributed
  notification `org.nextbsd.SettingsChanged` (userInfo `domain` `Dock`,
  `keys`); the extra reads them again and redraws, and posts the same
  when its own menu changes them. **Open Date & Time Settings…** opens
  Date & Time.app (`DateTime.app`).

## Build

```sh
make
```

## Run

```sh
./Dock.app/Dock
```

### From DockWM

The app was `DockWM.app` (process `DockWM`). Installing `Dock.app` removes a
`DockWM.app` from the same domain, so that two Docks never start, and the
session starts `Dock.app` (nextbsd/apps-loginwindow). The Dock's defaults
domain is its process name, `Dock`: the first time it runs, it takes the
values of the old `DockWM` domain that the new one hasn't got and marks
that with `DockMigratedFromDockWM`; the old domain is left as it was. Other
apps that read or write the Dock's settings use the `Dock` domain
(Workspace's Dock position, the settings apps' "Show … in Dock" and the
clock's settings).

The AppKit dock accepts filesystem drops. A companion X11 override-redirect host
window is created next to it for dockapps and other small X11 clients.

The dock remains visible on every workspace. Run the workspace regression
check with `sh Tests/run-all-workspaces.sh` (requires Xvfb, Window Maker,
`wmctrl`, `xprop`, and `xwininfo`). It switches among three workspaces on an
isolated display and checks that the dock stays visible.

Pinned applications that are moved or removed leave a question-mark placeholder
in their saved position by default. The tooltip identifies the missing app, and
its launch arguments and behavior settings are retained. The Dock checks for
changes every 15 seconds and restores the icon if the original path becomes
available again.

Disable **Keep placeholders for missing applications** in **Settings → Behavior**
to remove missing entries instead.

The missing-application regression checks can be run with:

```sh
sh Tests/run-missing-applications.sh
```

These checks require `clang`, GNUstep, and `xvfb-run`.

X11 application icons are cached when received from their windows and reloaded
by application path when the dock restarts, including older pinned entries.
GNUstep applications continue to use their bundle icons. If an X11 cache file
is missing or unreadable, the dock uses its normal icon lookup until the app
provides a new icon. Run `sh Tests/run-x11-icon-persistence.sh` to check this
behavior under Xvfb.

Application exits are checked every half second, independently of the slower
application discovery and missing-file scans. Closing a window keeps its app
running in the dock if the process is still alive. Run the exit regression
checks with `sh Tests/run-application-exits.sh`.

Window discovery runs in small batches so that full X11 sweeps yield to clicks
and icon-manager requests. Each batch handles at most eight windows and checks
an 8 ms budget between windows; a single slow X server reply can exceed that
budget. Newly mapped windows still use the event-driven discovery path.

Run the X11 regression tests with an installed GNUstep GUI backend and Xvfb:

```sh
sh Tests/run-window-scan.sh
sh Tests/run-x11-efficiency.sh
sh Tests/run-miniwindow-suppression.sh
```

The window-scan test creates 128 clients and verifies main-loop responsiveness,
complete discovery without duplicate classification, coalesced refreshes,
known-window updates, destruction during a scan, and discovery of new clients
while a sweep is active.

Icon suppression uses the `_GNUSTEP_WM_ATTR` application-icon and miniwindow
style bits, regardless of window dimensions. Miniwindow unmapping respects the
miniwindow preference. Window Maker application tiles are identified by the
`_WINDOWMAKER_APP_ICON` property (type `WINDOW`, one owning client window ID),
published by the companion gs-wmaker change. When that property is absent,
The Dock falls back to a validated Window Maker noticeboard plus an anonymous
override-redirect root window with the icon event mask and XDND support.
Named clients, transient windows, and containers of ordinary windows are
excluded from both fallback paths. If both attribute matches fail, exact
48×48 or 64×64 dimensions are used as the final fallback. The explicit marker
and legacy attribute matches do not require those dimensions. Both fallback
paths are heuristic.
Dockapp discovery uses explicit `DockApp` class and
`WM_HINTS` icon-window metadata instead of size heuristics.

Run `sh Tests/run-overlay-preservation.sh` to check preservation of unmarked
overlay windows, including windows with XDND support and icon-like event masks.
Run `sh Tests/run-windowmaker-icons.sh /path/to/gs-wmaker/src/wmaker` to verify
that Window Maker publishes the marker and the Dock unmaps the resulting tile,
then removes the marker and verifies the legacy fallback on the same tile.
This test uses an isolated display and requires `xdotool`.

Before launching an application, the Dock saves `GSSuppressAppIcon = YES` in that
application’s defaults domain, preserving its other preferences. This applies
to app bundles, executables, and applications launched through desktop files;
no suppression argument is added to the command line. The Dock also sets this
default for itself before creating its application object.

At startup, the Dock writes `GSUseIconManager` to the GNUstep global defaults
domain. It defaults to enabled. Turn off **Settings → Behavior → Use icon
manager for all applications** to disable it; the global choice is saved
immediately and retained across restarts. Applications read this setting when
starting, so restart running applications to pick up a change. Per-app choices are available in **Settings → Applications → Icon manager**:
**Use global setting** (the default), **On**, or **Off**. An explicit app choice
takes priority over the global switch and survives Dock restarts. Choose
**Use global setting** to remove an override. Other app preferences are preserved.
The Dock also rejects incoming application icon-manager updates when disabled,
including direct messages from apps that bypass GNUstep's preference check.
This does not pause an embedded X11 dockapp's own drawing or disable process
tracking. Restart applications after changing the setting to update their own
icon-manager connections.

Run `sh Tests/run-icon-manager-preferences.sh` to check defaults, persistence,
and per-application overrides using an isolated defaults database.

The Workspace tile comes first, then the kept applications, then the
running applications that aren't kept. A kept application's tile stays
whether or not the application runs (without a running dot when it
doesn't, and a click launches it); an application that isn't kept shows
only while it runs. Every running application has a tile.

Every application tile's menu (not the Workspace tile's) has **Keep in Dock**
and **Remove from Dock**, never checked. Keep in Dock moves the tile to the
kept applications. Remove from Dock moves a running application's tile to
the running applications, where it stays until the application quits, and
removes the tile of one that isn't running. Choosing the one that already
applies does nothing. Dragging an application from Workspace (or a
running application's tile) into the kept applications keeps it there:
while the drag is over the kept applications they open an empty slot where it
will go, right after the Workspace tile when nothing is kept yet. Dragging a
kept tile to the Recycler or out of the Dock removes it the same way. The
kept applications are saved as `DockApplications` in the Dock's defaults. Older
Docks saved a `GSDockKeepInDock` value in each application's defaults domain
and hid running applications with it; the Dock removes that value when it
next sees the application. This is separate from **Open At Login** and does
not quit the application.

Run `sh Tests/run-keep-in-dock.sh` to check the menu, the running and kept
sections, and keeping an app again by dropping it into the dock.

### Keeping applications from other programs

The Dock owns `DockApplications`; other programs don't write it. To keep
applications in the Dock, post the distributed notification
`org.nextbsd.Dock.KeepApplications` with a `paths` array of application
bundle paths in its userInfo. The Dock keeps them in that order at the
end of the kept applications, the same as dropping them into the kept
applications' slot there: an application that's already kept stays where
it is, and a running application that isn't kept moves up from the
running applications with its running dot and windows. Paths that aren't
absolute paths to an `.app` bundle on disk are ignored. The Dock saves
the list as it does after a drop. Nothing answers the notification; if
the Dock isn't running, the request is lost.

```objc
[[NSDistributedNotificationCenter defaultCenter]
  postNotificationName:@"org.nextbsd.Dock.KeepApplications"
                object:nil
              userInfo:[NSDictionary dictionaryWithObject:
                          [NSArray arrayWithObjects:
                             @"/Applications/Terminal.app", nil]
                                                   forKey:@"paths"]
    deliverImmediately:YES];
```

Workspace's **File → Add to Dock** (and the same command in a File
Viewer's context menu) sends it for the selected applications
(nextbsd/apps-workspace#59).

Each running application's context menu includes **Restore**. It activates the
application even when no minimized-window list is available. GNUstep apps are
contacted through NSWorkspace; X11 clients are raised through the window manager.
If a running external app has no managed windows, its launch command is used to
request a window. When minimized windows can be identified, a single window is
restored directly; for several windows, the submenu lists titles and **Restore All**.
Double-clicking a running app performs the same action as Restore (Restore All
when several windows are minimized). Apps that are not running still launch.
The single-click activation preference uses the same behavior.
Miniwindow suppression remains in effect throughout restoration.
GNUstep application entries find windows by their running process identifiers;
individual X11 entries restore their associated window. GNUstep miniwindow icons
and windows that are merely unmapped are excluded.

Run `sh Tests/run-restore-menu.sh` to check menu actions and window restoration
on an isolated X display. Run `sh Tests/run-chrome-restore.sh` to check a real
Chrome window under Window Maker; it requires `google-chrome`, `wmaker`,
`wmctrl`, `xdotool`, and Xvfb and uses a temporary Chrome profile.

Run `sh Tests/run-recycler-drag.sh` to exercise a real folder drag from a
separate GNUstep process across an app icon and onto the Recycler. It repeatedly
leaves and re-enters the dock with the button held, with tooltips, magnification,
and native event processing enabled. It uses a temporary folder and trash directory on an isolated display and requires Xvfb,
Window Maker, `wmctrl`, and `xdotool`.

Run `sh Tests/run-recycler-drag.sh --application` to check that dragging an
`Ink.app` test bundle across the icon windows pins it without crashing. Both
drag tests drain an autorelease pool between events to exercise normal
application object lifetimes. The Dock retains the shared drag pasteboard while
its dock view exists, preventing it from being destroyed as a drag crosses
icon windows. No GNUstep GUI library changes are required.

### Icon windows and bounce animation

Application icons, the GNUstep tile, the Recycler, and application state dots use
separate shaped, non-focusable windows. There is no visible dock background
or border. Two thin separator windows bracket the unpinned application section
when it contains apps. State dots remain stationary while icons bounce and are
removed when their state no longer matches the selected indicator mode.
Icon windows move through a large hop and a smaller settling hop, away
from the Dock's edge: up from the bottom, down from the top, and on
WindowServer, sideways from a left or right edge (X11 side docks hop up). Attention requests repeat
until acknowledged. Bounce frames move the existing buffered windows without
redrawing icons or rebuilding their shapes. The drop marker window exists only
during a drag. Rendered overlays are cached: unchanged refreshes and exposure
events reuse their images, while icon, badge, label, and size changes refresh
the affected surfaces. Existing animation preferences remain compatible.

App names appear in compact tooltip windows beside the hovered icon, toward the
interior of the screen. Labels stay within the screen edges. A small arrow points toward the hovered
icon, with transparent space around the arrow.

Icons receive clicks, context menus, hover, and drag input directly. Dots,
tooltips, separators, and the drag insertion marker pass pointer input through. On X11,
alpha-derived bounding shapes expose the desktop without requiring a compositor.
The invisible layout owner remains for placement and screen-space reservation.

Run `sh Tests/run-icon-windows.sh` with an available Xvfb server to check native
window creation, desktop visibility, dot lifecycle, pointer activation (using XTest), bounce movement,
reordering, and window cleanup. The test requires the XTest development library, Window Maker, and `xprop`.
It runs both on bare Xvfb and under Window Maker, checking recovery after native
restacking hides mapped icons behind the dock and ensuring repairs do not
generate a repeating configure-event loop.
Native event processing also continues during modal alerts and menu tracking,
so window-manager restacks cannot leave icons covered while those loops run.
The icon-window test checks recovery with a modal alert open.

Gaps can be enabled with **Settings → Dock → Allow gaps (NeXT style)**
(off by default). In **Applications**, select a pinned app and enable
**Gap before app** to leave one empty tile-sized slot before it. Gap positions
are saved with pinned apps; turning gaps off compacts the dock without erasing
them. The option works in horizontal and vertical docks.

**Appearance → Use common_Tile** draws a tile behind each icon while keeping
the surrounding dock transparent. The tile itself retains its image opacity.
