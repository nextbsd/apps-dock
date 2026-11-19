/*
 * DockWM
 *
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Showing and hiding the Dock's extras from other apps, the way a macOS
 * settings pane's "Show X in menu bar" checkbox does.
 *
 * The Dock owns its extras and the list of hidden ones:
 *
 *   domain  DockWM (the Dock's own defaults)
 *   key     DockExtrasHidden: an array of extras' CFBundleIdentifiers.
 *           An extra that isn't in it is shown (when its hardware is
 *           there: see DockExtra.h, -isAvailable).
 *
 * The extras' identifiers are below. Another app never writes the list
 * while the Dock runs; it asks the Dock, with a distributed
 * notification (NSDistributedNotificationCenter, deliverImmediately):
 *
 *   org.nextbsd.Dock.SetExtraHidden
 *       userInfo: identifier (NSString), hidden (NSNumber, a BOOL)
 *
 * The Dock shows or hides the extra at once, saves the list, and
 * answers, as it does whenever the list changes (its own Settings ->
 * Extras too):
 *
 *   org.nextbsd.Dock.ExtrasChanged
 *       userInfo: hidden (NSArray, the new DockExtrasHidden)
 *
 * so every "Show ... in Dock" checkbox can follow. An app that hears no
 * answer within a couple of seconds may assume no Dock is running and
 * write DockExtrasHidden itself; the Dock reads it when it starts.
 *
 * The settings apps' side of this is NBDockExtra (apps-settings
 * Shared/NBDockExtra.h), which spells the same names; keep the two in
 * step.
 */

#ifndef _DOCK_EXTRAS_SETTINGS_H_
#define _DOCK_EXTRAS_SETTINGS_H_

#define DockExtrasDefaultsDomain	@"DockWM"
#define DockExtrasHiddenKey		@"DockExtrasHidden"

#define DockSetExtraHiddenNotification	@"org.nextbsd.Dock.SetExtraHidden"
#define DockExtrasChangedNotification	@"org.nextbsd.Dock.ExtrasChanged"

/* The extras that ship with the Dock. */
#define DockExtraWiFiIdentifier		@"org.nextbsd.dockextra.wifi"
#define DockExtraBluetoothIdentifier	@"org.nextbsd.dockextra.bluetooth"
#define DockExtraBatteryIdentifier	@"org.nextbsd.dockextra.battery"
#define DockExtraSoundIdentifier	@"org.nextbsd.dockextra.sound"
#define DockExtraInputIdentifier	@"org.nextbsd.dockextra.input"
#define DockExtraClockIdentifier	@"org.nextbsd.dockextra.clock"

#endif
