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
 * The battery extra's data source: IOPowerSources, served by NextBSD's
 * powerd and pmconfigd. A plain C interface, so that the extra itself
 * needn't see CoreFoundation's headers (GNUstep has its own).
 */

#ifndef _DOCK_BATTERY_SOURCE_H_
#define _DOCK_BATTERY_SOURCE_H_

typedef struct
{
  int percent;		/* 0-100 */
  int charging;		/* charging now */
  int charged;		/* full, on AC */
  int onAC;		/* the Mac way: "AC Power" is providing power */
  int minutesToEmpty;	/* -1: unknown or not discharging */
  int minutesToFull;	/* -1: unknown or not charging */
  char name[64];
  char health[32];	/* BatteryHealth: Good, Fair, Poor; "" unknown */
} DockBatteryInfo;

/* The internal battery, if there is one: 1 and *info filled, else 0. */
int DockBatteryRead(DockBatteryInfo *info);

/* The notify(3) keys powerd posts when anything above changes: what
 * IOPSNotificationCreateRunLoopSource listens to, and more. NULL-ended. */
extern const char *const DockBatteryNotifyKeys[];

#endif
