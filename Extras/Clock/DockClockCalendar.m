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

#import "DockClockCalendar.h"
#import <GNUstepBase/GNUstep.h>

#define CalendarCell 28.0
#define CalendarPad 10.0
#define CalendarHeader 30.0

@interface DockClockCalendarView : NSView
{
  DockClockCalendar *_calendar;
}
- (id) initWithCalendar: (DockClockCalendar *)calendar;
@end

@interface DockClockCalendar (View)
- (NSCalendarDate *) month;
- (NSCalendarDate *) today;
- (void) moveMonths: (NSInteger)months;
@end

@implementation DockClockCalendar

- (id) init
{
  NSRect frame = NSMakeRect(0, 0, 0, 0);
  DockClockCalendarView *view;

  frame.size = [self preferredSize];
  self = [super initWithContentRect:frame
			  styleMask:NSBorderlessWindowMask
			    backing:NSBackingStoreBuffered
			      defer:NO];
  if (self)
    {
      [self setReleasedWhenClosed:NO];
      [self setLevel:NSPopUpMenuWindowLevel];
      [self setOpaque:NO];
      [self setBackgroundColor:[NSColor clearColor]];
      [self setHasShadow:YES];
      [self setHidesOnDeactivate:YES];
      [self setTitle:@"Calendar"];
      view = [[DockClockCalendarView alloc] initWithCalendar:self];
      [self setContentView:view];
      RELEASE(view);
      [[NSNotificationCenter defaultCenter]
	addObserver:self
	   selector:@selector(resigned:)
	       name:NSWindowDidResignKeyNotification
	     object:self];
    }
  return self;
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  DESTROY(_today);
  DESTROY(_month);
  DEALLOC;
}

- (BOOL) canBecomeKeyWindow
{
  return YES;
}

/* A click anywhere else closes it, like a menu. */
- (void) resigned: (NSNotification *)notification
{
  [self close];
}

- (void) keyDown: (NSEvent *)event
{
  NSString *keys = [event charactersIgnoringModifiers];
  unichar key = [keys length] ? [keys characterAtIndex:0] : 0;

  if (key == 27)
    {
      [self close];
    }
  else if (key == NSLeftArrowFunctionKey || key == NSPageUpFunctionKey)
    {
      [self moveMonths:-1];
    }
  else if (key == NSRightArrowFunctionKey || key == NSPageDownFunctionKey)
    {
      [self moveMonths:1];
    }
  else
    {
      [super keyDown:event];
    }
}

- (NSSize) preferredSize
{
  return NSMakeSize(CalendarPad * 2.0 + CalendarCell * 7.0,
		    CalendarPad * 2.0 + CalendarHeader + CalendarCell * 7.0);
}

- (void) setToday: (NSDate *)today
{
  NSCalendarDate *date = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:
					   [today timeIntervalSinceReferenceDate]];

  if (_today && [_today dayOfCommonEra] == [date dayOfCommonEra])
    {
      return;
    }
  ASSIGN(_today, date);
  [[self contentView] setNeedsDisplay:YES];
}

- (void) showMonthOfToday
{
  NSCalendarDate *today = _today ? _today : [NSCalendarDate calendarDate];

  ASSIGN(_month, [NSCalendarDate dateWithYear:[today yearOfCommonEra]
					 month:[today monthOfYear]
					   day:1 hour:12 minute:0 second:0
				      timeZone:[NSTimeZone localTimeZone]]);
  [[self contentView] setNeedsDisplay:YES];
}

- (NSCalendarDate *) month
{
  return _month;
}

- (NSCalendarDate *) today
{
  return _today;
}

- (void) moveMonths: (NSInteger)months
{
  ASSIGN(_month, [_month dateByAddingYears:0 months:months days:0
				     hours:0 minutes:0 seconds:0]);
  [[self contentView] setNeedsDisplay:YES];
}

@end

@implementation DockClockCalendarView

- (id) initWithCalendar: (DockClockCalendar *)calendar
{
  self = [super initWithFrame:NSMakeRect(0, 0, [calendar preferredSize].width,
					 [calendar preferredSize].height)];
  if (self)
    {
      _calendar = calendar;
    }
  return self;
}

- (BOOL) isOpaque
{
  return NO;
}

- (BOOL) acceptsFirstMouse: (NSEvent *)event
{
  return YES;
}

- (NSRect) arrowRectForward: (BOOL)forward
{
  NSRect bounds = [self bounds];
  CGFloat y = NSMaxY(bounds) - CalendarPad - CalendarHeader;

  return NSMakeRect(forward ? NSMaxX(bounds) - CalendarPad - CalendarCell
		    : CalendarPad, y, CalendarCell, CalendarHeader);
}

- (void) mouseDown: (NSEvent *)event
{
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];

  if (NSPointInRect(p, [self arrowRectForward:NO]))
    {
      [_calendar moveMonths:-1];
    }
  else if (NSPointInRect(p, [self arrowRectForward:YES]))
    {
      [_calendar moveMonths:1];
    }
}

- (void) scrollWheel: (NSEvent *)event
{
  if ([event deltaY] > 0.0)
    {
      [_calendar moveMonths:-1];
    }
  else if ([event deltaY] < 0.0)
    {
      [_calendar moveMonths:1];
    }
}

static void
CalendarDrawText(NSString *text, NSFont *font, NSColor *color, NSRect rect)
{
  NSDictionary *attributes =
    [NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName,
		  color, NSForegroundColorAttributeName, nil];
  NSSize size = [text sizeWithAttributes:attributes];

  [text drawAtPoint:NSMakePoint(floor(NSMidX(rect) - size.width / 2.0),
				floor(NSMidY(rect) - size.height / 2.0))
     withAttributes:attributes];
}

- (void) drawRect: (NSRect)dirty
{
  NSRect bounds = [self bounds];
  NSCalendarDate *month = [_calendar month];
  NSCalendarDate *today = [_calendar today];
  NSBezierPath *panel = [NSBezierPath bezierPathWithRoundedRect:
					NSInsetRect(bounds, 0.5, 0.5)
							xRadius:8.0
							yRadius:8.0];
  NSFont *font = [NSFont systemFontOfSize:12.0];
  NSFont *bold = [NSFont boldSystemFontOfSize:13.0];
  NSColor *white = [NSColor colorWithCalibratedWhite:1.0 alpha:0.95];
  NSColor *grey = [NSColor colorWithCalibratedWhite:1.0 alpha:0.55];
  NSArray *days = [NSArray arrayWithObjects:@"Su", @"Mo", @"Tu", @"We",
			   @"Th", @"Fr", @"Sa", nil];
  CGFloat top = NSMaxY(bounds) - CalendarPad - CalendarHeader;
  NSInteger first, length, i;

  [[NSColor clearColor] set];
  NSRectFill(bounds);
  [[NSColor colorWithCalibratedWhite:0.13 alpha:0.96] set];
  [panel fill];
  [[NSColor colorWithCalibratedWhite:1.0 alpha:0.2] set];
  [panel stroke];
  if (!month)
    {
      return;
    }

  CalendarDrawText([month descriptionWithCalendarFormat:@"%B %Y"], bold, white,
		   NSMakeRect(CalendarPad, top, NSWidth(bounds) - 2 * CalendarPad,
			      CalendarHeader));
  CalendarDrawText(@"‹", bold, white, [self arrowRectForward:NO]);
  CalendarDrawText(@"›", bold, white, [self arrowRectForward:YES]);
  for (i = 0; i < 7; i++)
    {
      CalendarDrawText([days objectAtIndex:i], font, grey,
		       NSMakeRect(CalendarPad + i * CalendarCell,
				  top - CalendarCell, CalendarCell, CalendarCell));
    }
  first = [month dayOfWeek];
  length = [[month dateByAddingYears:0 months:1 days:-1 hours:0 minutes:0
			     seconds:0] dayOfMonth];
  for (i = 0; i < length; i++)
    {
      NSInteger slot = first + i;
      NSRect cell = NSMakeRect(CalendarPad + (slot % 7) * CalendarCell,
			       top - CalendarCell * (2 + slot / 7),
			       CalendarCell, CalendarCell);
      BOOL isToday = today && [today yearOfCommonEra] == [month yearOfCommonEra]
	&& [today monthOfYear] == [month monthOfYear]
	&& [today dayOfMonth] == i + 1;

      if (isToday)
	{
	  [[NSColor colorWithCalibratedRed:0.25 green:0.52 blue:0.96 alpha:1.0] set];
	  [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(cell, 2.0, 2.0)] fill];
	}
      CalendarDrawText([NSString stringWithFormat:@"%ld", (long)(i + 1)],
		       isToday ? bold : font,
		       (slot % 7 == 0 || slot % 7 == 6) && !isToday ? grey : white,
		       cell);
    }
}

@end
