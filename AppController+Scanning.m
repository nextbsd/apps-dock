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

#import "AppControllerPrivate.h"
#if defined(__FreeBSD__)
#import <sys/types.h>
#import <sys/event.h>
#import <fcntl.h>
#endif

static NSArray *
exitWatchModes(void)
{
  return [NSArray arrayWithObjects:NSDefaultRunLoopMode,
		  NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil];
}

@implementation AppController (Scanning)

- (void) performInitialApplicationScans
{
  [self scanRunningApplications];
  /* X11 is polled for events and rescanned for dockapps; WindowServer
   * tells the Dock when its window list changes (WSDockManager). */
  if ([_windowManager isKindOfClass:[X11DockManager class]])
    {
      [_windowManager scanForDockApps];
      if (!_x11EventTimer)
	{
	  _x11EventTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
							    target:_windowManager
							  selector:@selector(processPendingEvents)
							  userInfo:nil
							   repeats:YES];
          /* Alerts run a separate loop. Keep native stacking repairs alive
           * while the modal panel is open, as well as during menu tracking. */
          [[NSRunLoop currentRunLoop] addTimer:_x11EventTimer
                                      forMode:NSModalPanelRunLoopMode];
          [[NSRunLoop currentRunLoop] addTimer:_x11EventTimer
                                      forMode:NSEventTrackingRunLoopMode];
	}
      if (!_scanTimer)
	{
	  _scanTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
							target:_windowManager
						      selector:@selector(scanForDockApps)
						      userInfo:nil
						       repeats:YES];
	}
    }
  if (!_processScanTimer)
    {
      _processScanTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
							   target:self
							 selector:@selector(scanRunningApplications)
							 userInfo:nil
							  repeats:YES];
    }
  if (!_applicationExitTimer && ![self startWatchingApplicationExits])
    {
      _applicationExitTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                               target:self
                               selector:@selector(scanForExitedApplications)
                               userInfo:nil repeats:YES];
    }
  [self launchOpenAtLoginApplications];
}

/* On WindowServer the kernel reports when a running app's process exits,
 * so nothing polls while the desktop is idle. X11 window items still need
 * the exit timer, as does a system without kqueue. */
- (BOOL) startWatchingApplicationExits
{
#if defined(__FreeBSD__)
  NSArray *modes = exitWatchModes();
  NSUInteger i;

  _exitQueue = -1;
  if (![_windowManager isKindOfClass:[WSDockManager class]])
    {
      return NO;
    }
  _exitQueue = kqueue();
  if (_exitQueue < 0)
    {
      return NO;
    }
  fcntl(_exitQueue, F_SETFD, FD_CLOEXEC);
  for (i = 0; i < [modes count]; i++)
    {
      [[NSRunLoop currentRunLoop] addEvent:(void *)(intptr_t)_exitQueue
				      type:ET_RDESC
				   watcher:(id<RunLoopEvents>)self
				   forMode:[modes objectAtIndex:i]];
    }
  [self watchRunningApplicationExits];
  return YES;
#else
  _exitQueue = -1;
  return NO;
#endif
}

- (void) stopWatchingApplicationExits
{
  NSArray *modes = exitWatchModes();
  NSUInteger i;

  if (_exitQueue < 0)
    {
      return;
    }
  for (i = 0; i < [modes count]; i++)
    {
      [[NSRunLoop currentRunLoop] removeEvent:(void *)(intptr_t)_exitQueue
					 type:ET_RDESC
				      forMode:[modes objectAtIndex:i]
					  all:YES];
    }
  close(_exitQueue);
  _exitQueue = -1;
}

/* Ask for an exit event from each process of a running app and of
 * Workspace. Watching a process already watched changes nothing; a process
 * gone before it is watched is caught by the next exit scan. */
- (void) watchRunningApplicationExits
{
#if defined(__FreeBSD__)
  NSDictionary *running;
  NSMutableArray *items;
  NSString *workspacePath;
  NSEnumerator *e;
  NSNumber *pid;
  BOOL missed = NO;
  NSUInteger i;

  if (_exitQueue < 0)
    {
      return;
    }

  items = [NSMutableArray array];
  for (i = 0; i < [_items count]; i++)
    {
      DockItem *item = [_items objectAtIndex:i];

      if ([item kind] == DockItemApplication &&
	  [item state] != DockItemNotRunning)
	{
	  [items addObject:item];
	}
    }
  workspacePath = [self workspaceApplicationPath];
  if ([workspacePath length])
    {
      [items addObject:[DockItem applicationItemWithPath:workspacePath]];
    }

  running = [_applicationScanner runningProcessPathsByIdentifier];
  e = [running keyEnumerator];
  while ((pid = [e nextObject]) != nil)
    {
      NSString *path = [running objectForKey:pid];
      struct kevent change;

      for (i = 0; i < [items count]; i++)
	{
	  if ([_applicationScanner applicationItem:[items objectAtIndex:i]
				 matchesRunningProcessPath:path])
	    {
	      break;
	    }
	}
      if (i == [items count])
	{
	  continue;
	}
      EV_SET(&change, [pid intValue], EVFILT_PROC, EV_ADD | EV_ONESHOT,
	     NOTE_EXIT, 0, NULL);
      if (kevent(_exitQueue, &change, 1, NULL, 0, NULL) != 0)
	{
	  missed = YES;
	}
    }
  if (missed)
    {
      [self performSelector:@selector(scanForExitedApplications)
		 withObject:nil
		 afterDelay:0.0];
    }
#endif
}

- (void) receivedEvent: (void *)data
		  type: (RunLoopEventType)type
		 extra: (void *)extra
	       forMode: (NSString *)mode
{
#if defined(__FreeBSD__)
  struct kevent events[16];
  struct timespec now = { 0, 0 };

  if (_exitQueue < 0 || (intptr_t)data != _exitQueue)
    {
      return;
    }
  while (kevent(_exitQueue, NULL, 0, events, 16, &now) > 0)
    {
      continue;
    }
  [self scanForExitedApplications];
#endif
}

/* Check exits independently of discovery, missing-file checks and recycler
 * maintenance. Window closure alone does not mean the application has quit. */
- (void) scanForExitedApplications
{
  NSArray *processPaths = nil;
  BOOL changed = NO;
  NSUInteger i;

  for (i = [_items count]; i > 0; i--)
    {
      DockItem *item = [_items objectAtIndex:i - 1];

      if ([item kind] == DockItemApplication &&
          [item state] != DockItemNotRunning)
        {
          if (!processPaths)
            {
              processPaths = [self runningProcessExecutablePaths];
            }
          if ([self applicationItemHasRunningProcess:item paths:processPaths] ||
              ([item xWindow] && [_windowManager windowExists:[item xWindow]]))
            {
              continue;
            }
          [self restoreApplicationItemAfterExit:item];
          if (![item isPinned])
            {
              [_items removeObjectAtIndex:i - 1];
            }
          changed = YES;
        }
      else if ([item kind] == DockItemX11Window && [item xWindow] &&
               ![_windowManager windowExists:[item xWindow]])
        {
          [item setXWindow:0];
          [item setState:DockItemNotRunning];
          if (![item isPinned])
            {
              [_items removeObjectAtIndex:i - 1];
            }
          changed = YES;
        }
    }

  if (!processPaths)
    {
      processPaths = [self runningProcessExecutablePaths];
    }
  [self updateTopTileWithProcessPaths:processPaths];

  if (changed)
    {
      [self pruneApplicationIconUpdatesForExitedProcesses];
      [self refreshDock];
    }
  [self watchRunningApplicationExits];
}

/* The top tile is Workspace's: it shows the running indicator whenever
 * Workspace runs, with or without windows. */
- (void) updateTopTileWithProcessPaths: (NSArray *)processPaths
{
  NSString *path = [self workspaceApplicationPath];
  BOOL running = [path length] &&
    [self applicationItemHasRunningProcess:[DockItem applicationItemWithPath:path]
				     paths:processPaths];

  [_dockView setTopTileRunning:running];
}

- (void) scanRunningApplications
{
  NSArray *processPaths = [self runningProcessExecutablePaths];
  BOOL changed = NO;
  NSUInteger i;

  [self pruneApplicationIconUpdatesForExitedProcesses];
  [self updateTopTileWithProcessPaths:processPaths];

  for (i = 0; i < [_items count]; i++)
    {
      DockItem *item = [_items objectAtIndex:i];
      BOOL running;
      DockItemState newState;

      if ([item kind] != DockItemApplication)
	{
	  continue;
	}

      if ([item refreshMissingState])
        {
          changed = YES;
        }

      running = [self applicationItemHasRunningProcess:item paths:processPaths];
      if (!running && [item xWindow])
	{
	  if ([_windowManager windowExists:[item xWindow]])
	    {
	      continue;
	    }
	}

      newState = running ? DockItemRunning : DockItemNotRunning;
      if (!running)
	{
	  if ([item state] != DockItemNotRunning ||
	      [item xWindow] ||
	      [[item badgeLabel] length])
	    {
	      [self restoreApplicationItemAfterExit:item];
	      changed = YES;
	    }
	}
      else if ([item state] != newState)
	{
	  [item setState:newState];
	  changed = YES;
	}
    }

  for (i = 0; i < [processPaths count]; i++)
    {
      NSString *processPath = [processPaths objectAtIndex:i];
      NSString *bundlePath = [DockItem applicationBundlePathForPath:processPath];
      DockItem *item;

      /* Every running app shows, kept or not: Keep in Dock only
       * decides whether its tile stays after it quits. */
      if (![bundlePath length] ||
	  [self applicationBundlePathIsBuiltIn:bundlePath] ||
	  [self dockHasApplicationPath:bundlePath] ||
	  [self transientApplicationItemMatchingBundlePath:bundlePath])
	{
	  continue;
	}

      [self forgetLegacyKeepInDockForApplicationPath:bundlePath];
      item = [DockItem applicationItemWithPath:bundlePath];
      [item setPinned:NO];
      [item setState:DockItemRunning];
      [self applyStoredApplicationIconUpdateForItem:item];
      [_items addObject:item];
      changed = YES;
    }

  for (i = [_items count]; i > 0; i--)
    {
      DockItem *item = [_items objectAtIndex:i - 1];

      if ([item kind] == DockItemApplication && [item isPinned] &&
          [item isMissing] && ![_preferences savedKeepsMissingApplications])
        {
          [_items removeObjectAtIndex:i - 1];
          changed = YES;
        }
      else if ([item kind] == DockItemApplication &&
	  ![item isPinned] &&
	  ![self applicationItemHasRunningProcess:item paths:processPaths])
	{
	  [_items removeObjectAtIndex:i - 1];
	  changed = YES;
	}
      else if ([item kind] == DockItemX11Window &&
	       ![item isPinned] &&
	       [item xWindow] &&
	       ![_windowManager windowExists:[item xWindow]])
	{
	  [_items removeObjectAtIndex:i - 1];
	  changed = YES;
	}
    }

  if (changed)
    {
      [self refreshDock];
    }

  [self updateRecyclerState];
  [self watchRunningApplicationExits];
}

@end
