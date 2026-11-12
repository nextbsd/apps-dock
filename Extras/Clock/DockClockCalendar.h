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

/* The clock extra's month calendar: a small panel beside its tile. */

#import <AppKit/AppKit.h>

@interface DockClockCalendar : NSPanel
{
  NSCalendarDate *_today;
  /* The month shown: its first day. */
  NSCalendarDate *_month;
}
- (NSSize) preferredSize;
- (void) setToday: (NSDate *)today;
- (void) showMonthOfToday;
@end
