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

/* Built without GNUstep's headers: see GNUmakefile. */

#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "DockWiFiSource.h"

#define AirPortPattern "State:/Network/Interface/[^/]+/AirPort"

static dispatch_queue_t
DockWiFiQueue(void)
{
  static dispatch_queue_t queue = NULL;

  if (queue == NULL)
    {
      queue = dispatch_queue_create("org.nextbsd.dockextra.wifi", NULL);
    }
  return queue;
}

static void
DockWiFiChanged(SCDynamicStoreRef store, CFArrayRef keys, void *info)
{
  char byte = 1;

  (void)store;
  (void)keys;
  (void)write((int)(intptr_t)info, &byte, 1);
}

void *
DockWiFiOpen(int wakeFD)
{
  SCDynamicStoreContext context = { 0, (void *)(intptr_t)wakeFD,
				    NULL, NULL, NULL };
  SCDynamicStoreRef store;
  CFStringRef pattern;
  CFArrayRef patterns;

  store = SCDynamicStoreCreate(NULL, CFSTR("DockWM Wi-Fi extra"),
			       DockWiFiChanged, &context);
  if (store == NULL)
    {
      return NULL;
    }
  pattern = CFSTR(AirPortPattern);
  patterns = CFArrayCreate(NULL, (const void **)&pattern, 1,
			   &kCFTypeArrayCallBacks);
  if (!SCDynamicStoreSetNotificationKeys(store, NULL, patterns) ||
      !SCDynamicStoreSetDispatchQueue(store, DockWiFiQueue()))
    {
      /* Still readable; just not watched. */
    }
  CFRelease(patterns);
  return (void *)store;
}

static void
CopyString(CFDictionaryRef d, CFStringRef key, char *out, size_t size)
{
  CFTypeRef v = CFDictionaryGetValue(d, key);

  out[0] = '\0';
  if (v && CFGetTypeID(v) == CFStringGetTypeID())
    {
      CFStringGetCString((CFStringRef)v, out, (CFIndex)size,
			 kCFStringEncodingUTF8);
    }
}

static int
CopyInt(CFDictionaryRef d, CFStringRef key)
{
  CFTypeRef v = CFDictionaryGetValue(d, key);
  int result = 0;

  if (v && CFGetTypeID(v) == CFNumberGetTypeID())
    {
      CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &result);
    }
  else if (v && CFGetTypeID(v) == CFBooleanGetTypeID())
    {
      result = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    }
  return result;
}

int
DockWiFiRead(void *handle, DockWiFiState *states, int max)
{
  SCDynamicStoreRef store = (SCDynamicStoreRef)handle;
  CFArrayRef keys;
  CFIndex i, count;
  int n = 0;

  if (store == NULL)
    {
      return 0;
    }
  keys = SCDynamicStoreCopyKeyList(store, CFSTR(AirPortPattern));
  if (keys == NULL)
    {
      return 0;
    }
  count = CFArrayGetCount(keys);
  for (i = 0; i < count && n < max; i++)
    {
      CFStringRef key = CFArrayGetValueAtIndex(keys, i);
      CFPropertyListRef value = SCDynamicStoreCopyValue(store, key);
      DockWiFiState *s = &states[n];
      char path[256];
      char *name, *end;

      if (value == NULL)
	{
	  continue;
	}
      if (CFGetTypeID(value) != CFDictionaryGetTypeID() ||
	  !CFStringGetCString(key, path, sizeof(path), kCFStringEncodingUTF8))
	{
	  CFRelease(value);
	  continue;
	}
      memset(s, 0, sizeof(*s));
      /* State:/Network/Interface/<if>/AirPort */
      name = path + strlen("State:/Network/Interface/");
      end = strchr(name, '/');
      if (end)
	{
	  *end = '\0';
	}
      strlcpy(s->interface, name, sizeof(s->interface));
      s->authenticated = CopyInt(value, CFSTR("Authenticated"));
      CopyString(value, CFSTR("SSID"), s->ssid, sizeof(s->ssid));
      CopyString(value, CFSTR("BSSID"), s->bssid, sizeof(s->bssid));
      s->rssi = CopyInt(value, CFSTR("RSSI"));
      s->channel = CopyInt(value, CFSTR("Channel"));
      CopyString(value, CFSTR("Security"), s->security, sizeof(s->security));
      CFRelease(value);
      n++;
    }
  CFRelease(keys);
  return n;
}

void
DockWiFiClose(void *handle)
{
  SCDynamicStoreRef store = (SCDynamicStoreRef)handle;

  if (store == NULL)
    {
      return;
    }
  SCDynamicStoreSetDispatchQueue(store, NULL);
  /* Wait out a callback already running before the pipe is closed. */
  dispatch_sync(DockWiFiQueue(), ^{});
  CFRelease(store);
}
