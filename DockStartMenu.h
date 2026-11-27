/*
 * Dock
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

#import <AppKit/AppKit.h>

/*
 * The Windows style's Start menu: the taskbar's cube and a tap of the
 * Start (Command) key on its own open it (WindowServer sends the tap to a
 * Dock that shows a Start menu). A search field that finds apps, settings
 * and recent files as you type; the pinned apps; All apps, every app in
 * /System/Applications, /Local/Applications and ~/Applications; recent
 * files, from Workspace's history; and the user, with a power menu (Log
 * Out, Restart, Shut Down), which asks loginwindow through its control
 * socket. It closes on Escape, on a click elsewhere, and once something
 * opens.
 *
 * The pinned apps are the Dock's StartPinnedApplications default (app
 * paths), else a list of NextBSD's own apps; those not installed are left
 * out.
 */
@interface DockStartMenu : NSPanel
{
  id _target;
  SEL _openFileViewer;
  NSTextField *_search;
  NSView *_content;
  BOOL _allApps;
}

/* target: something that opens a File Viewer when sent action. */
- (id) initWithTarget: (id)target fileViewerAction: (SEL)action;
/* Open above the taskbar, centred on the screen, or close if open. */
- (void) toggle;
- (void) close;

@end
