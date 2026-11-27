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
 * The screen recording indicator (nextbsd/nextbsd#715): while
 * Screenshot.app (apps-settings) records the screen, a red dot, the
 * time recorded and a stop button; a click stops the recording. Like
 * every extra it is a status item in the Mac menu style's menu bar, a
 * tile in the Windows style's taskbar and in the Dock otherwise, and
 * it has no tile at all while nothing records. A click on the tile
 * stops the recording; in the menu bar the item's menu has Stop
 * Recording.
 *
 * Screenshot says when it starts and stops with the distributed
 * notification org.nextbsd.Screenshot.RecordingChanged (Recording,
 * Started: seconds since 1970); the extra asks for it once at load
 * (org.nextbsd.Screenshot.RecordingQuery), in case a recording began
 * before the Dock did, and stops one with org.nextbsd.Screenshot.Stop.
 * apps-settings' Screenshot/SSRequest.h has the same names; keep the
 * two in step.
 */

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "DockExtra.h"

#define RecordingChanged @"org.nextbsd.Screenshot.RecordingChanged"
#define RecordingQuery @"org.nextbsd.Screenshot.RecordingQuery"
#define RecordingStop @"org.nextbsd.Screenshot.Stop"

@interface DockRecordingExtra : NSObject <DockExtra>
{
  id <DockExtraHost> _host;
  BOOL _recording;
  BOOL _stopping;
  NSTimeInterval _started;	/* since 1970 */
  NSTimer *_timer;
}
@end

static NSColor *
RecordingRed(void)
{
  return [NSColor colorWithCalibratedRed:0.95 green:0.24 blue:0.20 alpha:1.0];
}

@implementation DockRecordingExtra

- (id) initWithDockHost: (id <DockExtraHost>)host
{
  self = [super init];
  if (self)
    {
      NSDistributedNotificationCenter *dnc =
	[NSDistributedNotificationCenter defaultCenter];

      _host = host;
      [dnc addObserver:self
	      selector:@selector(recordingChanged:)
		  name:RecordingChanged
		object:nil];
      [dnc postNotificationName:RecordingQuery
			 object:nil
		       userInfo:nil
	     deliverImmediately:YES];
    }
  return self;
}

- (void) dockExtraWillUnload
{
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  [_timer invalidate];
  _timer = nil;
  _host = nil;
}

- (void) dealloc
{
  [self dockExtraWillUnload];
  DEALLOC;
}

- (void) tick: (NSTimer *)timer
{
  [_host dockExtraNeedsDisplay:self];
}

- (void) recordingChanged: (NSNotification *)note
{
  NSDictionary *info = [note userInfo];
  BOOL recording = [[info objectForKey:@"Recording"] boolValue];
  id started = [info objectForKey:@"Started"];

  _started = [started respondsToSelector:@selector(doubleValue)]
    ? [started doubleValue] : [[NSDate date] timeIntervalSince1970];
  _stopping = NO;
  [_timer invalidate];
  _timer = nil;
  if (recording)
    {
      _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
						target:self
					      selector:@selector(tick:)
					      userInfo:nil
					       repeats:YES];
    }
  if (recording != _recording)
    {
      _recording = recording;
      [_host dockExtraAvailabilityDidChange:self];
    }
  [_host dockExtraNeedsDisplay:self];
}

- (BOOL) isAvailable
{
  return _recording;
}

/* "0:42", "12:05", "1:02:07" */
- (NSString *) elapsed
{
  long s = (long)([[NSDate date] timeIntervalSince1970] - _started);

  if (s < 0)
    {
      s = 0;
    }
  if (s >= 3600)
    {
      return [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600,
		       (s / 60) % 60, s % 60];
    }
  return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

static void
drawDot(NSPoint center, CGFloat radius)
{
  [RecordingRed() set];
  [[NSBezierPath bezierPathWithOvalInRect:
		   NSMakeRect(center.x - radius, center.y - radius,
			      2 * radius, 2 * radius)] fill];
}

static void
drawStop(NSRect square, NSColor *color)
{
  NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:square
						    xRadius:1.5
						    yRadius:1.5];

  [color set];
  [p setLineWidth:1.4];
  [p stroke];
}

/* The tile: the dot and the stop button over the time. */
- (void) drawInRect: (NSRect)rect
{
  NSRect plate = DockExtraPlateRect(rect);
  CGFloat unit = NSWidth(plate) / 10.0;
  NSString *time = [self elapsed];
  NSDictionary *attrs;
  NSSize size;

  DockExtraDrawPlate(rect);
  drawDot(NSMakePoint(NSMidX(plate) - 1.6 * unit, NSMinY(plate) + 6.6 * unit),
	  1.3 * unit);
  drawStop(NSMakeRect(NSMidX(plate) + 0.6 * unit, NSMinY(plate) + 5.4 * unit,
		      2.4 * unit, 2.4 * unit),
	   DockExtraForegroundColor(NO));
  attrs = [NSDictionary dictionaryWithObjectsAndKeys:
			  [NSFont boldSystemFontOfSize:floor(2.6 * unit)],
			NSFontAttributeName,
			DockExtraForegroundColor(_stopping),
			NSForegroundColorAttributeName, nil];
  size = [time sizeWithAttributes:attrs];
  [time drawAtPoint:NSMakePoint(floor(NSMidX(plate) - size.width / 2),
				floor(NSMinY(plate) + 1.6 * unit))
     withAttributes:attrs];
}

- (NSString *) toolTip
{
  return [NSString stringWithFormat:@"Recording the screen, %@: "
		   @"click to stop", [self elapsed]];
}

/* In the menu bar: the dot, the time in red, and the stop button, as on
 * a Mac. */
- (NSDictionary *) menuBarAttributes
{
  return [NSDictionary dictionaryWithObjectsAndKeys:
			 [NSFont boldSystemFontOfSize:13],
		       NSFontAttributeName, RecordingRed(),
		       NSForegroundColorAttributeName, nil];
}

- (CGFloat) statusItemWidthForHeight: (CGFloat)height
{
  NSSize size = [@"00:00" sizeWithAttributes:[self menuBarAttributes]];

  return ceil(8 + height * 0.5 + 6 + size.width + 8 + height * 0.55 + 8);
}

- (void) drawStatusItemInRect: (NSRect)rect color: (NSColor *)color
{
  NSDictionary *attrs = [self menuBarAttributes];
  NSString *time = [self elapsed];
  NSSize size = [time sizeWithAttributes:attrs];
  CGFloat h = NSHeight(rect), x = NSMinX(rect) + 8;
  CGFloat stop = floor(h * 0.42);
  NSRect pill = NSInsetRect(rect, 1, floor(h * 0.12));

  [[RecordingRed() colorWithAlphaComponent:0.14] set];
  [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:5 yRadius:5] fill];
  drawDot(NSMakePoint(x + h * 0.25, NSMidY(rect)), h * 0.2);
  x += h * 0.5 + 6;
  [time drawAtPoint:NSMakePoint(floor(x), floor(NSMidY(rect)
						 - size.height / 2))
     withAttributes:attrs];
  drawStop(NSMakeRect(floor(NSMaxX(rect) - 8 - stop),
		      floor(NSMidY(rect) - stop / 2), stop, stop),
	   RecordingRed());
}

- (void) stopRecording: (id)sender
{
  if (_stopping)
    {
      return;
    }
  _stopping = YES;
  [[NSDistributedNotificationCenter defaultCenter]
    postNotificationName:RecordingStop
		  object:nil
		userInfo:nil
      deliverImmediately:YES];
  [_host dockExtraNeedsDisplay:self];
}

/* In the Dock and the taskbar a click stops the recording at once. In
 * the menu bar, whose items always drop a menu, the menu has Stop
 * Recording: the item goes when the recording ends, and it mustn't go
 * while its own menu is open. */
- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSMenu *menu;
  NSMenuItem *item;

  if (event != nil)
    {
      [self stopRecording:nil];
      return nil;
    }
  menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Recording"]);
  item = (NSMenuItem *)[menu addItemWithTitle:[NSString stringWithFormat:
						  @"Recording the screen, %@",
						[self elapsed]]
				       action:NULL
				keyEquivalent:@""];
  [item setEnabled:NO];
  item = (NSMenuItem *)[menu addItemWithTitle:@"Stop Recording"
				       action:@selector(stopRecording:)
				keyEquivalent:@""];
  [item setTarget:self];
  return menu;
}

@end
