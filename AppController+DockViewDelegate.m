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

#import "AppControllerPrivate.h"

@implementation AppController (DockViewDelegate)

- (void) applyDockPlacement
{
  NSUInteger i;

  /* WindowServer sessions fill one of the four screen edges, and only
   * the Settings window saves a new one there (the X11 placements a
   * WindowServer edge stands for are left as they are). */
  if ([WSDockManager isWindowServerSession])
    {
      _dockPlacement = [DockPreferences placementForEdge:
			  [DockPreferences edgeForPlacement:_dockPlacement]];
    }
  else
    {
      [_preferences saveDockPlacement:_dockPlacement];
    }
  [self applyDockCellSizeToView];
  [_dockView setHorizontal:[DockPreferences placementIsHorizontal:_dockPlacement]];
  [_window setFrame:[self dockWindowFrameForPlacement:_dockPlacement]
            display:YES];
  [_dockView setFrame:NSMakeRect(0, 0,
                                 NSWidth([_window frame]),
                                 NSHeight([_window frame]))];
  [_windowManager setDockPlacement:_dockPlacement];
  [self reportDockEdge];
  for (i = 0; i < [_items count]; i++)
    {
      DockItem *item = [_items objectAtIndex:i];

      if ([item xWindow])
	{
	  [_windowManager dockWindow:[item xWindow] atIndex:i];
	}
    }
  [self updateDockBackground];
  [self updateDockMenu];
}

/*
 * Tell WindowServer which edge the Dock keeps and how thick it is, so
 * that tiling keeps that strip free. X11 has no such request.
 */
- (void) reportDockEdge
{
  NSRect frame = [_window frame];
  DockEdge edge = [DockPreferences edgeForPlacement:_dockPlacement];

  if ([_windowManager respondsToSelector:@selector(setDockEdge:thickness:)])
    {
      [(WSDockManager *)_windowManager setDockEdge:edge
					 thickness:(edge == DockEdgeLeft
						    || edge == DockEdgeRight)
					  ? NSWidth(frame) : NSHeight(frame)];
    }
}

- (void) updateDockBackground
{
  [_dockView setBackgroundColor:_backgroundColor];
  [_dockView setBackgroundAlpha:_windowAlpha];
  [_dockView setUsesCellBackgroundTile:_useCellTileBackground];
  [_dockView setShowsBorder:_showDockBorder];
  [_dockView setRunningIndicatorMode:_runningIndicatorMode];
  [_dockView setMagnifiesHoveredIcons:_magnifiesHoveredIcons];
  [_dockView setHoverIconScale:_hoverIconScale];
}

- (void) startLaunchWiggleForItem: (DockItem *)item
{
  if ([self itemWigglesOnLaunch:item])
    {
      [_dockView startWiggleForItem:item];
    }
}

- (void) startActivationWiggleForItem: (DockItem *)item
{
  if ([self itemWigglesOnActivation:item])
    {
      [_dockView startWiggleForItem:item];
    }
}

- (void) startAttentionWiggleForItem: (DockItem *)item
{
  if ([self itemWigglesOnAttentionRequest:item])
    {
      [_dockView startAttentionWiggleForItem:item];
    }
}

- (void) cancelAttentionWiggleForItem: (DockItem *)item
{
  [_dockView acknowledgeWiggleForItem:item];
}

- (BOOL) itemWigglesOnLaunch: (DockItem *)item
{
  return [item usesDockBehaviorDefaults] ? _wigglesOnLaunch : [item wigglesOnLaunch];
}

- (BOOL) itemWigglesOnActivation: (DockItem *)item
{
  return [item usesDockBehaviorDefaults] ?
    _wigglesOnActivation : [item wigglesOnActivation];
}

- (BOOL) itemWigglesOnAttentionRequest: (DockItem *)item
{
  return [item usesDockBehaviorDefaults] ?
    _wigglesOnAttentionRequest : [item wigglesOnAttentionRequest];
}

- (void) quitDock: (id)sender
{
  [self savePersistedApplications];
  [[NSUserDefaults standardUserDefaults] synchronize];
  [NSApp terminate:sender];
}

- (void) refreshDock
{
  [self sortItemsIntoSections];
  [_dockView setItems:_items];
  [_dockView setPinnedItemCount:[self pinnedApplicationCount]];
  [self applyDockPlacement];
}

- (void) dockViewDidReceivePaths: (NSArray *)paths
{
  [self dockViewDidReceivePaths:paths atIndex:[_items count]];
}

- (void) dockViewDidReceivePaths: (NSArray *)paths
			 atIndex: (NSUInteger)index
{
  NSUInteger i;
  BOOL added = NO;
  NSUInteger pinnedCount = [self pinnedApplicationCount];
  NSUInteger insertionIndex = MIN(index, pinnedCount);

  for (i = 0; i < [paths count]; i++)
    {
      NSString *path = [paths objectAtIndex:i];
      NSString *bundlePath = [DockItem applicationBundlePathForPath:path];
      NSString *applicationPath = [bundlePath length] ? bundlePath : path;
      DockItem *transientItem;
      NSUInteger transientIndex;
      BOOL isDir = NO;

      if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] &&
	  ![self applicationBundlePathIsBuiltIn:applicationPath] &&
	  ![self dockHasApplicationPath:applicationPath])
	{
	  DockItem *item = [DockItem applicationItemWithPath:applicationPath];

	  transientItem = [self transientApplicationItemMatchingBundlePath:applicationPath];
	  transientIndex = transientItem ? [self indexForItem:transientItem] : NSNotFound;
	  if (transientIndex != NSNotFound)
	    {
	      [_items removeObjectAtIndex:transientIndex];
	      if (transientIndex < insertionIndex && insertionIndex > 0)
		{
		  insertionIndex--;
		}
	    }

	  [self setApplicationPath:applicationPath keptInDock:YES];
	  [item setPinned:YES];
	  [_items insertObject:item atIndex:insertionIndex];
	  insertionIndex++;
	  added = YES;
	}
    }

  if (added)
    {
      [self savePersistedApplications];
      [self refreshDock];
    }
}

- (void) dockViewDidMoveItemFromIndex: (NSUInteger)fromIndex
                              toIndex: (NSUInteger)toIndex
{
  DockItem *item;
  NSUInteger pinnedCount = [self pinnedApplicationCount];
  BOOL promoteItem = NO;

  if (fromIndex >= [_items count] || toIndex > [_items count])
    {
      return;
    }

  if (fromIndex < pinnedCount && toIndex > pinnedCount)
    {
      toIndex = pinnedCount;
    }
  else if (fromIndex >= pinnedCount && toIndex <= pinnedCount)
    {
      promoteItem = YES;
    }

  if (toIndex > fromIndex)
    {
      toIndex--;
    }

  if (fromIndex == toIndex && !promoteItem)
    {
      return;
    }

  item = RETAIN([_items objectAtIndex:fromIndex]);
  [_items removeObjectAtIndex:fromIndex];
  if (promoteItem)
    {
      [item setPinned:YES];
    }
  [_items insertObject:item atIndex:toIndex];
  DESTROY(item);

  [self savePersistedApplications];
  [self refreshDock];
}

- (void) dockViewDidRemoveItemAtIndex: (NSUInteger)index
{
  DockItem *item;

  if (index >= [_items count])
    {
      return;
    }

  item = [_items objectAtIndex:index];
  if (![self canRemoveDockItemAtIndex:index])
    {
      return;
    }

  if (([item kind] == DockItemApplication ||
       [item kind] == DockItemX11Window) &&
      [[item path] length])
    {
      [self setApplicationPath:[item path] openAtLogin:NO];
    }

  [_items removeObjectAtIndex:index];
  [self savePersistedApplications];
  [self refreshDock];
  [self playDockRemovalSoundIfEnabled];
}

- (BOOL) dockView: (id)dockView canRemoveItemAtIndex: (NSUInteger)index
{
  return [self canRemoveDockItemAtIndex:index];
}

- (BOOL) dockView: (id)dockView itemIsKeptInDock: (DockItem *)item
{
  [self resolvePathForX11WindowItem:item];
  return [self applicationPathIsKeptInDock:[item path]];
}

- (void) dockView: (id)dockView didToggleKeepInDockForItem: (DockItem *)item
{
  NSInteger i;
  BOOL keep;

  [self resolvePathForX11WindowItem:item];
  if (![[item path] length])
    {
      return;
    }
  keep = ![self applicationPathIsKeptInDock:[item path]];
  [self setApplicationPath:[item path] keptInDock:keep];
  for (i = [_items count] - 1; i >= 0; i--)
    {
      DockItem *candidate = [_items objectAtIndex:i];

      if (![self applicationPathIsKeptInDock:[candidate path]])
        {
          [_windowManager hideDockedWindow:[candidate xWindow]];
          [_items removeObjectAtIndex:i];
        }
    }
  [self savePersistedApplications];
  [self refreshDock];
}

- (BOOL) dockView: (id)dockView itemIsOpenAtLogin: (DockItem *)item
{
  [self resolvePathForX11WindowItem:item];
  if (![[item path] length])
    {
      return NO;
    }

  return [self applicationPathIsOpenAtLogin:[item path]];
}

- (void) dockView: (id)dockView didToggleOpenAtLoginForItem: (DockItem *)item
{
  BOOL openAtLogin;

  [self resolvePathForX11WindowItem:item];
  if (![[item path] length])
    {
      return;
    }

  openAtLogin = ![self applicationPathIsOpenAtLogin:[item path]];
  [self setApplicationPath:[item path] openAtLogin:openAtLogin];
}

- (void) dockView: (id)dockView didShowItemInFileViewer: (DockItem *)item
{
  NSString *path = [item path];
  NSString *directory;

  if (![path length])
    {
      return;
    }

  directory = [path stringByDeletingLastPathComponent];
  [[NSWorkspace sharedWorkspace] selectFile:path
                   inFileViewerRootedAtPath:directory];
}

- (BOOL) dockView: (id)dockView canRestoreItem: (DockItem *)item
{
  if ([item kind] == DockItemApplication)
    {
      return [item state] != DockItemNotRunning ||
        [[self runningProcessIdentifiersForApplicationItem:item] count] > 0;
    }
  return [item xWindow] && [_windowManager windowExists:[item xWindow]];
}


- (NSArray *) dockView: (id)dockView minimizedWindowsForItem: (DockItem *)item
{
  NSArray *processIds = nil;

  if ([item kind] == DockItemApplication)
    {
      processIds = [self runningProcessIdentifiersForApplicationItem:item];
    }
  return [_windowManager minimizedWindowsForProcessIdentifiers:processIds window:[item xWindow]];
}


- (void) dockView: (id)dockView restoreWindows: (NSArray *)windows
          forItem: (DockItem *)item
{
  NSArray *current;
  NSUInteger i;

  /* An empty selection means restore the application, without requiring a
   * miniwindow or a particular WM_STATE value to exist. */
  if (![windows count])
    {
      if ([item kind] == DockItemApplication)
        {
          NSArray *processIds = [self runningProcessIdentifiersForApplicationItem:item];
          BOOL activated = NO;
          NSString *bundle = [DockItem applicationBundlePathForPath:[item path]];

          /* GNUstep's NSRunningApplication is a stub. NSWorkspace contacts
           * the running application and asks it to activate/unhide itself. */
          if ([bundle length])
            activated = [[NSWorkspace sharedWorkspace] launchApplication:bundle];
          if ([_windowManager activateApplicationWithProcessIdentifiers:processIds])
            activated = YES;
          if (!activated && [self dockView:dockView canRestoreItem:item])
            [self launchApplicationItem:item useIconManager:YES];
        }
      else if ([item xWindow])
        {
          [_windowManager activateWindow:[item xWindow]];
        }
      [_windowManager drainTransientIconEvents];
      [self refreshDock];
      return;
    }
  current = [self dockView:dockView minimizedWindowsForItem:item];

  for (i = 0; i < [current count]; i++)
    {
      NSNumber *window = [[current objectAtIndex:i] objectForKey:@"window"];
      if ([windows containsObject:window])
        {
          [_windowManager restoreWindow:[window unsignedLongValue]];
        }
    }
  [_windowManager drainTransientIconEvents];
  [self refreshDock];
}


- (void) dockView: (id)dockView didQuitItem: (DockItem *)item
{
  NSUInteger index;

  if ([item kind] == DockItemApplication)
    {
      [self terminateApplicationItemProcesses:item];
      [self restoreApplicationItemAfterExit:item];
    }
  else if ([item xWindow])
    {
      [_windowManager closeWindow:[item xWindow]];
      [item setState:DockItemNotRunning];
    }
  if (![item isPinned])
    {
      index = [self indexForItem:item];
      if (index != NSNotFound)
	{
	  [_items removeObjectAtIndex:index];
	}
    }

  [self refreshDock];
}

- (void) dockViewDidEmptyRecycler: (id)dockView
{
  [self emptyRecycler:dockView];
}

- (void) dockViewDidActivateRecycler
{
  NSString *path = [self recyclerPathForDropping];

  if ([path length])
    {
      [[NSWorkspace sharedWorkspace] openFile:path];
    }
  else
    {
      NSBeep();
    }
}

- (BOOL) dockView: (id)dockView canShowSettingsForItem: (DockItem *)item
{
  return ([item kind] == DockItemApplication ||
	  [item kind] == DockItemX11Window) &&
    ![self applicationBundlePathIsDockWM:[item path]];
}

- (void) dockView: (id)dockView didShowSettingsForItem: (DockItem *)item
{
  if ([self dockView:dockView canShowSettingsForItem:item])
    {
      [self showSettingsForDockItem:item];
    }
}

- (void) dockViewDidActivateItem: (DockItem *)item
{
  NSArray *minimized = [self dockView:_dockView minimizedWindowsForItem:item];

  if ([minimized count] || [self dockView:_dockView canRestoreItem:item])
    {
      NSMutableArray *windows = [NSMutableArray array];
      NSUInteger i;

      /* On WindowServer, activating an app restores its minimized
       * windows only when it has nothing else on screen; otherwise it
       * just comes forward with the windows it shows. */
      if ([self usesWindowServer] && [item kind] == DockItemApplication &&
	  [_windowManager processIdentifiersHaveVisibleWindows:
	     [self runningProcessIdentifiersForApplicationItem:item]])
	{
	  minimized = nil;
	}
      for (i = 0; i < [minimized count]; i++)
        [windows addObject:[[minimized objectAtIndex:i] objectForKey:@"window"]];
      /* Match Restore (or Restore All) including its application fallback. */
      [self dockView:_dockView restoreWindows:windows forItem:item];
      [self startActivationWiggleForItem:item];
      return;
    }

  if ([item kind] == DockItemApplication)
    {
      [self rememberLaunchedApplicationPath:[item path]];
      if ([self launchApplicationItem:item useIconManager:YES])
        {
          [item setState:DockItemRunning];
          [self startLaunchWiggleForItem:item];
          [self refreshDock];
        }
      [_windowManager drainTransientIconEvents];
    }
}


/* The top tile is Workspace, as on NeXTSTEP: activate it, or start it. */
- (void) dockViewDidActivateTopIcon
{
  NSString *path = [self workspaceApplicationPath];
  DockItem *item;
  NSString *executablePath;
  BOOL launched = NO;

  if (![path length])
    {
      return;
    }
  item = [DockItem applicationItemWithPath:path];
  /* NSWorkspace asks the running app to activate itself. */
  if ([[self runningProcessIdentifiersForApplicationItem:item] count] > 0 &&
      [[NSWorkspace sharedWorkspace] launchApplication:path])
    {
      return;
    }

  executablePath = [self executablePathForApplicationPath:path];
  [self rememberLaunchedApplicationPath:path];
  [self prepareDefaultsForApplicationPath:path];
  if ([[NSFileManager defaultManager] isExecutableFileAtPath:executablePath])
    {
      [self launchTaskWithLaunchPath:executablePath
			   arguments:[NSArray array]
		      useIconManager:YES];
      launched = YES;
    }
  else
    {
      launched = [[NSWorkspace sharedWorkspace] launchApplication:path];
    }
  if (!launched)
    {
      [[NSWorkspace sharedWorkspace] openFile:path];
    }
  [_windowManager drainTransientIconEvents];
}

@end
