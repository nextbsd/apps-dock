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

@implementation AppController

- (void) applicationDidFinishLaunching: (NSNotification *)notification
{
  NSRect frame;

  _items = [NSMutableArray new];
  _recyclerController = [RecyclerController new];
  _preferences = [[DockPreferences alloc] init];
  [_preferences applyIconManagerPreference];
  _applicationScanner = [RunningApplicationScanner new];
  _applicationStore = [[DockApplicationStore alloc]
			initWithScanner:_applicationScanner];
  _applicationIconManager = [[ApplicationIconManager alloc]
			      initWithScanner:_applicationScanner];
  _launchedApplicationPaths = [NSMutableSet new];
  /* On WindowServer the Dock fills the screen edge it's on: left,
   * right (the default), top or bottom, from NBDockPosition. */
  _dockPlacement = [WSDockManager isWindowServerSession]
    ? [_preferences savedWindowServerDockPlacement]
    : [self savedDockPlacement];
  _dockCellSizeMode = [self savedDockCellSizeMode];
  _runningIndicatorMode = [self savedRunningIndicatorMode];
  _backgroundColor = RETAIN([self savedBackgroundColor]);
  _windowAlpha = [self savedWindowAlpha];
  _useCellTileBackground = [self savedUseCellTileBackground];
  _showDockBorder = [self savedShowDockBorder];
  _magnifiesHoveredIcons = [_preferences savedMagnifiesHoveredIcons];
  _hoverIconScale = [_preferences savedHoverIconScale];
  _dockScale = [_preferences savedDockScale];
  _wigglesOnLaunch = [_preferences savedWigglesOnLaunch];
  _wigglesOnActivation = [_preferences savedWigglesOnActivation];
  _wigglesOnAttentionRequest = [_preferences savedWigglesOnAttentionRequest];
  _playsSoundOnRemove = [_preferences savedPlaysSoundOnRemove];
  _singleClickLaunchesApplications = [self savedSingleClickLaunchesApplications];
  _hidesMiniwindows = [_preferences savedHidesMiniwindows];
  [self loadPersistedApplications];
  frame = [self dockWindowFrameForPlacement:_dockPlacement];

  _window = [[DockWindow alloc] initWithContentRect:frame
                                        styleMask:NSBorderlessWindowMask
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  [_window setLevel:NSDockWindowLevel];
  [_window setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorStationary)];
  [_window setOpaque:NO];
  [_window setAlphaValue:1.0];
  [_window setBackgroundColor:[NSColor clearColor]];
  [_window setTitle:@"AppsDockWM"];
  [_window setAcceptsMouseMovedEvents:YES];

  _dockView = [[DockView alloc] initWithFrame:NSMakeRect(0, 0,
                                                         NSWidth(frame),
                                                         NSHeight(frame))];
  [_dockView setDelegate:self];
  [_dockView setFillsColumn:[WSDockManager isWindowServerSession]];
  [_dockView setHorizontal:[DockPreferences placementIsHorizontal:_dockPlacement]];
  [self applyDockCellSizeToView];
  [_dockView setBackgroundColor:_backgroundColor];
  [_dockView setBackgroundAlpha:_windowAlpha];
  [_dockView setShowsBorder:_showDockBorder];
  [_dockView setRunningIndicatorMode:_runningIndicatorMode];
  [_dockView setMagnifiesHoveredIcons:_magnifiesHoveredIcons];
  [_dockView setHoverIconScale:_hoverIconScale];
  [_dockView setTooltipDelay:[_preferences savedTooltipDelay]];
  [_dockView setSingleClickLaunchesApplications:_singleClickLaunchesApplications];
  [_dockView setItems:_items];
  [_dockView setTopTileIcon:[self workspaceIcon]];
  [_dockView setPinnedItemCount:[self pinnedApplicationCount]];
  [_dockView setMenu:[self dockMenu]];
  [_window setContentView:_dockView];

  [self updateDockBackground];
  [_window makeKeyAndOrderFront:nil];
  [_window orderFrontRegardless];
  [_window display];

  if ([WSDockManager isWindowServerSession])
    {
      /* NextBSD's WindowServer: window lists, minimized windows and
       * GSIconManager come from WindowServer's Dock connection. */
      WSDockManager *ws = [[WSDockManager alloc] initWithDockView:_dockView];

      _windowManager = ws;
      [ws setDelegate:self];
      [ws setHidesMiniwindows:_hidesMiniwindows];
      [ws start];
      [self reportDockEdge];
      [self loadDockExtras];
    }
  else
    {
      X11DockManager *x11 = [[X11DockManager alloc] initWithDockView:_dockView];

      _windowManager = x11;
      [x11 setDelegate:self];
      [x11 setHidesMiniwindows:_hidesMiniwindows];
      if ([x11 start])
	{
	  /* GNUstep window numbers are backend tags, not native X11 IDs. */
	  [x11 makeWindowSticky:(unsigned long)[_window windowRef]];
	  [x11 setDockPlacement:_dockPlacement];
	}
    }

  /* Workspace Preferences -> Desktop moves the Dock (NBDockPosition). */
  [[NSDistributedNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(desktopSettingsDidChange:)
	   name:DockDesktopSettingsChangedNotification
	 object:nil];

  /* The screen changed size (another "looks like" size in Displays,
   * a new display mode): fill the new screen edge again. */
  [[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(screenParametersDidChange:)
	   name:NSApplicationDidChangeScreenParametersNotification
	 object:nil];

  /* Other apps keep apps in the Dock by asking it (Workspace's File >
   * Add to Dock); the Dock owns its list. */
  [[NSDistributedNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(keepApplicationsRequested:)
	   name:DockKeepApplicationsNotification
	 object:nil];

  [self performSelector:@selector(performInitialApplicationScans)
	     withObject:nil
	     afterDelay:0.5];
}

- (void) dealloc
{
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_x11EventTimer invalidate];
  [_scanTimer invalidate];
  [_processScanTimer invalidate];
  [_applicationExitTimer invalidate];
  DESTROY(_settingsController);
  DESTROY(_recyclerController);
  DESTROY(_preferences);
  DESTROY(_dockMenu);
  DESTROY(_windowManager);
  DESTROY(_extrasController);
  DESTROY(_dockView);
  DESTROY(_window);
  DESTROY(_applicationStore);
  DESTROY(_applicationIconManager);
  DESTROY(_applicationScanner);
  DESTROY(_launchedApplicationPaths);
  DESTROY(_backgroundColor);
  DESTROY(_items);
  DEALLOC;
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication *)sender
{
  return NO;
}

- (void) applicationWillTerminate: (NSNotification *)notification
{
  [_extrasController unloadExtras];
  [self savePersistedApplications];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
