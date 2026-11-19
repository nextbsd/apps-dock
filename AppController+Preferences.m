/*
 * Dock
 *
 * Copyright (C) 2026 Gregory Casamento <greg.casamento@gmail.com>
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

#import "AppControllerPrivate.h"

@implementation AppController (Preferences)

- (DockPlacement) savedDockPlacement
{
  return [_preferences savedDockPlacement];
}

/*
 * Workspace Preferences changed a desktop setting. For the Dock's
 * position (NBDockPosition), or the window mode (NBWindowMode), which
 * has its own, move to the new edge at once, as the Dock's own Settings
 * window does. On WindowServer the NBDockPosition notification carries
 * the effective position (the user's or the theme's); under X11 the
 * Dock follows the DockPlacement Workspace wrote beside it.
 */
- (void) desktopSettingsDidChange: (NSNotification *)notification
{
  NSDictionary *info = [notification userInfo];
  id key = [info objectForKey:@"key"];
  DockPlacement placement;

  [NSObject cancelPreviousPerformRequestsWithTarget:self
					   selector:@selector(updateDockExtrasPlace)
					     object:nil];
  [self performSelector:@selector(updateDockExtrasPlace) withObject:nil
	     afterDelay:0.0];
  if (![key isEqual:DockPositionDefaultsKey]
      && ![key isEqual:DockWindowModeDefaultsKey]
      && ![key isEqual:DockModeSettingsKey])
    {
      return;
    }
  [[NSUserDefaults standardUserDefaults] synchronize];
  if ([WSDockManager isWindowServerSession])
    {
      if (![key isEqual:DockPositionDefaultsKey]
	  || ![DockPreferences placement:&placement
			 forDockPosition:[info objectForKey:@"value"]])
	{
	  placement = [_preferences savedWindowServerDockPlacement];
	}
    }
  else
    {
      placement = [self savedDockPlacement];
    }
  if (placement == _dockPlacement)
    {
      return;
    }
  _dockPlacement = placement;
  [self applyDockPlacement];
  [_settingsController updateControls];
}

- (NSColor *) savedBackgroundColor
{
  return [_preferences savedBackgroundColor];
}

- (void) saveBackgroundColor
{
  [_preferences saveBackgroundColor:_backgroundColor];
}

- (CGFloat) savedWindowAlpha
{
  return [_preferences savedWindowAlpha];
}

- (void) saveWindowAlpha
{
  [_preferences saveWindowAlpha:_windowAlpha];
}

- (BOOL) savedShowDockBorder
{
  return [_preferences savedShowDockBorder];
}

- (void) saveShowDockBorder
{
  [_preferences saveShowDockBorder:_showDockBorder];
}

- (NSInteger) savedDockCellSizeMode
{
  return [_preferences savedDockCellSizeMode];
}

- (void) saveDockCellSizeMode
{
  [_preferences saveDockCellSizeMode:_dockCellSizeMode];
}

- (DockRunningIndicatorMode) savedRunningIndicatorMode
{
  return [_preferences savedRunningIndicatorMode];
}

- (void) saveRunningIndicatorMode
{
  [_preferences saveRunningIndicatorMode:_runningIndicatorMode];
}

- (BOOL) savedUseCellTileBackground
{
  return [_preferences savedUseCellTileBackground];
}

- (void) saveUseCellTileBackground
{
  [_preferences saveUseCellTileBackground:_useCellTileBackground];
}

- (BOOL) savedSingleClickLaunchesApplications
{
  return [_preferences savedSingleClickLaunchesApplications];
}

- (CGFloat) activeDockPad
{
  return [DockPreferences padForCellSizeMode:_dockCellSizeMode] * _dockScale;
}

- (CGFloat) activeDockGap
{
  return [DockPreferences gapForCellSizeMode:_dockCellSizeMode] * _dockScale;
}

- (CGFloat) activeDockWindowWidth
{
  return [DockPreferences windowWidthForCellSizeMode:_dockCellSizeMode] * _dockScale;
}

/* The empty gaps between the Dock's sections on WindowServer: one
 * before the running apps that aren't kept, one before the minimized
 * windows and one before the Dock extras, each only when its section
 * has something in it. */
- (NSUInteger) dockSectionGapCount
{
  NSUInteger pinned = [self pinnedApplicationCount];
  BOOL running = NO;
  BOOL windows = NO;
  NSUInteger i;

  for (i = pinned; i < [_items count]; i++)
    {
      if ([(DockItem *)[_items objectAtIndex:i] kind] == DockItemMinimizedWindow)
	windows = YES;
      else
	running = YES;
    }
  return (running ? 1 : 0) + (windows ? 1 : 0)
    + ([self dockExtraCount] > 0 || [self dockSizesToContent] ? 1 : 0);
}

/* Centred only in the Mac menu style, where the extras have gone to the
 * menu bar; in the NeXT style the Dock runs the length of its edge with
 * the extras at its end, whatever DockAlignment says. */
- (BOOL) dockSizesToContent
{
  return [WSDockManager isWindowServerSession]
    && _dockAlignment == DockAlignmentCenter
    && [self dockIsMacMenuStyle];
}

- (BOOL) dockIsMacMenuStyle
{
  return NSInterfaceStyleForKey(@"NSMenuInterfaceStyle", nil)
    == NSMacintoshInterfaceStyle;
}

/* The cells along the Dock: the top tile, every item (minimized
 * windows too), the Dock extras and the Recycler, any empty slots
 * before kept apps, and a kept apps' drop slot while the Dock makes
 * room for one. */
- (NSUInteger) dockCellCount
{
  NSUInteger count = [_items count] + [self dockExtraCount] + 2;
  NSUInteger i;

  if ([_preferences savedAllowsGaps])
    {
      for (i = 0; i < [_items count]; i++)
	{
	  DockItem *item = [_items objectAtIndex:i];

	  if ([item isPinned] && [item gapBefore])
	    count++;
	}
    }
  if ([_dockView reservesDropSlot])
    {
      count++;
    }
  return count;
}

/* How long a centred Dock is, as DockView lays it out: the padding at
 * both ends, the cells and the gaps between them, and the section gaps,
 * the one before the extras or the Recycler included. */
- (CGFloat) dockContentLength
{
  CGFloat cell = [self activeDockCellSize];
  NSUInteger count = [self dockCellCount];

  return 2.0 * [self activeDockPad] + count * cell
    + (count - 1) * [self activeDockGap]
    + [self dockSectionGapCount] * floor(cell * DockSectionGapFraction);
}

/*
 * The cell size: the chosen one, or on WindowServer, where the Dock
 * fills its screen edge, smaller when the column or row is full, so
 * that tiles shrink before anything is hidden, and back up to the
 * chosen size as tiles go away. The Dock calls this whenever its items
 * (apps, minimized windows) or extras change.
 */
- (CGFloat) activeDockCellSize
{
  CGFloat cell = [DockPreferences dockCellSize] * _dockScale;
  CGFloat gap = [self activeDockGap];
  CGFloat available;
  CGFloat cells;
  NSUInteger count;
  NSRect frame;

  if (![WSDockManager isWindowServerSession])
    {
      return cell;
    }
  /* The cells, plus the gaps between sections, which are a fraction
   * of a cell; the flexible gap can be empty. */
  count = [self dockCellCount];
  cells = count + [self dockSectionGapCount] * DockSectionGapFraction;
  /* Along the Dock's own frame: below the Mac menu bar, if any. */
  frame = [self windowServerDockFrameForEdge:
		  [DockPreferences edgeForPlacement:_dockPlacement]
				   thickness:[self activeDockWindowWidth]];
  available = ([DockPreferences placementIsHorizontal:_dockPlacement]
	       ? NSWidth(frame) : NSHeight(frame))
    - 2.0 * [self activeDockPad];
  if (cells * cell + (count - 1) * gap > available)
    {
      cell = floor((available - (count - 1) * gap) / cells);
      if (cell < 24.0)
	{
	  cell = 24.0;
	}
    }
  return cell;
}

- (void) applyDockCellSizeToView
{
  if (_dockView)
    {
      [_dockView setAllowsGaps:[_preferences savedAllowsGaps]];
      [_dockView setIconCellSize:[self activeDockCellSize]
			      gap:[self activeDockGap]
			  padding:[self activeDockPad]];
    }
}


@end
