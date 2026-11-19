/*
 * Dock
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

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "AppController.h"

/*
 * The Dock was DockWM.app, and its settings are in the DockWM defaults
 * domain; the Dock's own domain is its process name now. The first time
 * it runs as Dock, the old domain's values that the new one hasn't got
 * move over, and DockMigratedFromDockWM marks that it was done. The old
 * domain stays as it was.
 */
static void
migrateDockWMDefaults(void)
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *name = [[NSProcessInfo processInfo] processName];
  NSDictionary *old = [defaults persistentDomainForName:@"DockWM"];
  NSMutableDictionary *domain;
  NSEnumerator *e;
  NSString *key;

  if ([name isEqualToString:@"DockWM"])
    {
      return;
    }
  domain = [[[defaults persistentDomainForName:name] mutableCopy]
	     autorelease];
  if (domain == nil)
    {
      domain = [NSMutableDictionary dictionary];
    }
  if ([[domain objectForKey:@"DockMigratedFromDockWM"] boolValue])
    {
      return;
    }
  e = [old keyEnumerator];
  while ((key = [e nextObject]) != nil)
    {
      if ([domain objectForKey:key] == nil)
	{
	  [domain setObject:[old objectForKey:key] forKey:key];
	}
    }
  [domain setObject:@"YES" forKey:@"DockMigratedFromDockWM"];
  [defaults setPersistentDomain:domain forName:name];
  [defaults synchronize];
  if ([old count])
    {
      NSLog(@"Dock: took the settings from the DockWM defaults domain.");
    }
}

int
main(int argc, const char **argv)
{
  AppController *delegate;
  NSApplication *app;

  ENTER_POOL
    migrateDockWMDefaults();
    /* Set this before NSApplication can create the Dock's own icon window. */
    [[NSUserDefaults standardUserDefaults] setBool: YES
					    forKey: @"GSSuppressAppIcon"];
  app = [NSApplication sharedApplication];
  delegate = [AppController new];

  [app setDelegate:delegate];
  [app run];

  DESTROY(delegate);
  LEAVE_POOL
    return 0;
}
