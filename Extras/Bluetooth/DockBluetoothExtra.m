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
 * The Bluetooth Dock extra, like macOS's Bluetooth menu extra: the
 * Bluetooth rune, dimmed while Bluetooth is off, with a dot when a
 * device is connected. A click shows a menu to turn Bluetooth on or off,
 * the paired devices (choose one to connect or disconnect it) and
 * "Open Bluetooth Settings...", which opens Bluetooth.app for the rest:
 * pairing, nearby devices, headset audio. A connected device that
 * reports its battery (a headset over hands-free, an LE mouse or
 * keyboard) shows it after its name with a small gauge, red at 20% or
 * less (BTBatteryLow).
 *
 * It talks to bluetoothd as Bluetooth.app does (BTClient.c, its MIG
 * interface org.nextbsd.bluetooth). Changes come as bluetoothd's
 * org.nextbsd.bluetooth.* notify(3) keys and State:/Bluetooth in the
 * dynamic store, which BTClient turns into a byte on a pipe the extra
 * watches on the Dock's run loop. Without a Bluetooth controller (or
 * without bluetoothd) there is no tile; the extra then looks again
 * every 10 seconds, in case bluetoothd comes back without a word.
 */

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "DockExtra.h"
#import "BTClient.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#define DockBluetoothSearchInterval 10.0

@interface DockBluetoothExtra : NSObject <DockExtra>
{
  id <DockExtraHost> _host;
  BTClient *_client;
  int _pipe[2];
  NSFileHandle *_handle;
  NSTimer *_searchTimer;
  BOOL _available;
  BOOL _powered;
  NSString *_adapterName;
  /* Paired devices: dictionaries of address, name, state and battery
   * (NSNumber; percent, -1 unknown). */
  NSArray *_devices;
}
- (void) reload;
@end

static NSArray *
DockBluetoothRunLoopModes(void)
{
  return [NSArray arrayWithObjects:NSDefaultRunLoopMode,
		  NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil];
}

static NSString *
DockBluetoothStatusText(int status)
{
  switch (status)
    {
    case BTStatusRPCFailed:
      return @"bluetoothd isn't answering.";
    case BTStatusPoweredOff:
      return @"Bluetooth is off.";
    case BTStatusNotConnected:
      return @"The device isn't connected.";
    default:
      return [NSString stringWithFormat:@"bluetoothd said %d.", status];
    }
}

@implementation DockBluetoothExtra

- (id) initWithDockHost: (id <DockExtraHost>)host
{
  self = [super init];
  if (self)
    {
      NSUInteger i;

      _host = host;
      _devices = [NSArray new];
      _pipe[0] = _pipe[1] = -1;
      if (pipe(_pipe) == 0)
	{
	  for (i = 0; i < 2; i++)
	    {
	      (void)fcntl(_pipe[i], F_SETFL,
			  fcntl(_pipe[i], F_GETFL) | O_NONBLOCK);
	      (void)fcntl(_pipe[i], F_SETFD, FD_CLOEXEC);
	    }
	  _handle = [[NSFileHandle alloc] initWithFileDescriptor:_pipe[0]
						  closeOnDealloc:NO];
	  [[NSNotificationCenter defaultCenter]
	    addObserver:self
	       selector:@selector(bluetoothChanged:)
		   name:NSFileHandleDataAvailableNotification
		 object:_handle];
	  [_handle waitForDataInBackgroundAndNotifyForModes:
		     DockBluetoothRunLoopModes()];
	}
      else
	{
	  NSLog(@"Bluetooth extra: no pipe for notifications: %s",
		strerror(errno));
	}
      /* BTClient writes a byte per change; with no pipe it writes to
       * -1, which fails harmlessly, and the 10-second look still runs. */
      _client = BTClientOpen(_pipe[1]);
      [self reload];
    }
  return self;
}

- (void) dockExtraWillUnload
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_searchTimer invalidate];
  DESTROY(_searchTimer);
  if (_client)
    {
      /* Waits out a notification being handled, so the pipe can go. */
      BTClientClose(_client);
      _client = NULL;
    }
  [_handle closeFile];
  DESTROY(_handle);
  if (_pipe[1] >= 0)
    {
      close(_pipe[1]);
    }
  _pipe[0] = _pipe[1] = -1;
  _host = nil;
}

- (void) dealloc
{
  [self dockExtraWillUnload];
  DESTROY(_devices);
  DESTROY(_adapterName);
  DEALLOC;
}

/* ---- bluetoothd ---- */

- (void) bluetoothChanged: (NSNotification *)notification
{
  char buffer[256];

  while (_pipe[0] >= 0 && read(_pipe[0], buffer, sizeof(buffer)) > 0)
    {
    }
  [self reload];
  [_handle waitForDataInBackgroundAndNotifyForModes:
	     DockBluetoothRunLoopModes()];
}

- (void) searchTimerFired: (NSTimer *)timer
{
  [self reload];
}

/* Read the controller and the paired devices again. */
- (void) reload
{
  BOOL wasAvailable = _available;
  BTClientStatus status;
  BTClientAdapter adapter;
  NSMutableArray *devices = [NSMutableArray array];
  int count = 0, i;

  if (!_client)
    {
      return;
    }
  _available = BTClientGetStatus(_client, &status) == BTStatusSuccess
    && status.adapters > 0
    && BTClientGetAdapter(_client, &adapter) == BTStatusSuccess;
  _powered = _available && adapter.powered;
  ASSIGN(_adapterName, _available && adapter.name[0]
	 ? [NSString stringWithUTF8String:adapter.name] : nil);

  if (_available && BTClientPairedCount(_client, &count) == BTStatusSuccess)
    {
      for (i = 0; i < count; i++)
	{
	  BTClientDevice info;
	  NSString *name;

	  if (BTClientPairedEntry(_client, i, &info) != BTStatusSuccess)
	    {
	      continue;
	    }
	  name = info.name[0] ? [NSString stringWithUTF8String:info.name] : nil;
	  [devices addObject:
		     [NSDictionary dictionaryWithObjectsAndKeys:
				     [NSString stringWithUTF8String:info.address],
				   @"address",
				   [name length] ? name
				   : [NSString stringWithUTF8String:info.address],
				   @"name",
				   [NSNumber numberWithInt:info.state], @"state",
				   [NSNumber numberWithInt:info.battery],
				   @"battery",
				   nil]];
	}
    }
  ASSIGNCOPY(_devices, devices);

  /* No controller: look again now and then. */
  if (!_available && !_searchTimer)
    {
      _searchTimer = RETAIN([NSTimer
			      scheduledTimerWithTimeInterval:
				DockBluetoothSearchInterval
						      target:self
						    selector:@selector(searchTimerFired:)
						    userInfo:nil
						     repeats:YES]);
    }
  else if (_available && _searchTimer)
    {
      [_searchTimer invalidate];
      DESTROY(_searchTimer);
    }

  if (_available != wasAvailable)
    {
      [_host dockExtraAvailabilityDidChange:self];
    }
  [_host dockExtraNeedsDisplay:self];
}

/* A connected device's battery, -1 unknown. */
static int
DockBluetoothBattery(NSDictionary *device)
{
  if ([[device objectForKey:@"state"] intValue] != BTDeviceConnected)
    {
      return -1;
    }
  return [[device objectForKey:@"battery"] intValue];
}

static BOOL
DockBluetoothBatteryLow(NSDictionary *device)
{
  int battery = DockBluetoothBattery(device);

  return battery >= 0 && battery <= BTBatteryLow;
}

/* A device's name for its menu item, before what follows it (its
 * battery or state). The menu grows to fit its widest item (libs-gui
 * sizes it), so a long name shows in full, up to a third of the main
 * screen; past that the name gives way in the middle, so the battery
 * after it always shows. */
static NSString *
DockBluetoothMenuName(NSString *name, NSString *suffix)
{
  NSDictionary *attributes =
    [NSDictionary dictionaryWithObject:[NSFont menuFontOfSize:0]
				forKey:NSFontAttributeName];
  CGFloat limit = floor(NSWidth([[NSScreen mainScreen] frame]) / 3.0)
    - [suffix sizeWithAttributes:attributes].width;
  NSUInteger keep = [name length];
  NSString *shown = name;

  while (keep > 2 && [shown sizeWithAttributes:attributes].width > limit)
    {
      keep--;
      shown = [NSString stringWithFormat:@"%@…%@",
			[name substringToIndex:(keep + 1) / 2],
			[name substringFromIndex:[name length] - keep / 2]];
    }
  return shown;
}

/* A small battery for a menu item: an outline in the menu's text color,
 * filled to the level, red when low. */
static NSImage *
DockBluetoothGauge(int percent)
{
  NSSize size = NSMakeSize(22, 11);
  NSImage *image = AUTORELEASE([[NSImage alloc] initWithSize:size]);
  NSRect body = NSMakeRect(0.5, 1.5, 18, 8);
  NSRect level = NSInsetRect(body, 2, 2);
  NSColor *color = [NSColor controlTextColor];
  NSBezierPath *outline;

  [image lockFocus];
  outline = [NSBezierPath bezierPathWithRoundedRect:body xRadius:2 yRadius:2];
  [outline setLineWidth:1.0];
  [color set];
  [outline stroke];
  NSRectFill(NSMakeRect(NSMaxX(body) + 1, NSMidY(body) - 2, 1.5, 4));
  level.size.width = MAX(1.0, floor(NSWidth(level) * MIN(percent, 100)
				    / 100.0));
  if (percent <= BTBatteryLow)
    {
      [[NSColor colorWithCalibratedRed:1.0 green:0.23 blue:0.19 alpha:1.0]
	set];
    }
  NSRectFill(level);
  [image unlockFocus];
  return image;
}

- (NSArray *) connectedDevices
{
  NSMutableArray *connected = [NSMutableArray array];
  NSUInteger i;

  for (i = 0; i < [_devices count]; i++)
    {
      NSDictionary *device = [_devices objectAtIndex:i];

      if ([[device objectForKey:@"state"] intValue] == BTDeviceConnected)
	{
	  [connected addObject:device];
	}
    }
  return connected;
}

/* ---- DockExtra ---- */

- (BOOL) isAvailable
{
  return _available;
}

/* The Bluetooth rune: a vertical stroke with two arrowheads to its
 * right, crossing back over it, in a unit square scaled to r. */
- (void) drawRuneInRect: (NSRect)r color: (NSColor *)color
{
  NSBezierPath *path = [NSBezierPath bezierPath];
  CGFloat w = NSWidth(r), h = NSHeight(r);
  CGFloat x = NSMinX(r), y = NSMinY(r);
#define P(px, py) NSMakePoint(x + (px) * w, y + (py) * h)

  [path moveToPoint:P(0.22, 0.30)];
  [path lineToPoint:P(0.72, 0.72)];
  [path lineToPoint:P(0.48, 0.94)];
  [path lineToPoint:P(0.48, 0.06)];
  [path lineToPoint:P(0.72, 0.28)];
  [path lineToPoint:P(0.22, 0.70)];
#undef P
  [path setLineWidth:MAX(1.5, floor(w * 0.11))];
  [path setLineJoinStyle:NSRoundLineJoinStyle];
  [path setLineCapStyle:NSRoundLineCapStyle];
  [color set];
  [path stroke];
}

- (void) drawInRect: (NSRect)rect
{
  NSRect plate = DockExtraPlateRect(rect);
  CGFloat side = floor(NSHeight(plate) * 0.56);
  NSRect rune = NSMakeRect(floor(NSMidX(plate) - side / 2),
			   floor(NSMidY(plate) - side / 2), side, side);
  NSColor *color = DockExtraForegroundColor(!_powered);

  DockExtraDrawPlate(rect);
  [self drawRuneInRect:rune color:color];
  /* A device is connected: a dot in the corner, as on a status light. */
  if (_powered && [[self connectedDevices] count])
    {
      CGFloat d = MAX(3.0, floor(NSWidth(plate) * 0.13));
      NSRect dot = NSMakeRect(NSMaxX(plate) - d * 1.9, NSMinY(plate) + d * 0.9,
			      d, d);

      [color set];
      [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }
}

- (NSString *) toolTip
{
  NSArray *connected = [self connectedDevices];

  if (!_powered)
    {
      return @"Bluetooth: Off";
    }
  if ([connected count] == 1)
    {
      NSDictionary *device = [connected objectAtIndex:0];

      return [NSString stringWithFormat:@"Bluetooth: connected to %@%@",
		       [device objectForKey:@"name"],
		       DockBluetoothBatteryLow(device)
		       ? @" (battery low)" : @""];
    }
  if ([connected count] > 1)
    {
      return [NSString stringWithFormat:@"Bluetooth: %lu devices connected",
		       (unsigned long)[connected count]];
    }
  return @"Bluetooth: On";
}

- (void) addInfo: (NSString *)title toMenu: (NSMenu *)menu
{
  [(NSMenuItem *)[menu addItemWithTitle:title action:NULL keyEquivalent:@""]
		 setEnabled:NO];
}

- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSMenu *menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Bluetooth"]);
  NSMenuItem *item;
  NSUInteger i;

  [self reload];
  [menu setAutoenablesItems:NO];
  [self addInfo:_powered ? @"Bluetooth: On" : @"Bluetooth: Off" toMenu:menu];
  item = (NSMenuItem *)[menu addItemWithTitle:_powered
			      ? @"Turn Bluetooth Off" : @"Turn Bluetooth On"
				       action:@selector(togglePower:)
				keyEquivalent:@""];
  [item setTarget:self];

  if (_powered)
    {
      [menu addItem:[NSMenuItem separatorItem]];
      [self addInfo:[_devices count] ? @"Devices" : @"No paired devices"
	     toMenu:menu];
      for (i = 0; i < [_devices count]; i++)
	{
	  NSDictionary *device = [_devices objectAtIndex:i];
	  int state = [[device objectForKey:@"state"] intValue];
	  int battery = DockBluetoothBattery(device);
	  NSString *suffix = @"";
	  NSString *title;

	  if (state == BTDeviceConnecting)
	    {
	      suffix = @"  (connecting…)";
	    }
	  else if (state == BTDevicePairing)
	    {
	      suffix = @"  (pairing…)";
	    }
	  else if (battery >= 0)
	    {
	      suffix = [NSString stringWithFormat:
				   DockBluetoothBatteryLow(device)
				 ? @" — %d%%, battery low" : @" — %d%%",
				 battery];
	    }
	  title = [DockBluetoothMenuName([device objectForKey:@"name"], suffix)
		    stringByAppendingString:suffix];
	  item = (NSMenuItem *)[menu addItemWithTitle:title
					       action:@selector(toggleDevice:)
					keyEquivalent:@""];
	  [item setTarget:self];
	  [item setRepresentedObject:device];
	  [item setState:state == BTDeviceConnected ? NSOnState : NSOffState];
	  if (battery >= 0)
	    {
	      [item setImage:DockBluetoothGauge(battery)];
	    }
	  [item setToolTip:state == BTDeviceConnected
		? @"Choose to disconnect" : @"Choose to connect"];
	  [item setEnabled:state == BTDeviceConnected
		|| state == BTDeviceDisconnected];
	}
    }
  DockExtraAddSettingsItem(menu, _host, @"Open Bluetooth Settings…",
			   [NSArray arrayWithObject:@"Bluetooth"]);
  return menu;
}

/* ---- actions ---- */

- (void) report: (int)status what: (NSString *)what
{
  if (status != BTStatusSuccess)
    {
      NSRunAlertPanel(@"Bluetooth",
		      [NSString stringWithFormat:@"Couldn't %@. %@", what,
				DockBluetoothStatusText(status)],
		      @"OK", nil, nil);
    }
}

- (void) togglePower: (id)sender
{
  [self report:BTClientSetPower(_client, _powered ? 0 : 1)
	  what:_powered ? @"turn Bluetooth off" : @"turn Bluetooth on"];
  [self reload];
}

- (void) toggleDevice: (id)sender
{
  NSDictionary *device = [sender representedObject];
  const char *address = [[device objectForKey:@"address"] UTF8String];

  if ([[device objectForKey:@"state"] intValue] == BTDeviceConnected)
    {
      [self report:BTClientDisconnect(_client, address)
	      what:[NSString stringWithFormat:@"disconnect “%@”",
			     [device objectForKey:@"name"]]];
    }
  else
    {
      [self report:BTClientConnect(_client, address)
	      what:[NSString stringWithFormat:@"connect to “%@”",
			     [device objectForKey:@"name"]]];
    }
  [self reload];
}

@end
