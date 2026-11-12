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
 * The date and clock Dock extra: the time with the day and date, digital
 * or analog, fitted to the Dock's cell. A click shows a small month
 * calendar; the right-click menu has the settings.
 *
 * It wakes on the minute (on the second while seconds are shown) from a
 * timerfd armed for the next boundary of the wall clock, with
 * TFD_TIMER_CANCEL_ON_SET so that setting the clock wakes it at once
 * too. Time zone changes come from notify(3) (com.apple.system.timezone)
 * where something posts it, and from /etc/localtime's change time, read
 * on each tick.
 *
 * Defaults (the Dock's): DockExtraClockAnalog, DockExtraClock24Hour,
 * DockExtraClockShowsSeconds, DockExtraClockShowsDate.
 */

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "DockExtra.h"
#import "DockExtraNotify.h"
#import "DockClockCalendar.h"

#include <sys/stat.h>
#include <sys/timerfd.h>
#include <errno.h>
#include <math.h>
#include <time.h>

#define AnalogKey @"DockExtraClockAnalog"
#define TwentyFourHourKey @"DockExtraClock24Hour"
#define ShowsSecondsKey @"DockExtraClockShowsSeconds"
#define ShowsDateKey @"DockExtraClockShowsDate"

@interface DockClockExtra : NSObject <DockExtra>
{
  id <DockExtraHost> _host;
  int _timerFD;
  NSFileHandle *_timerHandle;
  BOOL _timerWatched;
  int _notifyPipe[2];
  int _notifyTokens[2];
  NSFileHandle *_notifyHandle;
  struct timespec _zoneChange;
  DockClockCalendar *_calendar;
}
@end

static NSArray *
DockClockRunLoopModes(void)
{
  return [NSArray arrayWithObjects:NSDefaultRunLoopMode,
		  NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil];
}

@implementation DockClockExtra

- (id) initWithDockHost: (id <DockExtraHost>)host
{
  self = [super init];
  if (self)
    {
      NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

      _host = host;
      [defaults registerDefaults:
		  [NSDictionary dictionaryWithObjectsAndKeys:
				  @"NO", AnalogKey,
				@"YES", TwentyFourHourKey,
				@"NO", ShowsSecondsKey,
				@"YES", ShowsDateKey, nil]];

      _timerFD = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
      if (_timerFD >= 0)
	{
	  _timerHandle = [[NSFileHandle alloc] initWithFileDescriptor:_timerFD
						       closeOnDealloc:NO];
	  [[NSNotificationCenter defaultCenter]
	    addObserver:self
	       selector:@selector(timerFired:)
		   name:NSFileHandleDataAvailableNotification
		 object:_timerHandle];
	}
      else
	{
	  NSLog(@"Clock extra: timerfd_create failed (%s)", strerror(errno));
	}

      DockExtraNotifyPipe(_notifyPipe);
      _notifyTokens[0] = DockExtraNotifyRegister("com.apple.system.timezone",
						 _notifyPipe[1]);
      _notifyTokens[1] = DockExtraNotifyRegister("com.apple.system.clock_set",
						 _notifyPipe[1]);
      if (_notifyPipe[0] >= 0)
	{
	  _notifyHandle = [[NSFileHandle alloc]
			    initWithFileDescriptor:_notifyPipe[0]
				    closeOnDealloc:NO];
	  [[NSNotificationCenter defaultCenter]
	    addObserver:self
	       selector:@selector(timeChanged:)
		   name:NSFileHandleDataAvailableNotification
		 object:_notifyHandle];
	  [_notifyHandle waitForDataInBackgroundAndNotifyForModes:
			   DockClockRunLoopModes()];
	}
      [self checkTimeZone];
      [self armTimer];
    }
  return self;
}

- (void) dockExtraWillUnload
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_calendar close];
  DESTROY(_calendar);
  /* closeFile stops the run loop watching the descriptor, and closes it. */
  [_timerHandle closeFile];
  DESTROY(_timerHandle);
  _timerFD = -1;
  DockExtraNotifyCancel(_notifyTokens[0]);
  DockExtraNotifyCancel(_notifyTokens[1]);
  _notifyTokens[0] = _notifyTokens[1] = -1;
  [_notifyHandle closeFile];
  DESTROY(_notifyHandle);
  if (_notifyPipe[1] >= 0)
    {
      close(_notifyPipe[1]);
    }
  _notifyPipe[0] = _notifyPipe[1] = -1;
  _host = nil;
}

- (void) dealloc
{
  [self dockExtraWillUnload];
  DEALLOC;
}

- (BOOL) isAvailable
{
  return YES;
}

/* Wake at the next minute (or second) of the wall clock, or when the
 * clock is set. */
- (void) armTimer
{
  struct itimerspec spec;
  struct timespec now;
  time_t step = [[NSUserDefaults standardUserDefaults]
		  boolForKey:ShowsSecondsKey] ? 1 : 60;

  if (_timerFD < 0)
    {
      return;
    }
  clock_gettime(CLOCK_REALTIME, &now);
  memset(&spec, 0, sizeof(spec));
  spec.it_value.tv_sec = (now.tv_sec / step + 1) * step;
  if (timerfd_settime(_timerFD, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET,
		      &spec, NULL) != 0)
    {
      NSLog(@"Clock extra: timerfd_settime failed (%s)", strerror(errno));
      return;
    }
  if (!_timerWatched)
    {
      _timerWatched = YES;
      [_timerHandle waitForDataInBackgroundAndNotifyForModes:
		      DockClockRunLoopModes()];
    }
}

- (void) checkTimeZone
{
  struct stat st;

  if (stat("/etc/localtime", &st) == 0 &&
      (st.st_ctim.tv_sec != _zoneChange.tv_sec ||
       st.st_ctim.tv_nsec != _zoneChange.tv_nsec))
    {
      BOOL first = _zoneChange.tv_sec == 0 && _zoneChange.tv_nsec == 0;

      _zoneChange = st.st_ctim;
      if (!first)
	{
	  tzset();
	  [NSTimeZone resetSystemTimeZone];
	}
    }
}

- (void) timerFired: (NSNotification *)notification
{
  uint64_t expirations;

  /* ECANCELED: the clock was set. Either way, redraw and re-arm. */
  (void)read(_timerFD, &expirations, sizeof(expirations));
  _timerWatched = NO;
  [self checkTimeZone];
  [_host dockExtraNeedsDisplay:self];
  [_calendar setToday:[NSDate date]];
  /* The handle is still finishing this wait; wait again after it. */
  [self performSelector:@selector(armTimer) withObject:nil afterDelay:0.0];
}

- (void) timeChanged: (NSNotification *)notification
{
  DockExtraNotifyDrain(_notifyPipe[0]);
  tzset();
  [NSTimeZone resetSystemTimeZone];
  [_host dockExtraNeedsDisplay:self];
  [_calendar setToday:[NSDate date]];
  [self armTimer];
  [self performSelector:@selector(watchNotifications) withObject:nil
	     afterDelay:0.0];
}

- (void) watchNotifications
{
  [_notifyHandle waitForDataInBackgroundAndNotifyForModes:
		   DockClockRunLoopModes()];
}

- (NSString *) timeStringWithSeconds: (BOOL)seconds
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *format;

  if ([defaults boolForKey:TwentyFourHourKey])
    {
      format = seconds ? @"%H:%M:%S" : @"%H:%M";
    }
  else
    {
      format = seconds ? @"%I:%M:%S" : @"%I:%M";
    }
  {
    NSString *string = [[NSCalendarDate calendarDate]
			 descriptionWithCalendarFormat:format];

    /* 9:05, not 09:05, on a 12-hour clock. */
    if (![defaults boolForKey:TwentyFourHourKey] && [string hasPrefix:@"0"])
      {
	string = [string substringFromIndex:1];
      }
    return string;
  }
}

/* The largest font of this kind, up to size, whose text fits width. */
static NSFont *
DockClockFittedFont(NSString *text, BOOL bold, CGFloat size, CGFloat width)
{
  NSFont *font;

  for (;;)
    {
      font = bold ? [NSFont boldSystemFontOfSize:size]
	: [NSFont systemFontOfSize:size];
      if (size <= 6.0 ||
	  [text sizeWithAttributes:
		  [NSDictionary dictionaryWithObject:font
					      forKey:NSFontAttributeName]].width
	  <= width)
	{
	  return font;
	}
      size -= 0.5;
    }
}

static void
DockClockDrawCentered(NSString *text, NSFont *font, NSColor *color,
		      CGFloat midX, CGFloat midY)
{
  NSDictionary *attributes =
    [NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName,
		  color, NSForegroundColorAttributeName, nil];
  NSSize size = [text sizeWithAttributes:attributes];

  [text drawAtPoint:NSMakePoint(floor(midX - size.width / 2.0),
				floor(midY - size.height / 2.0))
     withAttributes:attributes];
}

- (void) drawDigitalInRect: (NSRect)plate
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSCalendarDate *now = [NSCalendarDate calendarDate];
  BOOL showsDate = [defaults boolForKey:ShowsDateKey];
  BOOL seconds = [defaults boolForKey:ShowsSecondsKey];
  NSString *time = [self timeStringWithSeconds:seconds];
  CGFloat side = NSWidth(plate);
  CGFloat width = side * 0.88;
  NSColor *white = DockExtraForegroundColor(NO);
  NSColor *soft = [NSColor colorWithCalibratedWhite:1.0 alpha:0.72];
  NSFont *timeFont = DockClockFittedFont(time, YES, floor(side * 0.32), width);

  if (!showsDate)
    {
      DockClockDrawCentered(time, timeFont, white, NSMidX(plate), NSMidY(plate));
      if (![defaults boolForKey:TwentyFourHourKey])
	{
	  DockClockDrawCentered([now descriptionWithCalendarFormat:@"%p"],
				[NSFont systemFontOfSize:floor(side * 0.15)],
				soft, NSMidX(plate),
				NSMinY(plate) + side * 0.18);
	}
      return;
    }
  {
    NSString *day = [[now descriptionWithCalendarFormat:@"%a"] uppercaseString];
    NSString *date = [now descriptionWithCalendarFormat:@"%e %b"];
    NSFont *small;

    date = [date stringByTrimmingCharactersInSet:
		   [NSCharacterSet whitespaceCharacterSet]];
    if (![defaults boolForKey:TwentyFourHourKey])
      {
	day = [NSString stringWithFormat:@"%@ %@", day,
			[now descriptionWithCalendarFormat:@"%p"]];
      }
    small = DockClockFittedFont(day, NO, floor(side * 0.17), width);
    DockClockDrawCentered(day, small, soft, NSMidX(plate),
			  NSMinY(plate) + side * 0.80);
    DockClockDrawCentered(time, timeFont, white, NSMidX(plate),
			  NSMinY(plate) + side * 0.50);
    small = DockClockFittedFont(date, NO, floor(side * 0.17), width);
    DockClockDrawCentered(date, small, soft, NSMidX(plate),
			  NSMinY(plate) + side * 0.20);
  }
}

static void
DockClockDrawHand(NSPoint center, CGFloat angle, CGFloat length,
		  CGFloat width, NSColor *color)
{
  NSBezierPath *path = [NSBezierPath bezierPath];

  [path moveToPoint:center];
  [path lineToPoint:NSMakePoint(center.x + sin(angle) * length,
				center.y + cos(angle) * length)];
  [path setLineWidth:width];
  [path setLineCapStyle:NSRoundLineCapStyle];
  [color set];
  [path stroke];
}

- (void) drawAnalogInRect: (NSRect)plate
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSCalendarDate *now = [NSCalendarDate calendarDate];
  BOOL showsDate = [defaults boolForKey:ShowsDateKey];
  CGFloat side = NSWidth(plate);
  CGFloat radius = side * (showsDate ? 0.33 : 0.42);
  NSPoint center = NSMakePoint(NSMidX(plate),
			       showsDate ? NSMinY(plate) + side * 0.60
			       : NSMidY(plate));
  NSColor *white = DockExtraForegroundColor(NO);
  NSBezierPath *face;
  double hour = [now hourOfDay] % 12 + [now minuteOfHour] / 60.0;
  double minute = [now minuteOfHour] + [now secondOfMinute] / 60.0;
  NSInteger i;

  face = [NSBezierPath bezierPathWithOvalInRect:
			 NSMakeRect(center.x - radius, center.y - radius,
				    radius * 2.0, radius * 2.0)];
  [[NSColor colorWithCalibratedWhite:1.0 alpha:0.10] set];
  [face fill];
  [[NSColor colorWithCalibratedWhite:1.0 alpha:0.55] set];
  [face setLineWidth:MAX(1.0, side * 0.025)];
  [face stroke];
  for (i = 0; i < 12; i++)
    {
      double angle = i * M_PI / 6.0;
      CGFloat inner = radius * (i % 3 == 0 ? 0.72 : 0.82);
      NSBezierPath *tick = [NSBezierPath bezierPath];

      [tick moveToPoint:NSMakePoint(center.x + sin(angle) * inner,
				    center.y + cos(angle) * inner)];
      [tick lineToPoint:NSMakePoint(center.x + sin(angle) * radius * 0.92,
				    center.y + cos(angle) * radius * 0.92)];
      [tick setLineWidth:MAX(1.0, side * (i % 3 == 0 ? 0.03 : 0.018))];
      [tick stroke];
    }
  DockClockDrawHand(center, hour * M_PI / 6.0, radius * 0.52,
		    MAX(1.5, side * 0.05), white);
  DockClockDrawHand(center, minute * M_PI / 30.0, radius * 0.80,
		    MAX(1.0, side * 0.035), white);
  if ([defaults boolForKey:ShowsSecondsKey])
    {
      DockClockDrawHand(center, [now secondOfMinute] * M_PI / 30.0,
			radius * 0.86, 1.0,
			[NSColor colorWithCalibratedRed:1.0 green:0.45
						   blue:0.3 alpha:1.0]);
    }
  if (showsDate)
    {
      NSString *date = [[now descriptionWithCalendarFormat:@"%a %e"]
			 uppercaseString];

      DockClockDrawCentered(date,
			    DockClockFittedFont(date, NO, floor(side * 0.16),
						side * 0.88),
			    [NSColor colorWithCalibratedWhite:1.0 alpha:0.72],
			    NSMidX(plate), NSMinY(plate) + side * 0.12);
    }
}

- (void) drawInRect: (NSRect)rect
{
  NSRect plate = DockExtraPlateRect(rect);

  DockExtraDrawPlate(rect);
  if ([[NSUserDefaults standardUserDefaults] boolForKey:AnalogKey])
    {
      [self drawAnalogInRect:plate];
    }
  else
    {
      [self drawDigitalInRect:plate];
    }
}

- (NSString *) toolTip
{
  return [[[NSCalendarDate calendarDate]
	    descriptionWithCalendarFormat:@"%A, %e %B %Y"]
	   stringByReplacingOccurrencesOfString:@"  " withString:@" "];
}

- (void) toggleCalendar
{
  if ([_calendar isVisible])
    {
      [_calendar close];
      return;
    }
  if (!_calendar)
    {
      _calendar = [DockClockCalendar new];
    }
  [_calendar setToday:[NSDate date]];
  [_calendar showMonthOfToday];
  [_calendar setFrame:[_host dockExtra:self
		       panelFrameForSize:[_calendar preferredSize]]
	      display:YES];
  [NSApp activateIgnoringOtherApps:YES];
  [_calendar makeKeyAndOrderFront:self];
}

- (NSMenuItem *) addItem: (NSString *)title
		  action: (SEL)action
		   state: (BOOL)state
		  toMenu: (NSMenu *)menu
{
  NSMenuItem *item = (NSMenuItem *)[menu addItemWithTitle:title action:action
			      keyEquivalent:@""];

  [item setTarget:self];
  [item setState:state ? NSOnState : NSOffState];
  return item;
}

- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSMenu *menu;
  NSMenuItem *item;

  /* A click shows the calendar; the menu is the right-click's. */
  if ([event type] == NSLeftMouseDown)
    {
      [self toggleCalendar];
      return nil;
    }
  menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Clock"]);
  [menu setAutoenablesItems:NO];
  item = (NSMenuItem *)[menu addItemWithTitle:[self toolTip] action:NULL keyEquivalent:@""];
  [item setEnabled:NO];
  [self addItem:@"Show Calendar" action:@selector(showCalendar:) state:NO
	 toMenu:menu];
  [menu addItem:[NSMenuItem separatorItem]];
  [self addItem:@"Digital" action:@selector(chooseDigital:)
	  state:![defaults boolForKey:AnalogKey] toMenu:menu];
  [self addItem:@"Analog" action:@selector(chooseAnalog:)
	  state:[defaults boolForKey:AnalogKey] toMenu:menu];
  [menu addItem:[NSMenuItem separatorItem]];
  [self addItem:@"24-Hour Clock" action:@selector(toggle24Hour:)
	  state:[defaults boolForKey:TwentyFourHourKey] toMenu:menu];
  [self addItem:@"Show Seconds" action:@selector(toggleSeconds:)
	  state:[defaults boolForKey:ShowsSecondsKey] toMenu:menu];
  [self addItem:@"Show Date" action:@selector(toggleDate:)
	  state:[defaults boolForKey:ShowsDateKey] toMenu:menu];
  return menu;
}

- (void) setBool: (BOOL)value forKey: (NSString *)key
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  [defaults setBool:value forKey:key];
  [defaults synchronize];
  [self armTimer];
  [_host dockExtraNeedsDisplay:self];
}

- (void) showCalendar: (id)sender
{
  if (![_calendar isVisible])
    {
      [self toggleCalendar];
    }
}

- (void) chooseDigital: (id)sender
{
  [self setBool:NO forKey:AnalogKey];
}

- (void) chooseAnalog: (id)sender
{
  [self setBool:YES forKey:AnalogKey];
}

- (void) toggle24Hour: (id)sender
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  [self setBool:![defaults boolForKey:TwentyFourHourKey]
	 forKey:TwentyFourHourKey];
}

- (void) toggleSeconds: (id)sender
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  [self setBool:![defaults boolForKey:ShowsSecondsKey] forKey:ShowsSecondsKey];
}

- (void) toggleDate: (id)sender
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  [self setBool:![defaults boolForKey:ShowsDateKey] forKey:ShowsDateKey];
}

@end
