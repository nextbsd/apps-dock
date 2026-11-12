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

@implementation AppController (Layout)

/*
 * The Dock's frame on WindowServer: the whole of one screen edge,
 * `thickness` deep.
 *
 * In the Mac menu style (NBMenuStyle macmenubar, nextbsd/libs-back#3)
 * the active app's menu bar runs along the top of the screen, and
 * WindowServer says how tall it is (-[WSDockManager menuBarHeight]). The
 * Dock stays below it: a top Dock sits directly below the bar, and a
 * left or right one starts there. The strip the Dock reports
 * (reportDockEdge) is its own thickness, which WindowServer counts from
 * the bar's bottom edge, so tiling keeps both strips free. The Dock
 * never moves to another edge on its own.
 */
- (NSRect) windowServerDockFrameForEdge: (DockEdge)edge
			      thickness: (CGFloat)thickness
{
  NSRect screen = [[NSScreen mainScreen] frame];
  CGFloat bar = 0;

  if ([_windowManager respondsToSelector:@selector(menuBarHeight)])
    {
      bar = [(WSDockManager *)_windowManager menuBarHeight];
    }
  if (bar > 0 && bar < NSHeight(screen) / 2)
    {
      screen.size.height -= bar;
    }

  switch (edge)
    {
    case DockEdgeLeft:
      return NSMakeRect(NSMinX(screen), NSMinY(screen),
			thickness, NSHeight(screen));
    case DockEdgeTop:
      return NSMakeRect(NSMinX(screen), NSMaxY(screen) - thickness,
			NSWidth(screen), thickness);
    case DockEdgeBottom:
      return NSMakeRect(NSMinX(screen), NSMinY(screen),
			NSWidth(screen), thickness);
    case DockEdgeRight:
    default:
      return NSMakeRect(NSMaxX(screen) - thickness, NSMinY(screen),
			thickness, NSHeight(screen));
    }
}

- (NSRect) dockWindowFrameForPlacement: (DockPlacement)placement
{
  NSRect screenFrame = [[NSScreen mainScreen] frame];
  NSUInteger cellCount = [_items count] + 2;
  if ([_preferences savedAllowsGaps])
    for (DockItem *item in _items)
      if ([item isPinned] && [item gapBefore]) cellCount++;

  CGFloat pad = [self activeDockPad];
  CGFloat gap = [self activeDockGap];
  CGFloat length = pad * 2.0 + cellCount * [DockPreferences dockCellSize] * _dockScale + (cellCount - 1) * gap;
  CGFloat thickness = [self activeDockWindowWidth];
  CGFloat width = [DockPreferences placementIsHorizontal:placement] ? length : thickness;
  CGFloat height = [DockPreferences placementIsHorizontal:placement] ? thickness : length;
  CGFloat x;
  CGFloat y;

  /* On WindowServer the Dock fills a whole screen edge: a column on the
   * left or right, a row along the top or bottom. */
  if ([WSDockManager isWindowServerSession])
    {
      return [self windowServerDockFrameForEdge:
		     [DockPreferences edgeForPlacement:placement]
				      thickness:thickness];
    }
  if (height > NSHeight(screenFrame))
    {
      height = NSHeight(screenFrame);
    }
  if (width > NSWidth(screenFrame))
    {
      width = NSWidth(screenFrame);
    }

  switch (placement)
    {
    case DockPlacementRightTop:
    case DockPlacementRightCenter:
      x = NSMaxX(screenFrame) - width;
      break;
    case DockPlacementTopCenter:
    case DockPlacementBottomCenter:
      x = NSMinX(screenFrame) + (NSWidth(screenFrame) - width) / 2.0;
      break;
    case DockPlacementLeftTop:
    case DockPlacementLeftCenter:
    default:
      x = NSMinX(screenFrame);
      break;
    }

  switch (placement)
    {
    case DockPlacementLeftCenter:
    case DockPlacementRightCenter:
      y = NSMinY(screenFrame) + (NSHeight(screenFrame) - height) / 2.0;
      break;
    case DockPlacementBottomCenter:
      y = NSMinY(screenFrame);
      break;
    case DockPlacementLeftTop:
    case DockPlacementRightTop:
    case DockPlacementTopCenter:
    default:
      y = NSMaxY(screenFrame) - height;
      break;
    }

  return NSMakeRect(x, y, width, height);
}

@end
