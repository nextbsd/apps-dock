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
 * The AppController's side of WSDockManager (NextBSD's WindowServer):
 * minimized windows as Dock items with live previews, the per-app
 * window list in the Dock menu, and keeping the Dock's sections in order.
 */

#import "AppControllerPrivate.h"
#import "DockViewPrivate.h"

/* Processes that had windows at the last window list, to notice new
 * apps without waiting for the next process scan. */
static NSSet *knownWindowProcesses = nil;

/* Minimized-window tiles are drawn at twice the 64-point cell. */
#define DockMinimizedTileSize 128.0
#define DockMinimizedBadgeSize 56.0

@implementation AppController (WindowServer)

- (BOOL) usesWindowServer
{
  return [_windowManager isKindOfClass:[WSDockManager class]];
}

/*
 * The Dock's sections, top to bottom: pinned apps, running apps that
 * aren't pinned, then minimized windows. Pinned apps are kept first by
 * the code that adds items; this keeps minimized windows after every
 * app, in the order they came, whatever was added since.
 */
- (void) sortItemsIntoSections
{
  NSMutableArray *apps = [NSMutableArray array];
  NSMutableArray *windows = [NSMutableArray array];
  NSUInteger i;

  for (i = 0; i < [_items count]; i++)
    {
      DockItem *item = [_items objectAtIndex:i];

      if ([item kind] == DockItemMinimizedWindow)
	[windows addObject:item];
      else
	[apps addObject:item];
    }
  if ([windows count] == 0)
    {
      return;
    }
  [apps addObjectsFromArray:windows];
  [_items setArray:apps];
}

- (DockItem *) minimizedWindowItemForWindow: (unsigned long)window
{
  NSUInteger i;

  for (i = 0; i < [_items count]; i++)
    {
      DockItem *item = [_items objectAtIndex:i];

      if ([item kind] == DockItemMinimizedWindow && [item xWindow] == window)
	{
	  return item;
	}
    }
  return nil;
}

- (NSDictionary *) windowEntryForWindow: (unsigned long)window
{
  NSArray *windows = [_windowManager windows];
  NSUInteger i;

  for (i = 0; i < [windows count]; i++)
    {
      NSDictionary *entry = [windows objectAtIndex:i];

      if ([[entry objectForKey:WSDockWindowKey] unsignedLongValue] == window)
	{
	  return entry;
	}
    }
  return nil;
}

/* The icon of the app that owns a window: its Dock item's, or its
 * bundle's. */
- (NSImage *) applicationIconForWindow: (unsigned long)window
{
  NSNumber *pid = [[self windowEntryForWindow:window] objectForKey:WSDockProcessKey];
  DockItem *item;
  NSString *path, *bundle;

  if (pid == nil)
    {
      return nil;
    }
  item = [self applicationItemMatchingProcessIdentifier:pid];
  if ([item icon] != nil)
    {
      return [item icon];
    }
  path = [self executablePathForProcessIdentifier:pid];
  bundle = [DockItem applicationBundlePathForPath:path];
  if ([bundle length])
    {
      return [[NSWorkspace sharedWorkspace] iconForFile:bundle];
    }
  return nil;
}

/*
 * A minimized window's tile: the window's preview, scaled to fit with a
 * thin edge, and the app's icon in the bottom-right corner, as
 * WindowServer draws its own tiles. Before the first preview arrives,
 * a plain dark tile stands in for the window.
 */
- (NSImage *) minimizedWindowTileWithPreview: (NSImage *)preview
				     appIcon: (NSImage *)icon
{
  NSSize size = NSMakeSize(DockMinimizedTileSize, DockMinimizedTileSize);
  NSRect inner = NSMakeRect(3.0, 10.0, size.width - 6.0, size.height - 20.0);
  NSImage *tile = AUTORELEASE([[NSImage alloc] initWithSize:size]);
  NSRect r;

  [tile lockFocus];
  if (preview != nil && [preview size].width > 0 && [preview size].height > 0)
    {
      NSSize ps = [preview size];
      CGFloat f = MIN(NSWidth(inner) / ps.width, NSHeight(inner) / ps.height);

      r = NSMakeRect(NSMidX(inner) - ps.width * f / 2.0,
		     NSMidY(inner) - ps.height * f / 2.0,
		     ps.width * f, ps.height * f);
      [preview drawInRect:r
		 fromRect:NSZeroRect
		operation:NSCompositeSourceOver
		 fraction:1.0];
      /* A light edge sets dark windows off the Dock's dark tiles. */
      [[NSColor colorWithCalibratedWhite:1.0 alpha:0.55] set];
      NSFrameRectWithWidth(r, 1.5);
    }
  else
    {
      [[NSColor colorWithCalibratedWhite:0.19 alpha:1.0] set];
      [[NSBezierPath bezierPathWithRoundedRect:inner xRadius:8.0 yRadius:8.0] fill];
    }
  if (icon != nil)
    {
      r = NSMakeRect(size.width - DockMinimizedBadgeSize, 0.0,
		     DockMinimizedBadgeSize, DockMinimizedBadgeSize);
      [icon drawInRect:r
	      fromRect:NSZeroRect
	     operation:NSCompositeSourceOver
	      fraction:1.0];
    }
  [tile unlockFocus];
  return tile;
}

/* The screen changed size: the Dock fills its edge of the new one.
 * libs-gui moves every window for the change too (keeping its distance
 * from the top) once this notification is out, the icon, extra and
 * Recycler windows included, so place everything again after that. */
- (void) screenParametersDidChange: (NSNotification *)notification
{
  if (_window != nil)
    {
      [self applyDockPlacement];
      [NSObject cancelPreviousPerformRequestsWithTarget:self
					      selector:@selector(placeAfterScreenChange)
						object:nil];
      [self performSelector:@selector(placeAfterScreenChange)
		 withObject:nil
		 afterDelay:0.25];
    }
}

- (void) placeAfterScreenChange
{
  if (_window != nil)
    {
      [self applyDockPlacement];
      [_dockView syncIconWindows];
      [_dockView updateIconWindowPositions];
    }
}

/* ---- WSDockManagerDelegate ---- */

/* A Mac menu bar came, went or changed height: stay below it. */
- (void) wsDockManagerMenuBarDidChange: (WSDockManager *)manager
{
  if (_window != nil)
    {
      [self applyDockPlacement];
    }
}

- (void) wsDockManagerDidUpdateWindowList: (WSDockManager *)manager
{
  NSArray *minimized = [manager dockMinimizedWindows];
  NSMutableSet *windows = [NSMutableSet set];
  NSSet *processes;
  BOOL changed = NO;
  NSUInteger i;

  for (i = 0; i < [minimized count]; i++)
    {
      [windows addObject:[[minimized objectAtIndex:i] objectForKey:WSDockWindowKey]];
    }

  /* Windows restored, closed, or no longer the Dock's. */
  for (i = [_items count]; i > 0; i--)
    {
      DockItem *item = [_items objectAtIndex:i - 1];

      if ([item kind] == DockItemMinimizedWindow &&
	  ![windows containsObject:[NSNumber numberWithUnsignedLong:[item xWindow]]])
	{
	  [_items removeObjectAtIndex:i - 1];
	  changed = YES;
	}
    }

  /* New ones go after the others; titles follow the windows'. */
  for (i = 0; i < [minimized count]; i++)
    {
      NSDictionary *entry = [minimized objectAtIndex:i];
      unsigned long window = [[entry objectForKey:WSDockWindowKey] unsignedLongValue];
      NSString *title = [entry objectForKey:WSDockTitleKey];
      DockItem *item = [self minimizedWindowItemForWindow:window];

      if (item == nil)
	{
	  item = [DockItem minimizedWindowItemWithTitle:title
						 window:window
						   icon:[self minimizedWindowTileWithPreview:nil
								 appIcon:[self applicationIconForWindow:window]]];
	  [_items addObject:item];
	  [manager requestPreviewForWindow:window];
	  changed = YES;
	}
      else if ([title length] && ![[item title] isEqual:title])
	{
	  [item setTitle:title];
	}
    }

  /* An app that just put up its first window gets its Dock item now,
   * not at the next process scan. */
  processes = [NSSet setWithArray:[manager processIdentifiersWithWindows]];
  if (knownWindowProcesses != nil && ![processes isSubsetOfSet:knownWindowProcesses])
    {
      ASSIGN(knownWindowProcesses, processes);
      [self scanRunningApplications];
      changed = YES;
    }
  ASSIGN(knownWindowProcesses, processes);

  if (changed)
    {
      [self refreshDock];
    }
}

- (void) wsDockManager: (WSDockManager *)manager
      didUpdatePreview: (NSImage *)preview
	     forWindow: (unsigned long)window
{
  DockItem *item = [self minimizedWindowItemForWindow:window];

  if (item == nil)
    {
      return;
    }
  [item setIcon:[self minimizedWindowTileWithPreview:preview
					     appIcon:[self applicationIconForWindow:window]]];
  [_dockView setNeedsDisplay:YES];
}

/* ---- the window list in the Dock menu ---- */

- (NSArray *) dockView: (id)dockView windowsForItem: (DockItem *)item
{
  NSMutableArray *result = [NSMutableArray array];
  NSArray *windows;
  NSUInteger i;

  if (![self usesWindowServer] || [item kind] != DockItemApplication)
    {
      return result;
    }
  windows = [_windowManager windowsForProcessIdentifiers:
		  [self runningProcessIdentifiersForApplicationItem:item]];
  for (i = 0; i < [windows count]; i++)
    {
      NSDictionary *entry = [windows objectAtIndex:i];

      [result addObject:
		[NSDictionary dictionaryWithObjectsAndKeys:
				[entry objectForKey:WSDockWindowKey], @"window",
				[entry objectForKey:WSDockTitleKey], @"title",
				[entry objectForKey:WSDockMinimizedKey], @"minimized",
				[entry objectForKey:WSDockKeyKey], @"key",
				nil]];
    }
  return result;
}

- (void) dockView: (id)dockView activateWindow: (NSNumber *)window
	  forItem: (DockItem *)item
{
  /* WindowServer brings it forward, or asks its app to restore it. */
  [_windowManager activateWindow:[window unsignedLongValue]];
}

@end
