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

#import "AppController.h"
#import "ApplicationIconManager.h"
#import "DockApplicationStore.h"
#import "DockItem.h"
#import "DockPreferences.h"
#import "RecyclerController.h"
#import "RunningApplicationScanner.h"
#import <GNUstepBase/GNUstep.h>
#import <signal.h>
#import <unistd.h>

/* The request other apps send to keep apps in the Dock (Workspace's
 * File > Add to Dock): a distributed notification whose userInfo's
 * "paths" lists application bundle paths, kept in that order at the end
 * of the kept apps, as if dropped there. See the README. */
#define DockKeepApplicationsNotification @"org.nextbsd.Dock.KeepApplications"
#define DockKeepApplicationsPathsKey @"paths"

@interface AppController (SettingsDelegate) <SettingsControllerDelegate>
@end

@interface AppController (X11Delegate) <X11DockManagerDelegate>
@end

@interface AppController (Extras) <DockExtrasControllerDelegate>
- (void) loadDockExtras;
- (NSUInteger) dockExtraCount;
- (BOOL) dockExtrasGoInMenuBar;
- (void) updateDockExtrasPlace;
- (NSArray *) dockExtrasDescriptions;
- (void) setDockExtraHidden: (BOOL)hidden forIdentifier: (NSString *)identifier;
@end

@interface AppController (WindowServer) <WSDockManagerDelegate>
- (BOOL) usesWindowServer;
- (void) sortItemsIntoSections;
- (NSArray *) dockView: (id)dockView windowsForItem: (DockItem *)item;
- (void) dockView: (id)dockView activateWindow: (NSNumber *)window
	  forItem: (DockItem *)item;
@end

@interface AppController (Restore)

- (BOOL) dockView: (id)dockView canRestoreItem: (DockItem *)item;
- (NSArray *) dockView: (id)dockView minimizedWindowsForItem: (DockItem *)item;
- (void) dockView: (id)dockView restoreWindows: (NSArray *)windows
          forItem: (DockItem *)item;

@end

@interface AppController (Private)
- (DockPlacement) savedDockPlacement;
- (void) desktopSettingsDidChange: (NSNotification *)notification;
- (void) dockSettingsDidChange: (NSNotification *)notification;
- (void) updateDockStyle;
- (void) applyDockStyle: (NSString *)style;
- (void) keepApplicationsRequested: (NSNotification *)notification;
- (NSColor *) savedBackgroundColor;
- (void) saveBackgroundColor;
- (CGFloat) savedWindowAlpha;
- (void) saveWindowAlpha;
- (BOOL) savedShowDockBorder;
- (void) saveShowDockBorder;
- (NSInteger) savedDockCellSizeMode;
- (void) saveDockCellSizeMode;
- (DockRunningIndicatorMode) savedRunningIndicatorMode;
- (void) saveRunningIndicatorMode;
- (BOOL) savedUseCellTileBackground;
- (void) saveUseCellTileBackground;
- (BOOL) savedSingleClickLaunchesApplications;
- (CGFloat) activeDockPad;
- (CGFloat) activeDockGap;
- (CGFloat) activeDockWindowWidth;
- (NSUInteger) dockSectionGapCount;
/* On WindowServer, centred (DockAlignmentCenter) in the Mac menu
 * style: the Dock's window is as long as what's in it. */
- (BOOL) dockSizesToContent;
- (BOOL) dockIsMacMenuStyle;
/* NO in the Mac menu style on WindowServer: the Dock is never at the
 * top, above or below the menu bar, as on macOS. */
- (BOOL) dockCanBeAtTop;
/* Where the Dock goes for a placement: a top one goes to the bottom
 * while the Dock can't be at the top. The saved one is left as it is. */
- (DockPlacement) effectiveDockPlacement: (DockPlacement)placement;
/* On WindowServer: the saved placement for the window mode, effective. */
- (DockPlacement) windowServerDockPlacement;
- (NSUInteger) dockCellCount;
- (CGFloat) dockContentLength;
- (CGFloat) activeDockCellSize;
- (void) applyDockCellSizeToView;
- (void) loadPersistedApplications;
- (void) savePersistedApplications;
- (void) playDockRemovalSoundIfEnabled;
- (id) persistedApplicationRecordForItem: (DockItem *)item;
- (NSString *) persistedApplicationPathFromRecord: (id)record;
- (NSString *) persistedApplicationArgumentsFromRecord: (id)record;
- (BOOL) dockHasApplicationPath: (NSString *)path;
- (NSUInteger) pinnedApplicationCount;
- (NSString *) normalizedPath: (NSString *)path;
- (NSArray *) commandSearchPathComponents;
- (NSString *) procFilesystemPath;
- (NSString *) procPathForProcessIdentifierString: (NSString *)identifier;
- (BOOL) path: (NSString *)path isEqualToOrDescendantOfPath: (NSString *)parentPath;
- (NSString *) executablePathForApplicationPath: (NSString *)path;
- (NSString *) firstCommandTokenFromString: (NSString *)string;
- (NSString *) pathForExecutableCommand: (NSString *)command;
- (NSString *) executablePathForDesktopFile: (NSString *)path;
- (BOOL) stringIsProcessIdentifier: (NSString *)string;
- (NSArray *) runningProcessExecutablePaths;
- (NSString *) executablePathForProcessIdentifier: (NSNumber *)processIdentifier;
- (NSArray *) runningProcessIdentifiersForApplicationItem: (DockItem *)item;
- (BOOL) applicationItem: (DockItem *)item
matchesRunningProcessPath: (NSString *)processPath;
- (BOOL) applicationItemHasRunningProcess: (DockItem *)item
				    paths: (NSArray *)processPaths;
- (DockItem *) transientApplicationItemMatchingBundlePath: (NSString *)path;
- (DockItem *) applicationItemMatchingProcessIdentifier: (NSNumber *)processIdentifier;
- (DockItem *) transientApplicationItemForProcessIdentifier: (NSNumber *)processIdentifier;
- (NSString *) executablePathForX11WindowTitle: (NSString *)title;
- (void) resolvePathForX11WindowItem: (DockItem *)item;
- (void) resolvePathsForX11WindowItems;
- (BOOL) item: (DockItem *)item iconMatchesImage: (NSImage *)image;
- (NSString *) x11IconCacheDirectory;
- (NSString *) x11IconCacheFileNameForIdentifier: (NSString *)identifier;
- (NSString *) storeX11Icon: (NSImage *)icon
		 identifier: (NSString *)identifier;
- (NSString *) x11IconIdentifierForTitle: (NSString *)title
				    path: (NSString *)path
				  window: (unsigned long)xWindow;
- (void) applyX11Icon: (NSImage *)icon
	       toItem: (DockItem *)item
	   identifier: (NSString *)identifier;
- (void) rememberApplicationIcon: (NSImage *)icon
		      badgeLabel: (NSString *)badgeLabel
       processIdentifier: (NSNumber *)processIdentifier;
- (BOOL) applyApplicationIconUpdate: (NSDictionary *)update
			     toItem: (DockItem *)item;
- (BOOL) applyStoredApplicationIconUpdateForItem: (DockItem *)item;
- (BOOL) activateRunningApplicationWithProcessIdentifiers: (NSArray *)processIdentifiers;
- (BOOL) shouldApplyX11Icon: (NSImage *)icon toItem: (DockItem *)item;
- (void) pruneApplicationIconUpdatesForExitedProcesses;
- (BOOL) applicationBundlePathIsDock: (NSString *)path;
- (BOOL) applicationBundlePathIsWorkspace: (NSString *)path;
- (BOOL) applicationBundlePathIsCoreService: (NSString *)path;
- (BOOL) applicationBundlePathIsBuiltIn: (NSString *)path;
- (NSString *) workspaceApplicationPath;
- (void) updateTopTileWithProcessPaths: (NSArray *)processPaths;
- (BOOL) reopenRunningApplicationAtPath: (NSString *)path;
- (NSImage *) workspaceIcon;
- (void) rememberLaunchedApplicationPath: (NSString *)path;
- (BOOL) windowPathMatchesLaunchedApplication: (NSString *)path;
- (NSArray *) openAtLoginApplicationPaths;
- (BOOL) applicationPathIsOpenAtLogin: (NSString *)path;
- (void) setApplicationPath: (NSString *)path openAtLogin: (BOOL)openAtLogin;
- (BOOL) canRemoveDockItemAtIndex: (NSUInteger)index;
- (BOOL) applicationItemIsRunning: (DockItem *)item;
- (void) keepApplicationItemInDock: (DockItem *)item;
- (void) stopKeepingApplicationItemInDock: (DockItem *)item;
- (BOOL) launchApplicationAtPath: (NSString *)path;
- (BOOL) launchApplicationItem: (DockItem *)item;
- (BOOL) launchApplicationItem: (DockItem *)item useIconManager: (BOOL)useIconManager;
- (void) forgetLegacyKeepInDockForApplicationPath: (NSString *)path;
- (BOOL) iconManagerEnabledForPath: (NSString *)path;
- (NSString *) defaultsDomainForApplicationPath: (NSString *)path;
- (void) prepareDefaultsForApplicationPath: (NSString *)path;
- (void) launchTaskWithLaunchPath: (NSString *)path
			arguments: (NSArray *)arguments
		   useIconManager: (BOOL)useIconManager;
- (NSArray *) launchArgumentsFromString: (NSString *)arguments;
- (NSString *) shellQuotedArgument: (NSString *)argument;
- (void) terminateApplicationItemProcesses: (DockItem *)item;
- (void) launchOpenAtLoginApplications;
- (void) performInitialApplicationScans;
- (void) scanRunningApplications;
- (void) scanForExitedApplications;
- (NSArray *) recyclerPaths;
- (BOOL) directoryHasVisibleContentsAtPath: (NSString *)path;
- (BOOL) recyclerHasContents;
- (NSString *) recyclerPathForDropping;
- (NSString *) recyclerDestinationPathForPath: (NSString *)path
				 recyclerPath: (NSString *)recyclerPath;
- (BOOL) movePathToRecyclerFallback: (NSString *)path
                       recyclerPath: (NSString *)recyclerPath;
- (BOOL) pathIsMountPoint: (NSString *)path;
- (BOOL) unmountPath: (NSString *)path error: (NSString **)errorMessage;
- (void) updateRecyclerState;
- (void) emptyRecyclerPath: (NSString *)path;
- (void) emptyRecycler: (id)sender;
/* The screen the Dock is on: the main display. */
- (NSScreen *) dockScreen;
- (NSScreen *) dockScreenForEdge: (DockEdge)edge;
- (NSRect) dockWindowFrameForPlacement: (DockPlacement)placement;
- (NSRect) windowServerDockFrameForEdge: (DockEdge)edge
			      thickness: (CGFloat)thickness;
- (void) updateDockMenu;
- (SettingsController *) settingsController;
- (void) showSettingsPanel: (id)sender;
- (void) showSettingsForDockItem: (DockItem *)item;
- (void) applyDockPlacement;
/* The Dock's window and view take the frame for its placement. */
- (void) applyDockWindowFrame;
- (void) screenParametersDidChange: (NSNotification *)notification;
- (void) reportDockEdge;
- (void) updateDockBackground;
- (void) startLaunchWiggleForItem: (DockItem *)item;
- (void) startActivationWiggleForItem: (DockItem *)item;
- (void) startAttentionWiggleForItem: (DockItem *)item;
- (void) cancelAttentionWiggleForItem: (DockItem *)item;
- (BOOL) itemWigglesOnLaunch: (DockItem *)item;
- (BOOL) itemWigglesOnActivation: (DockItem *)item;
- (BOOL) itemWigglesOnAttentionRequest: (DockItem *)item;
- (void) refreshDock;
- (DockItem *) itemForXWindow: (unsigned long)xWindow;
- (DockItem *) itemForApplicationIconWindow: (unsigned long)xWindow;
- (void) setApplicationIconWindow: (unsigned long)xWindow forItem: (DockItem *)item;
- (void) removeApplicationIconWindowsForItem: (DockItem *)item;
- (void) restoreApplicationItemAfterExit: (DockItem *)item;
- (NSUInteger) indexForItem: (DockItem *)targetItem;
- (DockItem *) applicationItemMatchingTitle: (NSString *)title;
- (DockItem *) applicationItemMatchingExecutablePath: (NSString *)path;
- (BOOL) launchDesktopFile: (NSString *)path
		 arguments: (NSArray *)arguments
	    useIconManager: (BOOL)useIconManager;
@end
