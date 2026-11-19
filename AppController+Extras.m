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
 * The AppController's side of the Dock extras: DockExtrasController
 * loads them, and the ones with a tile go into DockView's status area.
 * Only a Dock that fills its screen edge (on NextBSD's WindowServer) has
 * a status area, so extras are loaded there only. Nothing here assumes
 * which edge that is.
 */

#import "AppControllerPrivate.h"
#import "DockExtrasSettings.h"

@implementation AppController (Extras)

- (void) loadDockExtras
{
  if (_extrasController || ![_dockView fillsColumn])
    {
      return;
    }
  _extrasController = [[DockExtrasController alloc] initWithDelegate:self];
  [_extrasController loadExtras];

  /* The settings apps' "Show ... in Dock" checkboxes ask the Dock to
   * show or hide an extra (DockExtrasSettings.h). */
  [[NSDistributedNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(setExtraHiddenRequested:)
	   name:DockSetExtraHiddenNotification
	 object:nil];
}

- (void) setExtraHiddenRequested: (NSNotification *)notification
{
  NSDictionary *info = [notification userInfo];
  id identifier = [info objectForKey:@"identifier"];
  id hidden = [info objectForKey:@"hidden"];

  if (![identifier isKindOfClass:[NSString class]]
      || ![hidden respondsToSelector:@selector(boolValue)])
    {
      NSLog(@"DockWM: ignoring %@ without identifier and hidden: %@",
	    DockSetExtraHiddenNotification, info);
      return;
    }
  [self setDockExtraHidden:[hidden boolValue] forIdentifier:identifier];
}

- (NSUInteger) dockExtraCount
{
  return [[_extrasController shownExtras] count];
}

- (NSArray *) dockExtrasDescriptions
{
  return _extrasController ? [_extrasController extrasDescriptions]
    : [NSArray array];
}

- (void) setDockExtraHidden: (BOOL)hidden forIdentifier: (NSString *)identifier
{
  [_extrasController setHidden:hidden forExtraWithIdentifier:identifier];
  /* The Dock's own Settings -> Extras follows a change made elsewhere. */
  [_settingsController updateControls];
}

/* DockExtrasControllerDelegate */

- (void) dockExtrasControllerDidChangeExtras: (DockExtrasController *)controller
{
  /* The extras take cells too, so the tiles may need to shrink. */
  [self applyDockCellSizeToView];
  [_dockView setExtras:[controller shownExtras]];
}

- (void) dockExtrasController: (DockExtrasController *)controller
	       extraNeedsDisplay: (id)extra
{
  [_dockView setNeedsDisplayForExtra:extra];
}

- (NSRect) dockExtrasController: (DockExtrasController *)controller
	     screenFrameForExtra: (id)extra
{
  return [_dockView screenFrameForExtra:extra];
}

- (NSRect) dockExtrasController: (DockExtrasController *)controller
	      panelFrameForExtra: (id)extra
			    size: (NSSize)size
{
  return [_dockView frameForPanelOfSize:size besideExtra:extra];
}

- (CGFloat) dockExtrasControllerCellSize: (DockExtrasController *)controller
{
  return [_dockView cellSize].width;
}

- (void) dockExtrasController: (DockExtrasController *)controller
	openApplicationAtPath: (NSString *)path
{
  DockItem *item = [DockItem applicationItemWithPath:path];

  /* A running settings app comes forward, as from its Dock tile. */
  if ([[self runningProcessIdentifiersForApplicationItem:item] count] > 0
      && ([self reopenRunningApplicationAtPath:path]
	  || [[NSWorkspace sharedWorkspace] launchApplication:path]))
    {
      return;
    }
  [self rememberLaunchedApplicationPath:path];
  [self launchApplicationAtPath:path];
  [_windowManager drainTransientIconEvents];
}

/* DockView: the user dragged an extra to a new place. */
- (void) dockView: (id)dockView didReorderExtras: (NSArray *)extras
{
  [_extrasController setOrderOfShownExtras:extras];
}

@end
