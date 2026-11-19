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

/*
 * DockExtrasController finds the Dock extras (.dockextra bundles, see
 * DockExtra.h), loads the ones the user hasn't hidden, keeps their order,
 * and is the extras' DockExtraHost. Its delegate (the AppController)
 * puts the shown extras in the Dock's status area.
 *
 * Defaults: DockExtrasOrder (identifiers, top to bottom), DockExtrasHidden
 * (identifiers; other apps change it through the Dock, see
 * DockExtrasSettings.h), and DockExtrasTestData (YES or a dictionary; see the
 * README) for made-up data where the hardware is missing.
 */

#import <AppKit/AppKit.h>
#import "DockExtra.h"

@class DockExtrasController;

@protocol DockExtrasControllerDelegate
/* The shown extras changed: one was hidden or shown, came or went with
 * its hardware, or was moved. */
- (void) dockExtrasControllerDidChangeExtras: (DockExtrasController *)controller;
- (void) dockExtrasController: (DockExtrasController *)controller
	       extraNeedsDisplay: (id)extra;
- (NSRect) dockExtrasController: (DockExtrasController *)controller
	     screenFrameForExtra: (id)extra;
- (NSRect) dockExtrasController: (DockExtrasController *)controller
	      panelFrameForExtra: (id)extra
			    size: (NSSize)size;
- (CGFloat) dockExtrasControllerCellSize: (DockExtrasController *)controller;
/* An extra's "Open ... Settings" item was chosen. */
- (void) dockExtrasController: (DockExtrasController *)controller
	openApplicationAtPath: (NSString *)path;
@end

@interface DockExtrasController : NSObject <DockExtraHost>
{
  id _delegate;
  /* Every extra found, as NSMutableDictionaries: identifier, name, path,
   * position (the default) and, once loaded, instance. */
  NSMutableArray *_records;
  NSArray *_shownExtras;
  /* The Mac menu style: the extras are menu bar status items instead
   * (identifier -> NSStatusItem), DockExtrasController+MenuBar.m. */
  BOOL _inMenuBar;
  NSMutableDictionary *_statusItems;
}

+ (NSArray *) searchPaths;

- (id) initWithDelegate: (id <DockExtrasControllerDelegate>)delegate;
/* Find the bundles and load the ones that aren't hidden. */
- (void) loadExtras;
/* Release every extra (the Dock is quitting). */
- (void) unloadExtras;

/* The extras with a tile, in order: loaded, not hidden, available, and
 * none while they are in the menu bar. */
- (NSArray *) shownExtras;
/* Show the extras as status items in the menu bar (the Mac menu style)
 * or in the Dock. */
- (void) setShowsExtrasInMenuBar: (BOOL)inMenuBar;
- (BOOL) showsExtrasInMenuBar;
/* The user dragged the shown extras into this order. Hidden and
 * unavailable extras keep their places among them. */
- (void) setOrderOfShownExtras: (NSArray *)extras;

/* For the settings: every extra found, in order, as dictionaries with
 * identifier, name, hidden (NSNumber) and available (NSNumber). */
- (NSArray *) extrasDescriptions;
/* Show or hide an extra, save DockExtrasHidden, and post
 * org.nextbsd.Dock.ExtrasChanged. */
- (void) setHidden: (BOOL)hidden forExtraWithIdentifier: (NSString *)identifier;

@end

/* The extras in the menu bar, as macOS's ControlCenter shows its own:
 * each one an NSStatusItem (public NSStatusBar API only). */
@interface DockExtrasController (MenuBar)
/* Make, update and remove the status items, for these extras. */
- (void) syncStatusItemsWithExtras: (NSArray *)extras;
- (void) removeStatusItems;
/* Draw the extra's status item again. */
- (void) updateStatusItemForExtra: (id)extra;
/* Where a panel of this size goes for an extra in the menu bar: below
 * the bar, at its right end. */
- (NSRect) menuBarPanelFrameForSize: (NSSize)size;
@end
