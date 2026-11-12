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

/*
 * The status area's Dock extras (DockExtra.h): their tiles sit after the
 * minimized windows. A click shows the extra's menu; a double-click opens
 * it when it can; the scroll wheel goes to it; and a drag moves it among
 * the other extras. The drag is tracked here, not with a pasteboard, so
 * an extra can't leave the status area or be dropped on the Recycler.
 */

#import "DockViewPrivate.h"
#import "DockExtra.h"

/* How far the pointer moves before a press becomes a drag. */
#define DockExtraDragThreshold 4.0

@implementation DockView (Extras)

- (void) setExtras: (NSArray *)extras
{
  NSMutableDictionary *generations = [NSMutableDictionary dictionary];
  NSUInteger i;

  [_extras setArray:extras];
  for (i = 0; i < [_extras count]; i++)
    {
      NSValue *key = [NSValue valueWithPointer:[_extras objectAtIndex:i]];
      NSNumber *generation = [_extraGenerations objectForKey:key];

      if (generation)
	{
	  [generations setObject:generation forKey:key];
	}
    }
  [_extraGenerations setDictionary:generations];
  [self hideTooltip];
  [self setNeedsDisplay:YES];
}


- (NSArray *) extras
{
  return _extras;
}


- (void) setNeedsDisplayForExtra: (id)extra
{
  NSValue *key = [NSValue valueWithPointer:extra];
  NSNumber *generation = [_extraGenerations objectForKey:key];
  NSUInteger index = [_extras indexOfObjectIdenticalTo:extra];

  if (index == NSNotFound)
    {
      return;
    }
  [_extraGenerations setObject:
		       [NSNumber numberWithUnsignedInteger:
				   [generation unsignedIntegerValue] + 1]
			forKey:key];
  [self refreshExtraWindow:extra];
  /* Its tooltip may say something new (the time, the network). */
  if (_tooltipItemIndex == DockHoverExtra((NSInteger)index))
    {
      [self syncIconWindows];
    }
}


- (NSRect) screenFrameForExtra: (id)extra
{
  NSUInteger index = [_extras indexOfObjectIdenticalTo:extra];
  NSRect cell;

  if (index == NSNotFound || ![self window])
    {
      return NSZeroRect;
    }
  cell = [self extraCellAtIndex:index];
  if (NSIsEmptyRect(cell))
    {
      return NSZeroRect;
    }
  cell.origin = [[self window] convertBaseToScreen:
				 [self convertPoint:cell.origin toView:nil]];
  return cell;
}


/* An event's location in this view, whichever window it came to (a tile
 * window, during tracking, or the Dock's own). */
- (NSPoint) dockPointForEvent: (NSEvent *)event
{
  NSPoint location = [event locationInWindow];

  if ([event window])
    {
      location = [[event window] convertBaseToScreen:location];
    }
  location = [[self window] convertScreenToBase:location];
  return [self convertPoint:location fromView:nil];
}


- (NSRect) frameForPanelOfSize: (NSSize)size besideExtra: (id)extra
{
  return [self frameForPanelOfSize:size
		  besideScreenRect:[self screenFrameForExtra:extra]];
}


/* A tile's frame on the screen (a cell of this view). */
- (NSRect) screenRectForCell: (NSRect)cell
{
  if (NSIsEmptyRect(cell) || ![self window])
    {
      return NSZeroRect;
    }
  cell.origin = [[self window] convertBaseToScreen:
				 [self convertPoint:cell.origin toView:nil]];
  return cell;
}


/* Beside the tile at `tile` (screen coordinates), toward the middle of
 * the screen, whichever edge the Dock is on, and on the screen. */
- (NSRect) frameForPanelOfSize: (NSSize)size besideScreenRect: (NSRect)tile
{
  NSScreen *screen = [[self window] screen];
  NSRect visible;
  NSRect frame = NSMakeRect(0, 0, size.width, size.height);
  CGFloat gap = 8.0;
  CGFloat dx, dy;

  if (!screen)
    {
      screen = [NSScreen mainScreen];
    }
  visible = screen ? [screen frame] : NSMakeRect(0, 0, 1024, 768);
  if (NSIsEmptyRect(tile))
    {
      frame.origin.x = NSMidX(visible) - size.width / 2.0;
      frame.origin.y = NSMidY(visible) - size.height / 2.0;
      return frame;
    }
  /* Which way is the middle of the screen from the tile? The Dock is on
   * the edge the tile is nearest. */
  dx = NSMidX(visible) - NSMidX(tile);
  dy = NSMidY(visible) - NSMidY(tile);
  if (fabs(dx) / NSWidth(visible) >= fabs(dy) / NSHeight(visible))
    {
      /* A side edge: beside the tile, centred on it. */
      frame.origin.x = dx < 0 ? NSMinX(tile) - gap - size.width
	: NSMaxX(tile) + gap;
      frame.origin.y = NSMidY(tile) - size.height / 2.0;
    }
  else
    {
      /* The top or bottom edge: below or above the tile. */
      frame.origin.x = NSMidX(tile) - size.width / 2.0;
      frame.origin.y = dy < 0 ? NSMinY(tile) - gap - size.height
	: NSMaxY(tile) + gap;
    }
  frame.origin.x = floor(MAX(NSMinX(visible),
			     MIN(frame.origin.x, NSMaxX(visible) - size.width)));
  frame.origin.y = floor(MAX(NSMinY(visible),
			     MIN(frame.origin.y, NSMaxY(visible) - size.height)));
  return frame;
}


/* Show the extra's menu beside its tile, like a panel, rather than at
 * the pointer, where it would run off the screen edge the Dock is on.
 * Click to open, click to choose: the button is usually up already. */
- (void) showMenuForExtra: (id)extra event: (NSEvent *)event
{
  NSMenu *menu = nil;

  NS_DURING
    menu = [(id <DockExtra>)extra menuForEvent:event];
  NS_HANDLER
    NSLog(@"Dock extra %@ failed to make its menu: %@", extra, localException);
  NS_ENDHANDLER
  if (!menu)
    {
      return;
    }
  [self showMenu:menu besideScreenRect:[self screenFrameForExtra:extra]
	   event:event];
}


/* What +popUpContextMenu: does, but with the menu beside the tile,
 * toward the middle of the screen, whichever edge the Dock is on:
 * GNUstep opens a context menu at the pointer. */
- (void) showMenu: (NSMenu *)menu
 besideScreenRect: (NSRect)tile
	    event: (NSEvent *)event
{
  NSMenuView *view;
  NSRect frame;

  [menu displayTransient];
  view = [menu menuRepresentation];
  frame = [self frameForPanelOfSize:[[view window] frame].size
		   besideScreenRect:tile];
  [[view window] setFrameOrigin:frame.origin];
  [view mouseDown:event];
  [menu closeTransient];
  [self forgetHover];
}


/* Move the dragged extra to the slot under the pointer; the others
 * close up around it. */
- (void) moveExtra: (id)extra toPoint: (NSPoint)point
{
  NSUInteger from = [_extras indexOfObjectIdenticalTo:extra];
  NSRect area = [self statusAreaRect];
  CGFloat step = _cellSize + _dockGap;
  NSInteger to;

  if (from == NSNotFound || NSIsEmptyRect(area))
    {
      return;
    }
  /* Along the Dock: down a column, or across a row. */
  to = (NSInteger)floor(_horizontal ? (point.x - NSMinX(area)) / step
			: (NSMaxY(area) - point.y) / step);
  to = MAX(0, MIN(to, (NSInteger)[_extras count] - 1));
  if ((NSUInteger)to == from)
    {
      return;
    }
  RETAIN(extra);
  [_extras removeObjectAtIndex:from];
  [_extras insertObject:extra atIndex:(NSUInteger)to];
  RELEASE(extra);
  [self syncIconWindows];
}


/* After a menu or panel, the pointer is elsewhere: no tooltip. */
- (void) forgetHover
{
  _hoveredItemIndex = DockHoverNone;
  [self hideTooltip];
}


- (void) mouseDownOnExtraAtIndex: (NSUInteger)index event: (NSEvent *)event
{
  id extra = [_extras objectAtIndex:index];
  NSPoint start = [self dockPointForEvent:event];
  NSUInteger mask = NSLeftMouseUpMask | NSLeftMouseDraggedMask;
  BOOL dragging = NO;
  NSEvent *next;

  [self hideTooltip];
  RETAIN(extra);
  /* A click or a drag? Watch until the button comes up. */
  for (;;)
    {
      NSPoint point;

      next = [NSApp nextEventMatchingMask:mask
				untilDate:[NSDate distantFuture]
				   inMode:NSEventTrackingRunLoopMode
				  dequeue:YES];
      if ([next type] == NSLeftMouseUp)
	{
	  break;
	}
      point = [self dockPointForEvent:next];
      if (!dragging &&
	  hypot(point.x - start.x, point.y - start.y) < DockExtraDragThreshold)
	{
	  continue;
	}
      dragging = YES;
      [self moveExtra:extra toPoint:point];
    }
  if (dragging)
    {
      if ([_delegate respondsToSelector:@selector(dockView:didReorderExtras:)])
	{
	  [_delegate dockView:self didReorderExtras:AUTORELEASE([_extras copy])];
	}
      RELEASE(extra);
      return;
    }
  /* An extra that opens on a double-click gets its menu once no second
   * click has come. */
  if ([extra respondsToSelector:@selector(dockExtraOpen:)])
    {
      next = [NSApp nextEventMatchingMask:NSLeftMouseDownMask
				untilDate:[NSDate dateWithTimeIntervalSinceNow:0.35]
				   inMode:NSEventTrackingRunLoopMode
				  dequeue:YES];
      if (next && [self extraIndexAtPoint:[self dockPointForEvent:next]]
	  == [_extras indexOfObjectIdenticalTo:extra])
	{
	  [NSApp nextEventMatchingMask:NSLeftMouseUpMask
			     untilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]
				inMode:NSEventTrackingRunLoopMode
			       dequeue:YES];
	  NS_DURING
	    [extra dockExtraOpen:self];
	  NS_HANDLER
	    NSLog(@"Dock extra %@ failed to open: %@", extra, localException);
	  NS_ENDHANDLER
	  RELEASE(extra);
	  return;
	}
      if (next)
	{
	  [NSApp postEvent:next atStart:YES];
	}
    }
  /* The button is already up, so the menu stays until the next click:
   * click to open it, click to choose. */
  [self showMenuForExtra:extra event:event];
  [self forgetHover];
  RELEASE(extra);
}


- (void) rightMouseDownOnExtraAtIndex: (NSUInteger)index event: (NSEvent *)event
{
  [self hideTooltip];
  [self showMenuForExtra:[_extras objectAtIndex:index] event:event];
}


- (void) scrollWheel: (NSEvent *)event onExtra: (id)extra
{
  if ([_extras indexOfObjectIdenticalTo:extra] != NSNotFound &&
      [extra respondsToSelector:@selector(scrollWheel:)])
    {
      [extra scrollWheel:event];
    }
}


@end
