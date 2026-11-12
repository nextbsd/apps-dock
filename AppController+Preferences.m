/*
 * DockWM
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

/*
 * The cell size: the chosen one, or in the NextBSD column, smaller when
 * the column is full, so that tiles shrink before anything is hidden.
 */
- (CGFloat) activeDockCellSize
{
  CGFloat cell = [DockPreferences dockCellSize] * _dockScale;
  CGFloat gap = [self activeDockGap];
  CGFloat available;
  NSUInteger count;

  if (![WSDockManager isWindowServerSession])
    {
      return cell;
    }
  /* The top tile, every item and the Recycler; the status area and the
   * flexible gap can be empty. */
  count = [_items count] + 2;
  available = NSHeight([[NSScreen mainScreen] frame]) - 2.0 * [self activeDockPad];
  if (count * cell + (count - 1) * gap > available)
    {
      cell = floor((available - (count - 1) * gap) / count);
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
