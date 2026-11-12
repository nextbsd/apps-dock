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

#import "DockViewPrivate.h"

@implementation DockView (Layout)

- (NSSize) cellSize
{
  return NSMakeSize(_cellSize, _cellSize);
}


/*
 * Where the tiles sit across the Dock: inset by the padding, or, in a
 * Dock that fills its screen edge, centred, so that tiles that shrank
 * to fit a full column or row stay in the middle of it.
 */
- (CGFloat) crossOffset
{
  NSRect bounds = [self bounds];
  CGFloat thickness = _horizontal ? NSHeight(bounds) : NSWidth(bounds);

  if (_fillsColumn && thickness > _cellSize)
    {
      return floor((thickness - _cellSize) / 2.0);
    }
  return _dockPad;
}


/* The Workspace tile: first along the Dock, at the top of a column or
 * the left end of a row. */
- (NSRect) topTileRect
{
  NSRect bounds = [self bounds];
  if (_horizontal)
    {
      return NSMakeRect(_dockPad,
			[self crossOffset],
			_cellSize,
			_cellSize);
    }
  else
    {
      return NSMakeRect([self crossOffset],
			NSMaxY(bounds) - _dockPad - _cellSize,
			_cellSize,
			_cellSize);
    }
}


/*
 * In a Dock that fills its screen edge the items fall into sections,
 * as on macOS: the kept apps (with the Workspace tile), the running
 * apps that aren't kept, then the minimized windows. The first item
 * after the kept apps that is a minimized window starts the last one.
 */
- (NSUInteger) firstMinimizedWindowIndex
{
  NSUInteger count = [_items count];
  NSUInteger i;

  for (i = _pinnedItemCount; i < count; i++)
    {
      if ([(DockItem *)[_items objectAtIndex:i] kind] == DockItemMinimizedWindow)
	{
	  return i;
	}
    }
  return count;
}


/* The empty space that sets a section off from the one before it. */
- (CGFloat) sectionGap
{
  return floor(_cellSize * DockSectionGapFraction);
}


/* Whether the item at index starts a section that gets a separator
 * before it: only in a Dock that fills its edge, and never for an empty
 * section (an empty one has no first item). */
- (BOOL) sectionStartsAtIndex: (NSUInteger)index
{
  NSUInteger count = [_items count];

  if (!_fillsColumn || index >= count || index < _pinnedItemCount)
    {
      return NO;
    }
  return index == _pinnedItemCount || index == [self firstMinimizedWindowIndex];
}


/* How many separators come before the item at index (or after the last
 * item, for [_items count]). */
- (NSUInteger) sectionGapsBeforeIndex: (NSUInteger)index
{
  NSUInteger count = [_items count];
  NSUInteger firstWindow;
  NSUInteger gaps = 0;

  if (!_fillsColumn || _pinnedItemCount >= count)
    {
      return 0;
    }
  firstWindow = [self firstMinimizedWindowIndex];
  if (firstWindow > _pinnedItemCount && index >= _pinnedItemCount)
    {
      gaps++;
    }
  if (firstWindow < count && index >= firstWindow)
    {
      gaps++;
    }
  return gaps;
}


- (NSPoint) cellOriginAtIndex: (NSUInteger)index
{
  NSRect topTile = [self topTileRect];
  NSUInteger slot = index;
  CGFloat sections = [self sectionGapsBeforeIndex:index] * [self sectionGap];
  if (_allowsGaps)
    for (NSUInteger i = 0; i < [_items count] && i <= index; i++)
      if ([[_items objectAtIndex:i] isPinned] && [[_items objectAtIndex:i] gapBefore]) slot++;

  if (_horizontal)
    {
      return NSMakePoint(NSMaxX(topTile) + _dockGap + sections
			 + slot * (_cellSize + _dockGap),
			 NSMinY(topTile));
    }
  else
    {
      return NSMakePoint(NSMinX(topTile),
			 NSMinY(topTile) - _dockGap - _cellSize - sections
			 - slot * (_cellSize + _dockGap));
    }
}


- (NSRect) recyclerTileRect
{
  NSPoint origin;

  /* A Dock that fills its screen edge keeps the Recycler last, across
   * the flexible gap: at the bottom of a column, the right end of a row. */
  if (_fillsColumn && _horizontal)
    {
      return NSMakeRect(NSMaxX([self bounds]) - _dockPad - _cellSize,
			[self crossOffset], _cellSize, _cellSize);
    }
  if (_fillsColumn)
    {
      return NSMakeRect([self crossOffset], NSMinY([self bounds]) + _dockPad,
			_cellSize, _cellSize);
    }
  origin = [self cellOriginAtIndex:[_items count]];
  return NSMakeRect(origin.x, origin.y, _cellSize, _cellSize);
}


/* Where the Dock extras go: after the flexible gap, one cell each, so
 * that the last one sits right before the Recycler, along the Dock
 * whichever edge it is on (only when the Dock fills its screen edge, as
 * on WindowServer). */
- (NSRect) statusAreaRect
{
  NSRect first;
  NSRect last;

  if (!_fillsColumn || ![_extras count])
    {
      return NSZeroRect;
    }
  first = [self extraCellAtIndex:0];
  last = [self extraCellAtIndex:[_extras count] - 1];
  return NSUnionRect(first, last);
}


- (NSRect) extraCellAtIndex: (NSUInteger)index
{
  NSRect recycler;
  CGFloat offset;

  if (!_fillsColumn || index >= [_extras count])
    {
      return NSZeroRect;
    }
  /* Counted back from the Recycler: the first extra is the furthest. */
  recycler = [self recyclerTileRect];
  offset = ([_extras count] - index) * (_cellSize + _dockGap);
  if (_horizontal)
    {
      return NSMakeRect(NSMinX(recycler) - offset, NSMinY(recycler),
			_cellSize, _cellSize);
    }
  return NSMakeRect(NSMinX(recycler), NSMinY(recycler) + offset,
		    _cellSize, _cellSize);
}


- (NSUInteger) extraIndexAtPoint: (NSPoint)p
{
  NSUInteger i;

  for (i = 0; i < [_extras count]; i++)
    {
      if (NSPointInRect(p, [self extraCellAtIndex:i]))
	{
	  return i;
	}
    }
  return NSNotFound;
}


- (NSUInteger) indexAtPoint: (NSPoint)p
{
  NSUInteger i;
  for (i = 0; i < [_items count]; i++)
    {
      NSRect r = NSMakeRect([self cellOriginAtIndex:i].x,
			    [self cellOriginAtIndex:i].y,
			    _cellSize, _cellSize);
      if (NSPointInRect(p, r))
	{
	  return i;
	}
    }
  return NSNotFound;
}


- (BOOL) recyclerContainsPoint: (NSPoint)p
{
  return NSPointInRect(p, [self recyclerTileRect]);
}


- (NSUInteger) insertionIndexAtPoint: (NSPoint)p
{
  NSUInteger i;

  if (![_items count])
    {
      return 0;
    }

  for (i = 0; i < [_items count]; i++)
    {
      NSPoint origin = [self cellOriginAtIndex:i];
      NSRect cell = NSMakeRect(origin.x, origin.y, _cellSize, _cellSize);

      if (_horizontal)
	{
	  if (p.x < NSMidX(cell))
	    {
	      return i;
	    }
	}
      else
	{
	  if (p.y > NSMidY(cell))
	    {
	      return i;
	    }
	}
    }

  return [_items count];
}


- (NSUInteger) pinnedInsertionIndexAtPoint: (NSPoint)p
{
  NSUInteger index = [self insertionIndexAtPoint:p];

  return MIN(index, _pinnedItemCount);
}


- (NSUInteger) reorderInsertionIndexAtPoint: (NSPoint)p
                                  fromIndex: (NSUInteger)fromIndex
{
  NSUInteger index = [self insertionIndexAtPoint:p];

  if (fromIndex < _pinnedItemCount)
    {
      return MIN(index, _pinnedItemCount);
    }

  return index;
}


- (BOOL) topIconContainsPoint: (NSPoint)p
{
  return NSPointInRect(p, [self topTileRect]);
}


- (NSInteger) hoverIndexAtPoint: (NSPoint)p
{
  NSUInteger index;

  if ([self topIconContainsPoint:p])
    {
      return DockHoverTopIcon;
    }

  if ([self recyclerContainsPoint:p])
    {
      return DockHoverRecycler;
    }

  index = [self extraIndexAtPoint:p];
  if (index != NSNotFound)
    {
      return DockHoverExtra((NSInteger)index);
    }

  index = [self indexAtPoint:p];
  return index == NSNotFound ? DockHoverNone : (NSInteger)index;
}


- (NSRect) cellRectForHoverIndex: (NSInteger)index
{
  if (index == DockHoverTopIcon)
    {
      return [self topTileRect];
    }

  if (index == DockHoverRecycler)
    {
      return [self recyclerTileRect];
    }

  if (DockHoverIsExtra(index))
    {
      return [self extraCellAtIndex:(NSUInteger)DockHoverExtraIndex(index)];
    }

  if (index >= 0 && index < (NSInteger)[_items count])
    {
      NSPoint origin = [self cellOriginAtIndex: (NSUInteger)index];
      return NSMakeRect(origin.x, origin.y, _cellSize, _cellSize);
    }

  return NSZeroRect;
}


- (NSRect) iconRectInCell: (NSRect)cell size: (CGFloat)size
{
  NSRect bounds = [self bounds];
  NSRect rect = NSMakeRect(NSMidX(cell) - size / 2.0,
			   NSMidY(cell) - size / 2.0,
			   size,
			   size);

  if (NSWidth(rect) > NSWidth(bounds))
    {
      rect.origin.x = NSMinX(bounds);
      rect.size.width = NSWidth(bounds);
    }
  else if (NSMinX(rect) < NSMinX(bounds))
    {
      rect.origin.x = NSMinX(bounds);
    }
  else if (NSMaxX(rect) > NSMaxX(bounds))
    {
      rect.origin.x = NSMaxX(bounds) - NSWidth(rect);
    }

  if (NSHeight(rect) > NSHeight(bounds))
    {
      rect.origin.y = NSMinY(bounds);
      rect.size.height = NSHeight(bounds);
    }
  else if (NSMinY(rect) < NSMinY(bounds))
    {
      rect.origin.y = NSMinY(bounds);
    }
  else if (NSMaxY(rect) > NSMaxY(bounds))
    {
      rect.origin.y = NSMaxY(bounds) - NSHeight(rect);
    }

  return rect;
}


- (CGFloat) iconSizeForItemAtIndex: (NSUInteger)index
{
  CGFloat size = 46.0 * (_cellSize / DockCell);

  if (_magnifiesHoveredIcons &&
      _hoveredItemIndex == (NSInteger)index &&
      !_draggingPaths &&
      _draggedItemIndex == NSNotFound)
    {
      size *= _hoverIconScale;
    }

  return MIN(size, _cellSize);
}


@end
