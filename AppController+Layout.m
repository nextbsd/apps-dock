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

@implementation AppController (Layout)

/*
 * The Dock's screen, as macOS places it with several displays: on the
 * left or right edge, the display furthest that way (the desktop's
 * outer edge, not one between two displays); on the bottom or top, the
 * main display, the first of +[NSScreen screens] (nextbsd/libs-back#38).
 * Ties go to the earlier screen, the main one first, as WindowServer
 * picks the display whose usable area loses the Dock's strip.
 * +mainScreen is the key window's, which can be another display while
 * the Dock's settings panel is open there.
 */
- (NSScreen *) dockScreenForEdge: (DockEdge)edge
{
  NSArray *screens = [NSScreen screens];
  NSScreen *best = nil;

  if ([screens count] == 0)
    return [NSScreen mainScreen];
  best = [screens objectAtIndex:0];
  if (edge != DockEdgeLeft && edge != DockEdgeRight)
    return best;
  for (NSScreen *s in screens)
    {
      if (edge == DockEdgeLeft
	  ? NSMinX([s frame]) < NSMinX([best frame])
	  : NSMaxX([s frame]) > NSMaxX([best frame]))
	best = s;
    }
  return best;
}

- (NSScreen *) dockScreen
{
  return [self dockScreenForEdge:
		 [DockPreferences edgeForPlacement:_dockPlacement]];
}

/*
 * The Dock's frame on WindowServer: the whole of one edge of the Dock's
 * screen (-dockScreenForEdge:), `thickness` deep.
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
  NSScreen *dockScreen = [self dockScreenForEdge:edge];
  NSRect screen = [dockScreen frame];
  NSArray *screens = [NSScreen screens];
  CGFloat bar = 0;

  /* the menu bar is only on the main display */
  if (([screens count] == 0 || dockScreen == [screens objectAtIndex:0])
      && [_windowManager respondsToSelector:@selector(menuBarHeight)])
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
  NSRect screenFrame = [[self dockScreenForEdge:
				[DockPreferences edgeForPlacement:placement]]
			 frame];
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

  /* On WindowServer the Dock is a column on the left or right edge of
   * the screen, or a row along the top or bottom: in the middle of the
   * edge and as long as what's in it (DockAlignmentCenter, as on
   * macOS), so that it grows and shrinks as apps come and go, or
   * filling the whole edge. The strip it reports (reportDockEdge) is
   * its thickness either way. */
  if ([WSDockManager isWindowServerSession])
    {
      NSRect edge = [self windowServerDockFrameForEdge:
			    [DockPreferences edgeForPlacement:placement]
					     thickness:thickness];

      if (![self dockSizesToContent])
	{
	  return edge;
	}
      length = ceil([self dockContentLength]);
      if ([DockPreferences placementIsHorizontal:placement]
	  && length < NSWidth(edge))
	{
	  edge.origin.x += floor((NSWidth(edge) - length) / 2.0);
	  edge.size.width = length;
	}
      else if (![DockPreferences placementIsHorizontal:placement]
	       && length < NSHeight(edge))
	{
	  edge.origin.y += floor((NSHeight(edge) - length) / 2.0);
	  edge.size.height = length;
	}
      return edge;
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
