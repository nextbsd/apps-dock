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

#import "WSDockManager.h"
#import <Foundation/NSConnection.h>
#import <GNUstepBase/GNUstep.h>
#import <GNUstepGUI/GSDisplayServer.h>

#import <errno.h>
#import <string.h>
#import <unistd.h>

#ifdef DOCK_HAVE_WINDOWSERVER
#import <WindowServer/WSClient.h>
#endif

NSString * const WSDockWindowKey = @"window";
NSString * const WSDockTitleKey = @"title";
NSString * const WSDockProcessKey = @"pid";
NSString * const WSDockAppKey = @"app";
NSString * const WSDockMinimizedKey = @"minimized";
NSString * const WSDockInDockKey = @"inDock";
NSString * const WSDockKeyKey = @"key";

static NSString * const WSDockVisibleKey = @"visible";
static NSString * const WSDockLevelKey = @"level";
static NSString * const WSDockIconKey = @"icon";
#ifdef DOCK_HAVE_WINDOWSERVER
static NSString * const WSDockFrameKey = @"frame";
#endif

/* Previews are fetched at twice the 64-point cell, for magnification. */
#define WSDockPreviewSize 128
/* Levels of the windows a Dock menu lists: normal up to, not including,
 * the main menu (NSNormalWindowLevel ... below NSMainMenuWindowLevel). */
#define WSDockMenuLevelMin 0
#define WSDockMenuLevelMax 19

@interface WSDockManager (Private)
- (NSDictionary *) windowWithIdentifier: (unsigned long)window;
- (NSSize) getSizeWindow;
#ifdef DOCK_HAVE_WINDOWSERVER
- (void) reloadWindowList;
- (void) sendDockEdge;
- (void) scheduleWindowListReload;
- (void) refreshPreviews;
- (void) registerIconManager;
- (void) startWatching;
- (void) stopWatching;
- (void) handleEvent: (const ws_event_t *)ev;
#endif
@end

@implementation WSDockManager

+ (BOOL) isWindowServerSession
{
#ifdef DOCK_HAVE_WINDOWSERVER
  Class nextbsd = NSClassFromString(@"NextBSDServer");

  return nextbsd != Nil && [GSCurrentServer() isKindOfClass:nextbsd];
#else
  return NO;
#endif
}

- (id) initWithDockView: (DockView *)view
{
  self = [super init];
  if (self)
    {
      _dockView = view;
      _windows = [NSArray new];
      _dirtyPreviews = [NSMutableSet new];
      _hidesMiniwindows = YES;
    }
  return self;
}

- (void) dealloc
{
#ifdef DOCK_HAVE_WINDOWSERVER
  if (_connection)
    {
      [self stopWatching];
      ws_disconnect((ws_connection_t *)_connection);
      _connection = NULL;
    }
#endif
  if (_iconConnection)
    {
      [_iconConnection invalidate];
    }
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  DESTROY(_iconConnection);
  DESTROY(_windows);
  DESTROY(_dirtyPreviews);
  DEALLOC;
}

- (void) setDelegate: (id)delegate
{
  _delegate = delegate;
}

- (BOOL) ownsMinimizedWindows
{
  return _ownsMinimizedWindows;
}

- (NSArray *) windows
{
  return _windows;
}

#ifdef DOCK_HAVE_WINDOWSERVER

/* The run loop modes the Dock keeps working in: menus and panels too. */
static NSArray *
watchedModes(void)
{
  return [NSArray arrayWithObjects:NSDefaultRunLoopMode,
		  NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil];
}

/* ---- connection ---- */

- (BOOL) start
{
  ws_connection_t *conn;

  conn = ws_connect("Dock", WS_CONNECT_DOCK);
  if (conn == NULL)
    {
      NSLog(@"Unable to connect to WindowServer as the Dock (%s); "
	    @"window lists and minimized windows are disabled.",
	    strerror(errno));
      return NO;
    }
  if ((ws_server_flags(conn) & WS_SERVER_DOCK) == 0)
    {
      NSLog(@"This WindowServer has no window list for the Dock; "
	    @"window lists and minimized windows are disabled.");
      ws_disconnect(conn);
      return NO;
    }
  _connection = conn;
#ifdef WS_SERVER_MENU_BAR
  /* A Mac menu bar already along the top: the Dock goes below it. */
  _menuBarHeight = ws_menu_bar_height(conn);
  if (_menuBarHeight > 0
      && [_delegate respondsToSelector:@selector(wsDockManagerMenuBarDidChange:)])
    {
      [_delegate wsDockManagerMenuBarDidChange:self];
    }
#endif
  /* With MinimizeIntoDock on, WindowServer hands the minimized windows
   * to this Dock instead of drawing tiles (WS_EVENT_DOCK_STATE). */
  ws_dock_show_minimized(conn, 1);
  [self sendDockEdge];
  [self startWatching];
  [self registerIconManager];
  [self reloadWindowList];
  return YES;
}

/* WS_MSG_DOCK_SET_EDGE, on servers that have it. */
- (void) sendDockEdge
{
#ifdef WS_SERVER_DOCK_EDGE
  static const uint32_t edges[] = {
    [DockEdgeLeft] = WS_DOCK_EDGE_LEFT,
    [DockEdgeRight] = WS_DOCK_EDGE_RIGHT,
    [DockEdgeTop] = WS_DOCK_EDGE_TOP,
    [DockEdgeBottom] = WS_DOCK_EDGE_BOTTOM
  };

  if (_connection && _edgeKnown &&
      (ws_server_flags((ws_connection_t *)_connection) & WS_SERVER_DOCK_EDGE))
    {
      ws_dock_set_edge((ws_connection_t *)_connection, edges[_edge],
		       _edgeThickness);
    }
#endif
}

- (void) startWatching
{
  NSRunLoop *loop = [NSRunLoop currentRunLoop];
  NSArray *modes = watchedModes();
  NSUInteger i;

  for (i = 0; i < [modes count]; i++)
    {
      [loop addEvent:(void *)(intptr_t)ws_connection_fd((ws_connection_t *)_connection)
		type:ET_RDESC
	     watcher:(id<RunLoopEvents>)self
	     forMode:[modes objectAtIndex:i]];
    }
}

- (void) stopWatching
{
  NSRunLoop *loop = [NSRunLoop currentRunLoop];
  NSArray *modes = watchedModes();
  NSUInteger i;

  for (i = 0; i < [modes count]; i++)
    {
      [loop removeEvent:(void *)(intptr_t)ws_connection_fd((ws_connection_t *)_connection)
		   type:ET_RDESC
		forMode:[modes objectAtIndex:i]
		    all:YES];
    }
}

- (void) receivedEvent: (void *)data
		  type: (RunLoopEventType)type
		 extra: (void *)extra
	       forMode: (NSString *)mode
{
  [self processPendingEvents];
}

static void
handleEvent(ws_connection_t *conn, const ws_event_t *ev, void *ctx)
{
  WSDockManager *self = (WSDockManager *)ctx;

  (void)conn;
  [self handleEvent:ev];
}

- (void) handleEvent: (const ws_event_t *)ev
{
  switch (ev->hdr.type)
    {
    case WS_EVENT_WINDOW_LIST_CHANGED:
      [self scheduleWindowListReload];
      break;
    case WS_EVENT_DOCK_STATE:
      _ownsMinimizedWindows =
	(ev->u.dock_state.flags & WS_DOCK_MINIMIZED_WINDOWS) != 0;
      [self scheduleWindowListReload];
      break;
    case WS_EVENT_PREVIEW_CHANGED:
      [self requestPreviewForWindow:ev->hdr.window];
      break;
#ifdef WS_SERVER_MENU_BAR
    case WS_EVENT_USABLE_AREA:
      /* The active app's Mac menu bar came, went or changed height. */
      if (ev->u.usable_area.menu_bar != _menuBarHeight)
	{
	  _menuBarHeight = ev->u.usable_area.menu_bar;
	  if ([_delegate respondsToSelector:@selector(wsDockManagerMenuBarDidChange:)])
	    {
	      [_delegate wsDockManagerMenuBarDidChange:self];
	    }
	}
      break;
#endif
    case WS_EVENT_PREVIEW:
      /* An answer that came after its request timed out. */
      if (ev->u.preview.fd >= 0)
	close(ev->u.preview.fd);
      break;
    case WS_EVENT_ERROR:
      NSDebugLLog(@"DockWM", @"WindowServer: request 0x%x: %s",
		  ev->u.error.request, ev->u.error.message);
      break;
    default:
      break;
    }
}

- (void) processPendingEvents
{
  if (!_connection)
    {
      return;
    }
  if (ws_dispatch((ws_connection_t *)_connection, handleEvent, self) < 0)
    {
      NSLog(@"Lost the Dock's WindowServer connection (%s).", strerror(errno));
      [self stopWatching];
      ws_disconnect((ws_connection_t *)_connection);
      _connection = NULL;
      _ownsMinimizedWindows = NO;
      ASSIGN(_windows, [NSArray array]);
      if ([_delegate respondsToSelector:@selector(wsDockManagerDidUpdateWindowList:)])
	{
	  [_delegate wsDockManagerDidUpdateWindowList:self];
	}
    }
}

- (void) drainTransientIconEvents
{
  [self processPendingEvents];
}

/* ---- the window list ---- */

/* A title cut short by the server may end in half a UTF-8 sequence. */
static NSString *
stringFromTitle(const char *title, size_t size)
{
  size_t len = strnlen(title, size);
  NSString *s = nil;

  while (s == nil && len > 0)
    {
      s = AUTORELEASE([[NSString alloc] initWithBytes:title
					       length:len
					     encoding:NSUTF8StringEncoding]);
      if (s == nil)
	len--;
    }
  return s != nil ? s : @"";
}

static void
collectWindow(const ws_event_window_info_t *info, void *ctx)
{
  NSMutableArray *list = (NSMutableArray *)ctx;
  NSRect frame = NSMakeRect(info->frame.x, info->frame.y,
			    info->frame.width, info->frame.height);

  [list addObject:
	  [NSDictionary dictionaryWithObjectsAndKeys:
		 [NSNumber numberWithUnsignedLong:info->window], WSDockWindowKey,
		 stringFromTitle(info->title, sizeof(info->title)), WSDockTitleKey,
		 [NSNumber numberWithInt:info->pid], WSDockProcessKey,
		 [NSNumber numberWithUnsignedInt:info->app_id], WSDockAppKey,
		 [NSNumber numberWithInt:info->level], WSDockLevelKey,
		 [NSNumber numberWithBool:(info->flags & WS_WINDOW_INFO_VISIBLE) != 0],
		 WSDockVisibleKey,
		 [NSNumber numberWithBool:(info->flags & WS_WINDOW_INFO_MINIMIZED) != 0],
		 WSDockMinimizedKey,
		 [NSNumber numberWithBool:(info->flags & WS_WINDOW_INFO_IN_DOCK) != 0],
		 WSDockInDockKey,
		 [NSNumber numberWithBool:(info->flags & WS_WINDOW_INFO_KEY) != 0],
		 WSDockKeyKey,
		 [NSNumber numberWithBool:(info->window_flags & WS_WINDOW_ICON) != 0],
		 WSDockIconKey,
		 [NSValue valueWithRect:frame], WSDockFrameKey,
		 nil]];
}

- (void) scheduleWindowListReload
{
  if (_listScheduled)
    {
      return;
    }
  _listScheduled = YES;
  /* Several notices in a row (an app starting) make one reload. */
  [self performSelector:@selector(reloadWindowList)
	     withObject:nil
	     afterDelay:0.05
		inModes:watchedModes()];
}

- (void) reloadWindowList
{
  NSMutableArray *list = [NSMutableArray array];

  _listScheduled = NO;
  if (!_connection)
    {
      return;
    }
  if (ws_list_windows_flags((ws_connection_t *)_connection, WS_LIST_ORDERED_OUT,
			    collectWindow, list) < 0)
    {
      NSLog(@"Unable to list WindowServer's windows: %s", strerror(errno));
      return;
    }
  ASSIGN(_windows, list);
  if ([_delegate respondsToSelector:@selector(wsDockManagerDidUpdateWindowList:)])
    {
      [_delegate wsDockManagerDidUpdateWindowList:self];
    }
  /* Listing may have queued notices. */
  if (ws_pending((ws_connection_t *)_connection))
    {
      [self performSelector:@selector(processPendingEvents)
		 withObject:nil
		 afterDelay:0.0
		    inModes:watchedModes()];
    }
}

/* ---- previews ---- */

- (void) requestPreviewForWindow: (unsigned long)window
{
  [_dirtyPreviews addObject:[NSNumber numberWithUnsignedLong:window]];
  if (_previewsScheduled)
    {
      return;
    }
  _previewsScheduled = YES;
  /* A window that keeps drawing while minimized (Terminal) updates its
   * preview a few times a second, not on every frame. */
  [self performSelector:@selector(refreshPreviews)
	     withObject:nil
	     afterDelay:0.25
		inModes:watchedModes()];
}

/* A premultiplied ARGB8888 picture as an NSImage. */
static NSImage *
imageFromSnapshot(const ws_snapshot_t *snap)
{
  NSBitmapImageRep *rep;
  NSImage *image;
  unsigned char *dst;
  uint32_t x, y;

  rep = AUTORELEASE([[NSBitmapImageRep alloc]
		      initWithBitmapDataPlanes:NULL
				    pixelsWide:snap->width
				    pixelsHigh:snap->height
				 bitsPerSample:8
			       samplesPerPixel:4
				      hasAlpha:YES
				      isPlanar:NO
				colorSpaceName:NSCalibratedRGBColorSpace
				   bytesPerRow:snap->width * 4
				  bitsPerPixel:32]);
  if (rep == nil)
    {
      return nil;
    }
  dst = [rep bitmapData];
  for (y = 0; y < snap->height; y++)
    {
      const uint32_t *src = (const uint32_t *)(const void *)
	((const char *)snap->pixels + (size_t)y * snap->stride);

      for (x = 0; x < snap->width; x++, dst += 4)
	{
	  dst[0] = (unsigned char)(src[x] >> 16);
	  dst[1] = (unsigned char)(src[x] >> 8);
	  dst[2] = (unsigned char)src[x];
	  dst[3] = (unsigned char)(src[x] >> 24);
	}
    }
  image = AUTORELEASE([[NSImage alloc]
			initWithSize:NSMakeSize(snap->width, snap->height)]);
  [image addRepresentation:rep];
  return image;
}

- (void) refreshPreviews
{
  NSArray *windows = [_dirtyPreviews allObjects];
  NSUInteger i;

  _previewsScheduled = NO;
  [_dirtyPreviews removeAllObjects];
  for (i = 0; _connection && i < [windows count]; i++)
    {
      unsigned long window = [[windows objectAtIndex:i] unsignedLongValue];
      ws_snapshot_t snap;
      NSImage *image;

      if (ws_dock_preview((ws_connection_t *)_connection, (uint32_t)window,
			  WSDockPreviewSize, &snap) < 0)
	{
	  continue;	/* gone, or nothing drawn yet */
	}
      image = imageFromSnapshot(&snap);
      ws_snapshot_free(&snap);
      if (image != nil &&
	  [_delegate respondsToSelector:@selector(wsDockManager:didUpdatePreview:forWindow:)])
	{
	  [_delegate wsDockManager:self didUpdatePreview:image forWindow:window];
	}
    }
}

/* ---- requests ---- */

- (void) activateWindow: (unsigned long)window
{
  if (_connection && window)
    {
      ws_dock_activate((ws_connection_t *)_connection, 0, (uint32_t)window);
    }
}

- (void) restoreWindow: (unsigned long)window
{
  NSDictionary *entry = [self windowWithIdentifier:window];

  /* Recheck: it may have been restored while the menu was open. */
  if (_connection && [[entry objectForKey:WSDockMinimizedKey] boolValue])
    {
      ws_dock_restore((ws_connection_t *)_connection, (uint32_t)window);
    }
}

/* Activating an app from the Dock brings its windows forward; if all of
 * them are minimized, it restores them instead. */
- (BOOL) activateApplicationWithProcessIdentifiers: (NSArray *)processIdentifiers
{
  NSArray *windows = [self windowsForProcessIdentifiers:processIdentifiers];
  NSDictionary *any = nil;
  NSUInteger i;
  BOOL visible = NO;

  if (!_connection || ![processIdentifiers count])
    {
      return NO;
    }
  for (i = 0; i < [_windows count]; i++)
    {
      NSDictionary *entry = [_windows objectAtIndex:i];

      if ([processIdentifiers containsObject:[entry objectForKey:WSDockProcessKey]])
	{
	  any = entry;
	  break;
	}
    }
  if (any == nil)
    {
      return NO;
    }
  for (i = 0; i < [windows count]; i++)
    {
      if ([[[windows objectAtIndex:i] objectForKey:WSDockVisibleKey] boolValue])
	{
	  visible = YES;
	}
    }
  if (!visible && [windows count])
    {
      for (i = 0; i < [windows count]; i++)
	{
	  ws_dock_restore((ws_connection_t *)_connection,
			  [[[windows objectAtIndex:i] objectForKey:WSDockWindowKey]
			    unsignedIntValue]);
	}
      return YES;
    }
  ws_dock_activate((ws_connection_t *)_connection,
		   [[any objectForKey:WSDockAppKey] unsignedIntValue], 0);
  return YES;
}

/* ---- GSIconManager ---- */

- (void) registerIconManager
{
  _iconConnection = [NSConnection new];
  [_iconConnection setRootObject:self];
  if (![_iconConnection registerName:@"GSIconManager"])
    {
      NSLog(@"Unable to register GSIconManager; app badges and attention "
	    @"requests will not reach DockWM.");
      DESTROY(_iconConnection);
    }
}

/*
 * libs-gui asks where to put an app icon window or a miniwindow. Under
 * WindowServer, apps draw no miniwindows (WindowServer minimizes), and
 * with GSSuppressAppIcon their icon windows are never shown, so the
 * answer is the window's own frame, in GNUstep's bottom-left screen
 * coordinates, sized like an icon when it has no size yet: libs-gui
 * then keeps the window where it is rather than shrinking it to nothing.
 */
- (NSRect) setWindow: (unsigned int)aWindowNumber
	appProcessId: (int)aProcessId
{
  NSSize iconSize = [self getSizeWindow];
  NSDictionary *entry;
  CGFloat screenHeight;
  NSRect frame;

  if (!_connection)
    {
      return NSMakeRect(0, 0, iconSize.width, iconSize.height);
    }
  entry = [self windowWithIdentifier:aWindowNumber];
  if (entry == nil)
    {
      /* Just created: the notice may not have come yet. */
      [self reloadWindowList];
      entry = [self windowWithIdentifier:aWindowNumber];
    }
  if (entry == nil)
    {
      return NSMakeRect(0, 0, iconSize.width, iconSize.height);
    }
  frame = [[entry objectForKey:WSDockFrameKey] rectValue];
  if (NSWidth(frame) <= 1 || NSHeight(frame) <= 1)
    {
      frame.size = iconSize;
    }
  screenHeight = ws_main_screen((ws_connection_t *)_connection)->height;
  frame.origin.y = screenHeight - NSMinY(frame) - NSHeight(frame);
  return frame;
}

#else /* !DOCK_HAVE_WINDOWSERVER */

- (BOOL) start
{
  return NO;
}

- (void) processPendingEvents
{
}

- (void) drainTransientIconEvents
{
}

- (void) requestPreviewForWindow: (unsigned long)window
{
}

- (void) activateWindow: (unsigned long)window
{
}

- (void) restoreWindow: (unsigned long)window
{
}

- (BOOL) activateApplicationWithProcessIdentifiers: (NSArray *)processIdentifiers
{
  return NO;
}

- (NSRect) setWindow: (unsigned int)aWindowNumber
	appProcessId: (int)aProcessId
{
  return NSZeroRect;
}

#endif /* DOCK_HAVE_WINDOWSERVER */

- (NSDictionary *) windowWithIdentifier: (unsigned long)window
{
  NSUInteger i;

  for (i = 0; i < [_windows count]; i++)
    {
      NSDictionary *entry = [_windows objectAtIndex:i];

      if ([[entry objectForKey:WSDockWindowKey] unsignedLongValue] == window)
	{
	  return entry;
	}
    }
  return nil;
}

- (NSArray *) dockMinimizedWindows
{
  NSMutableArray *result = [NSMutableArray array];
  NSUInteger i;

  if (!_ownsMinimizedWindows)
    {
      return result;
    }
  for (i = 0; i < [_windows count]; i++)
    {
      NSDictionary *entry = [_windows objectAtIndex:i];

      if ([[entry objectForKey:WSDockInDockKey] boolValue])
	{
	  [result addObject:entry];
	}
    }
  /* The server lists the newest windows first. */
  return [[result reverseObjectEnumerator] allObjects];
}

/* The app ids of these processes' windows: a joined helper (an X
 * server) shares its app's id. */
- (NSSet *) appIdentifiersForProcessIdentifiers: (NSArray *)processIdentifiers
{
  NSMutableSet *apps = [NSMutableSet set];
  NSUInteger i;

  for (i = 0; i < [_windows count]; i++)
    {
      NSDictionary *entry = [_windows objectAtIndex:i];

      if ([processIdentifiers containsObject:[entry objectForKey:WSDockProcessKey]])
	{
	  [apps addObject:[entry objectForKey:WSDockAppKey]];
	}
    }
  return apps;
}

- (NSArray *) windowsForProcessIdentifiers: (NSArray *)processIdentifiers
{
  NSMutableArray *result = [NSMutableArray array];
  NSMutableArray *minimized = [NSMutableArray array];
  NSSet *apps;
  NSUInteger i;

  if (![processIdentifiers count])
    {
      return result;
    }
  apps = [self appIdentifiersForProcessIdentifiers:processIdentifiers];
  /* The windows on screen top to bottom, as the stack is, then the
   * minimized ones. */
  for (i = [_windows count]; i > 0; i--)
    {
      NSDictionary *entry = [_windows objectAtIndex:i - 1];
      int level = [[entry objectForKey:WSDockLevelKey] intValue];

      if (![apps containsObject:[entry objectForKey:WSDockAppKey]] ||
	  [[entry objectForKey:WSDockIconKey] boolValue] ||
	  level < WSDockMenuLevelMin || level > WSDockMenuLevelMax ||
	  ![[entry objectForKey:WSDockTitleKey] length])
	{
	  continue;
	}
      if ([[entry objectForKey:WSDockVisibleKey] boolValue])
	{
	  [result addObject:entry];
	}
      else if ([[entry objectForKey:WSDockMinimizedKey] boolValue])
	{
	  [minimized insertObject:entry atIndex:0];
	}
    }
  [result addObjectsFromArray:minimized];
  return result;
}

- (NSArray *) processIdentifiersWithWindows
{
  NSMutableSet *pids = [NSMutableSet set];
  NSUInteger i;

  for (i = 0; i < [_windows count]; i++)
    {
      NSDictionary *entry = [_windows objectAtIndex:i];

      if ([[entry objectForKey:WSDockVisibleKey] boolValue] ||
	  [[entry objectForKey:WSDockMinimizedKey] boolValue])
	{
	  [pids addObject:[entry objectForKey:WSDockProcessKey]];
	}
    }
  return [pids allObjects];
}

- (BOOL) processIdentifiersHaveVisibleWindows: (NSArray *)processIdentifiers
{
  NSArray *windows = [self windowsForProcessIdentifiers:processIdentifiers];
  NSUInteger i;

  for (i = 0; i < [windows count]; i++)
    {
      if ([[[windows objectAtIndex:i] objectForKey:WSDockVisibleKey] boolValue])
	{
	  return YES;
	}
    }
  return NO;
}

- (BOOL) windowExists: (unsigned long)window
{
  return window != 0 && [self windowWithIdentifier:window] != nil;
}

/* Entries contain window (NSNumber) and title (NSString), as
 * X11DockManager's. */
- (NSArray *) minimizedWindowsForProcessIdentifiers: (NSArray *)processIdentifiers
					     window: (unsigned long)window
{
  NSMutableArray *result = [NSMutableArray array];
  NSArray *candidates;
  NSUInteger i;

  if (window)
    {
      NSDictionary *entry = [self windowWithIdentifier:window];

      candidates = entry ? [NSArray arrayWithObject:entry] : [NSArray array];
    }
  else
    {
      candidates = [self windowsForProcessIdentifiers:processIdentifiers];
    }
  for (i = 0; i < [candidates count]; i++)
    {
      NSDictionary *entry = [candidates objectAtIndex:i];

      if ([[entry objectForKey:WSDockMinimizedKey] boolValue])
	{
	  [result addObject:
		    [NSDictionary dictionaryWithObjectsAndKeys:
				    [entry objectForKey:WSDockWindowKey], @"window",
				    [entry objectForKey:WSDockTitleKey], @"title",
				    nil]];
	}
    }
  return result;
}

/* ---- the rest of GSIconManager, as X11DockManager's ---- */

- (void) setApplicationIconData: (NSData *)data
		      badgeText: (NSString *)badgeText
		   appProcessId: (int)aProcessId
{
  NSImage *icon = nil;

  if (aProcessId <= 0)
    {
      return;
    }
  if (![badgeText length] && [data length] && [data length] <= 16 * 1024 * 1024)
    {
      icon = AUTORELEASE([[NSImage alloc] initWithData:data]);
    }
  if ([_delegate respondsToSelector:
		   @selector(x11DockManagerDidUpdateApplicationIcon:badgeLabel:processIdentifier:)])
    {
      [_delegate x11DockManagerDidUpdateApplicationIcon:icon
					     badgeLabel:badgeText
				      processIdentifier:aProcessId];
    }
}

- (void) requestUserAttention: (NSInteger)requestType
		 appProcessId: (int)aProcessId
{
  if (aProcessId > 0 &&
      [_delegate respondsToSelector:
		   @selector(x11DockManagerDidRequestUserAttentionForProcessIdentifier:requestType:)])
    {
      [_delegate x11DockManagerDidRequestUserAttentionForProcessIdentifier:aProcessId
							      requestType:requestType];
    }
}

- (void) cancelUserAttentionRequest: (NSInteger)request
		       appProcessId: (int)aProcessId
{
  if (aProcessId > 0 &&
      [_delegate respondsToSelector:
		   @selector(x11DockManagerDidCancelUserAttentionRequest:forProcessIdentifier:)])
    {
      [_delegate x11DockManagerDidCancelUserAttentionRequest:request
					forProcessIdentifier:aProcessId];
    }
}

- (void) removeWindow: (unsigned int)aWindowNumber
{
}

- (NSSize) getSizeWindow
{
  return NSMakeSize(64, 64);
}

/* ---- X11DockManager calls with nothing to do under WindowServer ---- */

- (void) setDockPlacement: (DockPlacement)placement
{
}

- (void) setDockEdge: (DockEdge)edge thickness: (CGFloat)thickness
{
  unsigned int pixels = thickness > 0 ? (unsigned int)ceil(thickness) : 0;

  if (_edgeKnown && _edge == edge && _edgeThickness == pixels)
    {
      return;
    }
  _edgeKnown = YES;
  _edge = edge;
  _edgeThickness = pixels;
#ifdef DOCK_HAVE_WINDOWSERVER
  [self sendDockEdge];
#endif
}

- (CGFloat) menuBarHeight
{
  return (CGFloat)_menuBarHeight;
}

/* Under WindowServer, where minimized windows go is WindowServer's
 * MinimizeIntoDock default, not the Dock's Hide Miniwindows. */
- (void) setHidesMiniwindows: (BOOL)hidesMiniwindows
{
  _hidesMiniwindows = hidesMiniwindows;
}

- (void) makeWindowSticky: (unsigned long)window
{
}

- (void) scanForDockApps
{
}

- (void) dockWindow: (unsigned long)window atIndex: (NSUInteger)index
{
}

- (void) hideDockedWindow: (unsigned long)window
{
}

- (void) moveDockedWindow: (unsigned long)window toIndex: (NSUInteger)index
{
}

/* Apps close their own windows; the Dock's Quit quits the app. */
- (void) closeWindow: (unsigned long)window
{
}

@end
