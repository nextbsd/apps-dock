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
 * The Input Dock extra, like macOS's Input menu: the keyboard layout in
 * use by its short name (EN, ΕΛ) on the Dock extras' plate. A click lists
 * the layouts, the one in use checked, and switches to the one chosen
 * (WS_MSG_SET_KEYBOARD_LAYOUT); "Open Keyboard Settings..." opens
 * Keyboard.app, where the layouts are set. It follows
 * WS_EVENT_KEYBOARD_LAYOUT, so a switch made with the shortcut shows at
 * once.
 *
 * As on macOS, it shows only when there is something to switch: two
 * layouts or more (and WindowServer to ask). Hiding it is the Dock's
 * business, like every extra's (DockExtrasSettings.h): Keyboard.app's
 * "Show Input menu in Dock" asks the Dock.
 *
 * It lived in apps-settings (Keyboard/InputMenu) as KBInputMenuExtra.
 */

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "DockExtra.h"
#import "DockInputConnection.h"

#include <math.h>
#include <string.h>

@interface DockInputExtra : NSObject <DockExtra, DockInputConnectionDelegate>
{
  id <DockExtraHost> _host;	/* not retained */
  DockInputConnection *_connection;
  NSArray *_layouts;		/* {Layout, Variant, Name} */
  int _active;
}
- (void) reload;
- (NSDictionary *) activeSource;
@end

/* What the tile shows for a layout: EN, ΕΛ, РУ, DE... (Keyboard.app's
 * KBShortName; keep the two in step.) */
static NSString *
DockInputShortName(NSString *layout, NSString *variant)
{
  /* UTF-8, so the table doesn't lean on non-ASCII string constants. */
  static const struct { const char *layout, *name; } names[] = {
    { "us", "EN" }, { "gb", "EN" }, { "au", "EN" }, { "ie", "EN" },
    { "nz", "EN" }, { "za", "EN" },
    { "gr", "\xCE\x95\xCE\x9B" },		/* ΕΛ */
    { "ru", "\xD0\xA0\xD0\xA3" },		/* РУ */
    { "ua", "\xD0\xA3\xD0\x9A" },		/* УК */
    { "bg", "\xD0\x91\xD0\x93" },		/* БГ */
    { "by", "\xD0\x91\xD0\x95" },		/* БЕ */
    { "mk", "\xD0\x9C\xD0\x9A" },		/* МК */
    { "rs", "\xD0\xA1\xD0\xA0" },		/* СР */
    { "il", "HE" }, { "ara", "AR" }, { "ir", "FA" }, { "jp", "JA" },
    { "kr", "KO" }, { "cn", "ZH" }, { "tw", "ZH" }, { "se", "SV" },
    { "dk", "DA" }, { "cz", "CS" }, { "ee", "ET" }, { "in", "HI" },
  };
  size_t i;

  if ([variant isEqual:@"dvorak"])
    {
      return @"DV";
    }
  if ([variant isEqual:@"colemak"])
    {
      return @"CO";
    }
  if ([layout isEqual:@"rs"] && [variant hasPrefix:@"latin"])
    {
      return @"SR";
    }
  for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
    {
      if (strcmp([layout UTF8String], names[i].layout) == 0)
	{
	  return [NSString stringWithUTF8String:names[i].name];
	}
    }
  if ([layout length] > 3)
    {
      layout = [layout substringToIndex:3];
    }
  return [layout uppercaseString];
}

@implementation DockInputExtra

- (id) initWithDockHost: (id <DockExtraHost>)host
{
  if ((self = [super init]) == nil)
    {
      return nil;
    }
  _host = host;
  _active = -1;
  _layouts = [NSArray new];
  _connection = [[DockInputConnection alloc] initWithName:@"Dock Input menu"
						 delegate:self];
  [self reload];
  return self;
}

- (void) dealloc
{
  [self dockExtraWillUnload];
  RELEASE(_layouts);
  [super dealloc];
}

- (void) dockExtraWillUnload
{
  [_connection invalidate];
  DESTROY(_connection);
  _host = nil;
}

/* Something to switch between: two layouts or more. */
- (BOOL) isAvailable
{
  return [_connection isConnected] && [_layouts count] >= 2;
}

- (void) drawInRect: (NSRect)rect
{
  NSDictionary *source = [self activeSource];
  NSString *text = source != nil
    ? DockInputShortName([source objectForKey:@"Layout"],
			 [source objectForKey:@"Variant"])
    : @"?";
  NSRect plate = DockExtraPlateRect(rect);
  CGFloat size = floor(NSHeight(plate) * 0.42);
  NSDictionary *attributes;
  NSSize textSize;

  DockExtraDrawPlate(rect);
  /* As large as fits, three letters at most. */
  for (;;)
    {
      attributes = [NSDictionary dictionaryWithObjectsAndKeys:
				   [NSFont boldSystemFontOfSize:size],
				 NSFontAttributeName,
				 DockExtraForegroundColor(NO),
				 NSForegroundColorAttributeName, nil];
      textSize = [text sizeWithAttributes:attributes];
      if (textSize.width <= NSWidth(plate) * 0.8 || size <= 7)
	{
	  break;
	}
      size -= 1;
    }
  [text drawAtPoint:NSMakePoint(floor(NSMidX(plate) - textSize.width / 2),
				floor(NSMidY(plate) - textSize.height / 2))
     withAttributes:attributes];
}

- (NSString *) toolTip
{
  NSDictionary *source = [self activeSource];

  if (source == nil)
    {
      return @"Input";
    }
  return [NSString stringWithFormat:@"Input: %@",
		   [source objectForKey:@"Name"]];
}

- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSMenu *menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Input"]);
  NSUInteger i;

  [self reload];
  [menu setAutoenablesItems:NO];
  for (i = 0; i < [_layouts count]; i++)
    {
      NSDictionary *source = [_layouts objectAtIndex:i];
      NSString *name = [source objectForKey:@"Name"];
      NSMenuItem *item;

      if ([name length] == 0)
	{
	  name = [source objectForKey:@"Layout"];
	}
      item = (NSMenuItem *)[menu addItemWithTitle:
			      [NSString stringWithFormat:@"%@  (%@)", name,
					DockInputShortName(
					  [source objectForKey:@"Layout"],
					  [source objectForKey:@"Variant"])]
					   action:@selector(chooseLayout:)
				    keyEquivalent:@""];
      [item setTarget:self];
      [item setTag:(NSInteger)i];
      [item setState:((int)i == _active ? NSOnState : NSOffState)];
    }
  DockExtraAddSettingsItem(menu, _host, @"Open Keyboard Settings…",
			   [NSArray arrayWithObject:@"Keyboard"]);
  return menu;
}

/* ---- WindowServer ---- */

- (void) connectionDidChange: (DockInputConnection *)c
{
  [self reload];
}

- (void) connectionLayoutDidChange: (DockInputConnection *)c
{
  [self reload];
}

- (void) reload
{
  BOOL wasAvailable = [self isAvailable];
  int index = -1;

  ASSIGN(_layouts, [_connection layoutsWithActiveIndex:&index]);
  _active = index;
  if ([self isAvailable] != wasAvailable)
    {
      [_host dockExtraAvailabilityDidChange:self];
    }
  [_host dockExtraNeedsDisplay:self];
}

- (void) chooseLayout: (id)sender
{
  NSInteger index = [sender tag];

  if (index < 0 || (NSUInteger)index >= [_layouts count])
    {
      return;
    }
  if ([_connection setActiveLayout:(unsigned)index] != 0)
    {
      NSBeep();
    }
  [self reload];
}

- (NSDictionary *) activeSource
{
  if (_active < 0 || (NSUInteger)_active >= [_layouts count])
    {
      return nil;
    }
  return [_layouts objectAtIndex:_active];
}

@end
