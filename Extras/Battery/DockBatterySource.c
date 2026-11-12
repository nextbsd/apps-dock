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

/* Built without GNUstep's headers: see GNUmakefile. */

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <string.h>

#include "DockBatterySource.h"

const char *const DockBatteryNotifyKeys[] = {
  kIOPSNotifyTimeRemaining,
  kIOPSNotifyPowerSource,
  kIOPSNotifyAttach,
  kIOPSNotifyAnyPowerSource,
  NULL
};

static int
DictInt(CFDictionaryRef d, const char *key, int fallback)
{
  CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
  CFTypeRef v = k ? CFDictionaryGetValue(d, k) : NULL;
  int result = fallback;

  if (v && CFGetTypeID(v) == CFNumberGetTypeID())
    {
      CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &result);
    }
  else if (v && CFGetTypeID(v) == CFBooleanGetTypeID())
    {
      result = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    }
  if (k)
    {
      CFRelease(k);
    }
  return result;
}

static int
DictString(CFDictionaryRef d, const char *key, char *out, size_t size)
{
  CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
  CFTypeRef v = k ? CFDictionaryGetValue(d, k) : NULL;
  int ok = 0;

  out[0] = '\0';
  if (v && CFGetTypeID(v) == CFStringGetTypeID())
    {
      ok = CFStringGetCString((CFStringRef)v, out, (CFIndex)size,
			      kCFStringEncodingUTF8);
    }
  if (k)
    {
      CFRelease(k);
    }
  return ok;
}

int
DockBatteryRead(DockBatteryInfo *info)
{
  CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
  CFArrayRef list = snapshot ? IOPSCopyPowerSourcesList(snapshot) : NULL;
  CFIndex i;
  int found = 0;

  memset(info, 0, sizeof(*info));
  info->minutesToEmpty = info->minutesToFull = -1;
  for (i = 0; list && i < CFArrayGetCount(list) && !found; i++)
    {
      CFDictionaryRef d = IOPSGetPowerSourceDescription(snapshot,
		CFArrayGetValueAtIndex(list, i));
      char type[64];
      char state[64];
      int max;

      if (!d || !DictString(d, kIOPSTypeKey, type, sizeof(type)) ||
	  strcmp(type, kIOPSInternalBatteryType) != 0 ||
	  !DictInt(d, kIOPSIsPresentKey, 1))
	{
	  continue;
	}
      found = 1;
      max = DictInt(d, kIOPSMaxCapacityKey, 100);
      info->percent = DictInt(d, kIOPSCurrentCapacityKey, 0);
      if (max > 0 && max != 100)
	{
	  info->percent = info->percent * 100 / max;
	}
      if (info->percent < 0)
	{
	  info->percent = 0;
	}
      if (info->percent > 100)
	{
	  info->percent = 100;
	}
      info->charging = DictInt(d, kIOPSIsChargingKey, 0);
      info->charged = DictInt(d, kIOPSIsChargedKey, 0);
      DictString(d, kIOPSPowerSourceStateKey, state, sizeof(state));
      info->onAC = strcmp(state, kIOPSACPowerValue) == 0;
      info->minutesToEmpty = DictInt(d, kIOPSTimeToEmptyKey, -1);
      info->minutesToFull = DictInt(d, kIOPSTimeToFullChargeKey, -1);
      DictString(d, kIOPSNameKey, info->name, sizeof(info->name));
      DictString(d, kIOPSBatteryHealthKey, info->health, sizeof(info->health));
    }
  if (list)
    {
      CFRelease(list);
    }
  if (snapshot)
    {
      CFRelease(snapshot);
    }
  return found;
}
