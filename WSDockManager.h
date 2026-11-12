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

/*
 * WSDockManager: the Dock's window features on NextBSD's WindowServer,
 * what X11DockManager does under X11. It connects to WindowServer as
 * the Dock (WS_CONNECT_DOCK, a privileged window-list connection beside
 * the GNUstep backend's own), keeps every app's window list up to date
 * from WindowServer's change notices, activates apps and windows,
 * restores minimized windows, fetches previews of the minimized windows
 * WindowServer hands to the Dock, and registers GSIconManager so apps'
 * badges and attention requests reach the Dock. It answers the
 * AppController with the X11DockManagerDelegate calls, plus the
 * WSDockManagerDelegate ones below.
 */

#import <AppKit/AppKit.h>
#import "X11DockManager.h"

@class WSDockManager;

/* Keys of the window entries WSDockManager hands out. */
extern NSString * const WSDockWindowKey;	/* NSNumber, window id */
extern NSString * const WSDockTitleKey;		/* NSString */
extern NSString * const WSDockProcessKey;	/* NSNumber, owner pid */
extern NSString * const WSDockAppKey;		/* NSNumber, app id */
extern NSString * const WSDockMinimizedKey;	/* NSNumber, BOOL */
extern NSString * const WSDockInDockKey;	/* NSNumber, BOOL: the Dock shows it */
extern NSString * const WSDockKeyKey;		/* NSNumber, BOOL: key window */

/* Besides these, WSDockManager sends its delegate the
 * X11DockManagerDelegate calls for badges and attention requests. */
@protocol WSDockManagerDelegate
/* The window list changed (WindowServer said so). */
- (void) wsDockManagerDidUpdateWindowList: (WSDockManager *)manager;
/* A new preview of a minimized window the Dock shows. */
- (void) wsDockManager: (WSDockManager *)manager
      didUpdatePreview: (NSImage *)preview
	     forWindow: (unsigned long)window;
@optional
/* The menu bar strip along the top (-menuBarHeight) changed. */
- (void) wsDockManagerMenuBarDidChange: (WSDockManager *)manager;
@end

@interface WSDockManager : NSObject
{
  id _delegate;
  DockView *_dockView;
  void *_connection;
  NSArray *_windows;
  NSConnection *_iconConnection;
  NSMutableSet *_dirtyPreviews;
  BOOL _ownsMinimizedWindows;
  BOOL _hidesMiniwindows;
  BOOL _listScheduled;
  BOOL _previewsScheduled;
  BOOL _edgeKnown;
  DockEdge _edge;
  unsigned int _edgeThickness;
  unsigned int _menuBarHeight;
}

/* YES when this process draws through the nextbsd backend. */
+ (BOOL) isWindowServerSession;

- (id) initWithDockView: (DockView *)view;
- (void) setDelegate: (id)delegate;
- (BOOL) start;

/* WindowServer hands minimized windows to the Dock (MinimizeIntoDock). */
- (BOOL) ownsMinimizedWindows;
/* Every window, as dictionaries with the keys above, bottom to top. */
- (NSArray *) windows;
/* The minimized windows the Dock shows, oldest first. */
- (NSArray *) dockMinimizedWindows;
/* The windows of these processes on normal and higher levels, as
 * dictionaries with the keys above (for the Dock menu). */
- (NSArray *) windowsForProcessIdentifiers: (NSArray *)processIdentifiers;
- (NSArray *) processIdentifiersWithWindows;
- (BOOL) processIdentifiersHaveVisibleWindows: (NSArray *)processIdentifiers;
- (void) requestPreviewForWindow: (unsigned long)window;

/* The screen edge the Dock fills and its thickness in pixels, for
 * WindowServer, so that tiling keeps that strip free (servers with
 * WS_SERVER_DOCK_EDGE; sent again on connecting). */
- (void) setDockEdge: (DockEdge)edge thickness: (CGFloat)thickness;
/* The height of the Mac menu bar along the top of the screen
 * (NBMenuStyle macmenubar), which the Dock stays below; 0 for none. */
- (CGFloat) menuBarHeight;

/* The X11DockManager calls AppController makes. */
- (void) setDockPlacement: (DockPlacement)placement;
- (void) setHidesMiniwindows: (BOOL)hidesMiniwindows;
- (void) makeWindowSticky: (unsigned long)window;
- (void) processPendingEvents;
- (void) drainTransientIconEvents;
- (void) scanForDockApps;
- (void) dockWindow: (unsigned long)window atIndex: (NSUInteger)index;
- (void) hideDockedWindow: (unsigned long)window;
- (void) moveDockedWindow: (unsigned long)window toIndex: (NSUInteger)index;
- (BOOL) windowExists: (unsigned long)window;
- (void) activateWindow: (unsigned long)window;
- (BOOL) activateApplicationWithProcessIdentifiers: (NSArray *)processIdentifiers;
- (NSArray *) minimizedWindowsForProcessIdentifiers: (NSArray *)processIdentifiers
					     window: (unsigned long)window;
- (void) restoreWindow: (unsigned long)window;
- (void) closeWindow: (unsigned long)window;

@end
