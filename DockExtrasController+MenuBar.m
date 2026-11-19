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
 * The Dock extras in the Mac menu style (nextbsd/apps-dock#41): the
 * Dock is ControlCenter, and each extra is its own NSStatusItem at the
 * right end of the menu bar. On NextBSD's WindowServer the backend
 * makes each one a window in WindowServer's status item slots
 * (nextbsd/libs-back#41, apps-windowserver#97), which WindowServer packs
 * right to left by priority; the Dock uses only NSStatusBar and
 * NSStatusItem.
 *
 * Order: larger priorities go further right, and WindowServer's bands
 * are 0 for apps' items, 1000 for the system's and 2000 for the clock.
 * The extras are the system's: each takes 1000 plus its
 * DockExtraMenuBarPosition, so they keep their order left to right
 * whenever one comes or goes, and the clock ("clock" priority) takes
 * 2000, rightmost. The backend takes the priority through a category it
 * documents, -setStatusItemPriority:, when it has one.
 *
 * Each item's menu is filled from the extra's -menuForEvent: (nil
 * event) just before it opens, through the menu's delegate
 * (-menuNeedsUpdate:), so it is as current as the Dock's.
 */

#import "DockExtrasController.h"
#import <GNUstepBase/GNUstep.h>

/* WindowServer's status item priorities (WS_STATUS_PRIORITY_*). */
#define DockStatusPrioritySystem 1000
#define DockStatusPriorityClock 2000

/* nextbsd/libs-back's NSStatusItem priority, where the backend has it. */
@interface NSStatusItem (NextBSD)
- (void) setStatusItemPriority: (NSInteger)priority;
@end

/* DockExtrasController.m's. */
@interface DockExtrasController (Records)
- (NSMutableDictionary *) recordForExtra: (id)extra;
@end

@interface DockExtrasController (MenuBarPrivate)
- (NSInteger) statusItemPriorityForRecord: (NSDictionary *)record;
- (void) updateStatusItem: (NSStatusItem *)item forExtra: (id)extra;
@end

/* The bar's text colour, as libs-gui's menu items draw their titles,
 * or with the item highlighted (its menu open). */
static NSColor *
statusItemColor(BOOL highlighted)
{
  NSColor *color = highlighted ? [NSColor selectedMenuItemTextColor]
    : [NSColor controlTextColor];

  color = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  return color ? color : [NSColor whiteColor];
}

/* How much of the bar's height a glyph takes, as on macOS. */
static CGFloat
glyphHeight(CGFloat thickness)
{
  return MAX(10.0, floor(thickness * 0.7));
}

/*
 * An extra that draws only its tile: the tile in one colour, as a
 * glyph, once in each of colors. The plate and anything dark go, white
 * stays in the colour, and dimmed or coloured parts are fainter; the
 * glyph is cut to what's left and fills the height.
 */
static NSArray *
monochromeTileImages(id extra, CGFloat height, NSArray *colors)
{
  NSMutableArray *images = [NSMutableArray array];
  NSUInteger i;
  CGFloat side = ceil(height * 3.0);
  NSImage *tile = AUTORELEASE([[NSImage alloc]
				initWithSize:NSMakeSize(side, side)]);
  NSBitmapImageRep *source;
  NSBitmapImageRep *glyph;
  NSInteger w, h, x, y;
  NSInteger minX, minY, maxX, maxY;
  CGFloat red, green, blue, alpha;
  unsigned char *out;
  NSImage *image;
  NSSize size;
  float *mask;

  [tile setBackgroundColor:[NSColor clearColor]];
  [tile lockFocus];
  NSRectFillUsingOperation(NSMakeRect(0, 0, side, side), NSCompositeClear);
  NS_DURING
    [(id <DockExtra>)extra drawInRect:NSMakeRect(0, 0, side, side)];
  NS_HANDLER
    NSLog(@"Dock extra %@ failed to draw: %@", extra, localException);
  NS_ENDHANDLER
  [tile unlockFocus];
  source = [NSBitmapImageRep imageRepWithData:[tile TIFFRepresentation]];
  w = [source pixelsWide];
  h = [source pixelsHigh];
  if (w <= 0 || h <= 0)
    {
      return images;
    }
  mask = malloc(sizeof(float) * w * h);
  minX = w;
  minY = h;
  maxX = -1;
  maxY = -1;
  for (y = 0; y < h; y++)
    {
      NSAutoreleasePool *pool = [NSAutoreleasePool new];

      for (x = 0; x < w; x++)
	{
	  NSColor *c = [[source colorAtX:x y:y]
			 colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
	  float v = 0.0;

	  if (c)
	    {
	      v = (0.30 * [c redComponent] + 0.59 * [c greenComponent]
		   + 0.11 * [c blueComponent]) * [c alphaComponent];
	      v = (v - 0.3) / 0.6;
	      v = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
	    }
	  mask[y * w + x] = v;
	  if (v > 0.05)
	    {
	      minX = MIN(minX, x);
	      maxX = MAX(maxX, x);
	      minY = MIN(minY, y);
	      maxY = MAX(maxY, y);
	    }
	}
      [pool release];
    }
  if (maxX < minX || maxY < minY)
    {
      free(mask);
      return images;
    }
  /* As tall as a glyph, as wide as its proportions (two heights at
   * most). */
  height = glyphHeight(height);
  size = NSMakeSize(MIN(2.0 * height,
			ceil(height * (maxX - minX + 1) / (maxY - minY + 1))),
		    height);
  for (i = 0; i < [colors count]; i++)
    {
      [[colors objectAtIndex:i] getRed:&red green:&green blue:&blue alpha:&alpha];
      glyph = AUTORELEASE([[NSBitmapImageRep alloc]
			    initWithBitmapDataPlanes:NULL
					  pixelsWide:maxX - minX + 1
					  pixelsHigh:maxY - minY + 1
				       bitsPerSample:8
				     samplesPerPixel:4
					    hasAlpha:YES
					    isPlanar:NO
				      colorSpaceName:NSCalibratedRGBColorSpace
					 bytesPerRow:0
					bitsPerPixel:0]);
      out = [glyph bitmapData];
      for (y = minY; y <= maxY; y++)
	{
	  unsigned char *row = out + (y - minY) * [glyph bytesPerRow];

	  for (x = minX; x <= maxX; x++)
	    {
	      /* Premultiplied, as NSBitmapImageRep keeps it. */
	      float a = mask[y * w + x] * alpha;

	      row[(x - minX) * 4 + 0] = (unsigned char)(red * a * 255.0 + 0.5);
	      row[(x - minX) * 4 + 1] = (unsigned char)(green * a * 255.0 + 0.5);
	      row[(x - minX) * 4 + 2] = (unsigned char)(blue * a * 255.0 + 0.5);
	      row[(x - minX) * 4 + 3] = (unsigned char)(a * 255.0 + 0.5);
	    }
	}
      [glyph setSize:size];
      image = AUTORELEASE([[NSImage alloc] initWithSize:size]);
      [image addRepresentation:glyph];
      [images addObject:image];
    }
  free(mask);
  return images;
}

@implementation DockExtrasController (MenuBar)

- (void) syncStatusItemsWithExtras: (NSArray *)extras
{
  NSStatusBar *bar = [NSStatusBar systemStatusBar];
  NSMutableSet *live = [NSMutableSet set];
  NSEnumerator *e;
  NSString *identifier;
  NSUInteger i;

  if (bar == nil)
    {
      return;
    }
  for (i = 0; i < [extras count]; i++)
    {
      id extra = [extras objectAtIndex:i];
      NSDictionary *record = [self recordForExtra:extra];
      NSStatusItem *item;
      NSMenu *menu;

      identifier = [record objectForKey:@"identifier"];
      if (identifier == nil)
	{
	  continue;
	}
      [live addObject:identifier];
      item = [_statusItems objectForKey:identifier];
      if (item == nil)
	{
	  item = [bar statusItemWithLength:NSVariableStatusItemLength];
	  /* Before it has anything to show, so it shows in its place. */
	  if ([item respondsToSelector:@selector(setStatusItemPriority:)])
	    {
	      [item setStatusItemPriority:
		      [self statusItemPriorityForRecord:record]];
	    }
	  menu = AUTORELEASE([[NSMenu alloc]
			       initWithTitle:[record objectForKey:@"name"]]);
	  [menu setDelegate:(id)self];
	  [item setMenu:menu];
	  [item setHighlightMode:YES];
	  [_statusItems setObject:item forKey:identifier];
	}
      [self updateStatusItem:item forExtra:extra];
    }
  e = [[_statusItems allKeys] objectEnumerator];
  while ((identifier = [e nextObject]) != nil)
    {
      if (![live containsObject:identifier])
	{
	  [bar removeStatusItem:[_statusItems objectForKey:identifier]];
	  [_statusItems removeObjectForKey:identifier];
	}
    }
}

- (void) removeStatusItems
{
  NSStatusBar *bar = [NSStatusBar systemStatusBar];
  NSEnumerator *e = [_statusItems objectEnumerator];
  NSStatusItem *item;

  while ((item = [e nextObject]) != nil)
    {
      [bar removeStatusItem:item];
    }
  [_statusItems removeAllObjects];
}

- (void) updateStatusItemForExtra: (id)extra
{
  NSString *identifier = [[self recordForExtra:extra]
			   objectForKey:@"identifier"];
  NSStatusItem *item = identifier
    ? [_statusItems objectForKey:identifier] : nil;

  if (item)
    {
      [self updateStatusItem:item forExtra:extra];
    }
}

- (NSRect) menuBarPanelFrameForSize: (NSSize)size
{
  NSArray *screens = [NSScreen screens];
  NSRect screen = [screens count]
    ? [[screens objectAtIndex:0] frame] : NSMakeRect(0, 0, 1024, 768);
  CGFloat bar = [[NSStatusBar systemStatusBar] thickness];

  return NSMakeRect(floor(NSMaxX(screen) - size.width - 8.0),
		    floor(NSMaxY(screen) - bar - 4.0 - size.height),
		    size.width, size.height);
}

/* NSMenu delegate: an item's menu is about to show. */
- (void) menuNeedsUpdate: (NSMenu *)menu
{
  NSEnumerator *e = [_statusItems keyEnumerator];
  NSString *identifier;

  while ((identifier = [e nextObject]) != nil)
    {
      NSStatusItem *item = [_statusItems objectForKey:identifier];
      NSUInteger i;
      id extra = nil;
      NSMenu *source = nil;

      if ([item menu] != menu)
	{
	  continue;
	}
      for (i = 0; i < [_records count]; i++)
	{
	  NSDictionary *record = [_records objectAtIndex:i];

	  if ([[record objectForKey:@"identifier"] isEqual:identifier])
	    {
	      extra = [record objectForKey:@"instance"];
	    }
	}
      NS_DURING
	source = [extra menuForEvent:nil];
      NS_HANDLER
	NSLog(@"Dock extra %@ failed to make its menu: %@", identifier,
	      localException);
      NS_ENDHANDLER
      while ([menu numberOfItems])
	{
	  [menu removeItemAtIndex:0];
	}
      [menu setAutoenablesItems:source ? [source autoenablesItems] : NO];
      /* An item is in one menu at a time: they move over. */
      while ([source numberOfItems])
	{
	  NSMenuItem *menuItem = RETAIN([source itemAtIndex:0]);

	  [source removeItemAtIndex:0];
	  [menu addItem:menuItem];
	  RELEASE(menuItem);
	}
      return;
    }
}

@end

@implementation DockExtrasController (MenuBarPrivate)

- (NSInteger) statusItemPriorityForRecord: (NSDictionary *)record
{
  NSBundle *bundle = [NSBundle bundleWithPath:[record objectForKey:@"path"]];
  NSDictionary *info = [bundle infoDictionary];
  id position = [info objectForKey:@"DockExtraMenuBarPosition"];
  NSInteger p;

  if ([[info objectForKey:@"DockExtraMenuBarPriority"] isEqual:@"clock"])
    {
      return DockStatusPriorityClock;
    }
  p = [position respondsToSelector:@selector(integerValue)]
    ? [position integerValue]
    : [[record objectForKey:@"position"] integerValue];
  return DockStatusPrioritySystem + MAX(0, MIN(p, 999));
}

/* A glyph comes in the bar's text colour, and in its highlighted text
 * colour as the alternate image, for while the item's menu is open. */
- (void) updateStatusItem: (NSStatusItem *)item forExtra: (id)extra
{
  CGFloat thickness = [[item statusBar] thickness];
  NSArray *colors = [NSArray arrayWithObjects:statusItemColor(NO),
			     statusItemColor(YES), nil];
  NSMutableArray *images = [NSMutableArray array];
  NSString *title = nil;
  NSUInteger i;

  NS_DURING
    {
      [item setToolTip:[extra toolTip]];
      if ([extra respondsToSelector:@selector(statusItemTitle)])
	{
	  title = [extra statusItemTitle];
	}
      if ([title length] == 0
	  && [extra respondsToSelector:
		      @selector(drawStatusItemInRect:color:)])
	{
	  CGFloat height = glyphHeight(thickness);
	  CGFloat width = [extra respondsToSelector:
				   @selector(statusItemWidthForHeight:)]
	    ? ceil([extra statusItemWidthForHeight:height]) : height;

	  for (i = 0; i < [colors count]; i++)
	    {
	      NSImage *image = AUTORELEASE([[NSImage alloc]
					     initWithSize:NSMakeSize(width,
								     height)]);

	      [image setBackgroundColor:[NSColor clearColor]];
	      [image lockFocus];
	      NSRectFillUsingOperation(NSMakeRect(0, 0, width, height),
				       NSCompositeClear);
	      [extra drawStatusItemInRect:NSMakeRect(0, 0, width, height)
				    color:[colors objectAtIndex:i]];
	      [image unlockFocus];
	      [images addObject:image];
	    }
	}
      else if ([title length] == 0)
	{
	  [images setArray:monochromeTileImages(extra, thickness, colors)];
	}
    }
  NS_HANDLER
    NSLog(@"Dock extra %@ failed to draw its status item: %@", extra,
	  localException);
  NS_ENDHANDLER
  if ([title length])
    {
      [item setImage:nil];
      [item setAlternateImage:nil];
      [item setTitle:title];
    }
  else
    {
      [item setTitle:@""];
      [item setImage:[images count] ? [images objectAtIndex:0] : nil];
      [item setAlternateImage:[images count] > 1
			     ? [images objectAtIndex:1] : nil];
    }
}

@end
