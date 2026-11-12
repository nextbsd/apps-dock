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
 * The battery Dock extra: the charge as a battery glyph, a bolt while on
 * the power adapter, and the percentage; the time remaining (or to full)
 * in the tooltip.
 *
 * The data is IOPowerSources (IOPSCopyPowerSourcesInfo), from NextBSD's
 * powerd. Changes come as the notify(3) keys powerd posts, the ones
 * IOPSNotificationCreateRunLoopSource listens to (see DockBatterySource),
 * so nothing is polled. Desktops and VMs without a battery get no tile;
 * one that appears later (kIOPSNotifyAttach) gets one.
 *
 * Defaults: DockExtraBatteryShowsPercentage. For testing, the Dock's
 * DockExtrasTestData shows a made-up battery where there is none:
 * BatteryPercent (72), BatteryCharging (YES) and BatteryOnAC (YES) in the
 * dictionary set it.
 */

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "DockExtra.h"
#import "DockExtraNotify.h"
#import "DockBatterySource.h"

#define ShowsPercentageKey @"DockExtraBatteryShowsPercentage"
#define DockBatteryMaxKeys 8

@interface DockBatteryExtra : NSObject <DockExtra>
{
  id <DockExtraHost> _host;
  DockBatteryInfo _info;
  BOOL _present;
  BOOL _testData;
  int _pipe[2];
  int _tokens[DockBatteryMaxKeys];
  NSFileHandle *_handle;
}
@end

static NSArray *
DockBatteryRunLoopModes(void)
{
  return [NSArray arrayWithObjects:NSDefaultRunLoopMode,
		  NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil];
}

static NSString *
DockBatteryDuration(int minutes)
{
  return [NSString stringWithFormat:@"%d:%02d", minutes / 60, minutes % 60];
}

@implementation DockBatteryExtra

- (id) initWithDockHost: (id <DockExtraHost>)host
{
  self = [super init];
  if (self)
    {
      NSUInteger i;

      _host = host;
      [[NSUserDefaults standardUserDefaults] registerDefaults:
	[NSDictionary dictionaryWithObject:@"YES" forKey:ShowsPercentageKey]];
      for (i = 0; i < DockBatteryMaxKeys; i++)
	{
	  _tokens[i] = -1;
	}
      DockExtraNotifyPipe(_pipe);
      for (i = 0; DockBatteryNotifyKeys[i] && i < DockBatteryMaxKeys; i++)
	{
	  _tokens[i] = DockExtraNotifyRegister(DockBatteryNotifyKeys[i],
					       _pipe[1]);
	}
      if (_pipe[0] >= 0)
	{
	  _handle = [[NSFileHandle alloc] initWithFileDescriptor:_pipe[0]
						  closeOnDealloc:NO];
	  [[NSNotificationCenter defaultCenter]
	    addObserver:self
	       selector:@selector(powerSourcesChanged:)
		   name:NSFileHandleDataAvailableNotification
		 object:_handle];
	  [_handle waitForDataInBackgroundAndNotifyForModes:
		     DockBatteryRunLoopModes()];
	}
      [self readPowerSources];
    }
  return self;
}

- (void) dockExtraWillUnload
{
  NSUInteger i;

  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  for (i = 0; i < DockBatteryMaxKeys; i++)
    {
      DockExtraNotifyCancel(_tokens[i]);
      _tokens[i] = -1;
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
  DEALLOC;
}

- (void) readPowerSources
{
  DockBatteryInfo info;
  BOOL present = DockBatteryRead(&info) != 0;
  BOOL wasPresent = _present;

  _testData = NO;
  if (!present && [_host dockExtrasUseTestData])
    {
      NSDictionary *test = [_host dockExtrasTestData];
      id value;

      memset(&info, 0, sizeof(info));
      value = [test objectForKey:@"BatteryPercent"];
      info.percent = value ? [value intValue] : 72;
      value = [test objectForKey:@"BatteryCharging"];
      info.charging = value ? [value boolValue] : YES;
      value = [test objectForKey:@"BatteryOnAC"];
      info.onAC = value ? [value boolValue] : info.charging;
      info.minutesToFull = info.charging ? 48 : -1;
      info.minutesToEmpty = info.onAC ? -1 : 205;
      strcpy(info.name, "Test battery");
      strcpy(info.health, "Good");
      present = YES;
      _testData = YES;
    }
  if (present == wasPresent && memcmp(&info, &_info, sizeof(info)) == 0)
    {
      return;
    }
  _info = info;
  _present = present;
  if (present != wasPresent)
    {
      [_host dockExtraAvailabilityDidChange:self];
    }
  [_host dockExtraNeedsDisplay:self];
}

- (void) powerSourcesChanged: (NSNotification *)notification
{
  DockExtraNotifyDrain(_pipe[0]);
  [self readPowerSources];
  [self performSelector:@selector(watch) withObject:nil afterDelay:0.0];
}

- (void) watch
{
  [_handle waitForDataInBackgroundAndNotifyForModes:DockBatteryRunLoopModes()];
}

- (BOOL) isAvailable
{
  return _present;
}

- (void) drawBoltInRect: (NSRect)r color: (NSColor *)color
{
  NSBezierPath *bolt = [NSBezierPath bezierPath];
  CGFloat x = NSMinX(r), y = NSMinY(r), w = NSWidth(r), h = NSHeight(r);

  [bolt moveToPoint:NSMakePoint(x + w * 0.58, y + h)];
  [bolt lineToPoint:NSMakePoint(x + w * 0.18, y + h * 0.42)];
  [bolt lineToPoint:NSMakePoint(x + w * 0.46, y + h * 0.42)];
  [bolt lineToPoint:NSMakePoint(x + w * 0.38, y)];
  [bolt lineToPoint:NSMakePoint(x + w * 0.82, y + h * 0.60)];
  [bolt lineToPoint:NSMakePoint(x + w * 0.54, y + h * 0.60)];
  [bolt closePath];
  /* A dark outline keeps the bolt clear of the charge level under it. */
  [[NSColor colorWithCalibratedWhite:0.13 alpha:1.0] set];
  [bolt setLineWidth:2.0];
  [bolt stroke];
  [color set];
  [bolt fill];
}

- (void) drawInRect: (NSRect)rect
{
  NSRect plate = DockExtraPlateRect(rect);
  CGFloat s = NSWidth(plate);
  BOOL percentage = [[NSUserDefaults standardUserDefaults]
		      boolForKey:ShowsPercentageKey];
  NSColor *white = DockExtraForegroundColor(NO);
  NSRect body;
  NSRect nub;
  NSRect level;
  NSBezierPath *outline;
  NSColor *fill;

  DockExtraDrawPlate(rect);
  body = NSMakeRect(NSMinX(plate) + s * 0.14,
		    NSMinY(plate) + s * (percentage ? 0.46 : 0.33),
		    s * 0.64, s * 0.32);
  body = NSIntegralRect(body);
  nub = NSMakeRect(NSMaxX(body) + 1.0, NSMidY(body) - s * 0.07,
		   MAX(2.0, s * 0.06), s * 0.14);
  outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 0.5, 0.5)
					    xRadius:s * 0.06
					    yRadius:s * 0.06];
  [outline setLineWidth:MAX(1.0, s * 0.035)];
  [white set];
  [outline stroke];
  [[NSBezierPath bezierPathWithRoundedRect:nub xRadius:1.5 yRadius:1.5] fill];

  level = NSInsetRect(body, MAX(2.0, s * 0.05), MAX(2.0, s * 0.05));
  level.size.width = floor(NSWidth(level) * _info.percent / 100.0);
  if (_info.charging || _info.onAC)
    {
      fill = [NSColor colorWithCalibratedRed:0.30 green:0.85 blue:0.40 alpha:1.0];
    }
  else if (_info.percent <= 10)
    {
      fill = [NSColor colorWithCalibratedRed:1.0 green:0.30 blue:0.25 alpha:1.0];
    }
  else
    {
      fill = white;
    }
  [fill set];
  [[NSBezierPath bezierPathWithRoundedRect:level xRadius:s * 0.03
				   yRadius:s * 0.03] fill];
  if (_info.charging || _info.onAC)
    {
      CGFloat h = NSHeight(body) * 1.15;

      [self drawBoltInRect:NSMakeRect(NSMidX(body) - h * 0.35,
				      NSMidY(body) - h / 2.0, h * 0.7, h)
		     color:white];
    }
  if (percentage)
    {
      NSString *text = [NSString stringWithFormat:@"%d%%", _info.percent];
      NSDictionary *attributes =
	[NSDictionary dictionaryWithObjectsAndKeys:
			[NSFont boldSystemFontOfSize:floor(s * 0.22)],
		      NSFontAttributeName, white,
		      NSForegroundColorAttributeName, nil];
      NSSize size = [text sizeWithAttributes:attributes];

      [text drawAtPoint:NSMakePoint(floor(NSMidX(plate) - size.width / 2.0),
				    floor(NSMinY(plate) + s * 0.24
					  - size.height / 2.0))
	 withAttributes:attributes];
    }
}

- (NSString *) stateString
{
  if (_info.charged || (_info.onAC && !_info.charging && _info.percent >= 99))
    {
      return @"Charged";
    }
  if (_info.charging)
    {
      return _info.minutesToFull >= 0
	? [NSString stringWithFormat:@"Charging, %@ until full",
		    DockBatteryDuration(_info.minutesToFull)]
	: @"Charging";
    }
  if (_info.onAC)
    {
      return @"On power adapter, not charging";
    }
  return _info.minutesToEmpty >= 0
    ? [NSString stringWithFormat:@"%@ remaining",
		DockBatteryDuration(_info.minutesToEmpty)]
    : @"Calculating time remaining";
}

- (NSString *) toolTip
{
  return [NSString stringWithFormat:@"Battery: %d%% (%@)%@", _info.percent,
		   [self stateString], _testData ? @" [test data]" : @""];
}

- (void) togglePercentage: (id)sender
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  [defaults setBool:![defaults boolForKey:ShowsPercentageKey]
	     forKey:ShowsPercentageKey];
  [defaults synchronize];
  [_host dockExtraNeedsDisplay:self];
}

- (void) addInfo: (NSString *)title toMenu: (NSMenu *)menu
{
  [(NSMenuItem *)[menu addItemWithTitle:title action:NULL keyEquivalent:@""]
		 setEnabled:NO];
}

- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSMenu *menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Battery"]);
  NSString *health = [NSString stringWithUTF8String:_info.health];
  NSMenuItem *item;

  [menu setAutoenablesItems:NO];
  [self addInfo:[NSString stringWithFormat:@"Battery: %d%%", _info.percent]
	 toMenu:menu];
  [self addInfo:[self stateString] toMenu:menu];
  [self addInfo:[NSString stringWithFormat:@"Power Source: %@",
			  _info.onAC ? @"Power Adapter" : @"Battery"]
	 toMenu:menu];
  [self addInfo:[NSString stringWithFormat:@"Condition: %@",
			  ([health length] == 0 || [health isEqual:@"Good"])
			  ? @"Normal" : health]
	 toMenu:menu];
  [menu addItem:[NSMenuItem separatorItem]];
  item = (NSMenuItem *)[menu addItemWithTitle:@"Show Percentage"
				       action:@selector(togglePercentage:)
				keyEquivalent:@""];
  [item setTarget:self];
  [item setState:[[NSUserDefaults standardUserDefaults]
		   boolForKey:ShowsPercentageKey] ? NSOnState : NSOffState];
  return menu;
}

@end
