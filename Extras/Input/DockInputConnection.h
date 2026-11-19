/*
 * Dock
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
 * DockInputConnection: the Input extra's tool connection to WindowServer
 * (WS_CONNECT_CONTROL, as wsctl's), beside the GNUstep backend's own. It
 * lists the keyboard layouts, makes one active
 * (WS_MSG_SET_KEYBOARD_LAYOUT), and tells its delegate when the layouts
 * or the active one change (WS_EVENT_SETTINGS_CHANGED,
 * WS_EVENT_KEYBOARD_LAYOUT). When WindowServer goes away it tries again
 * every few seconds.
 *
 * The layout half of Keyboard.app's KBConnection (nextbsd/apps-settings),
 * whose author wrote it for this extra when it lived there.
 */

#import <Foundation/Foundation.h>

@class DockInputConnection;

@protocol DockInputConnectionDelegate
/* Connected, disconnected, or the settings (the layout list) changed. */
- (void) connectionDidChange: (DockInputConnection *)connection;
/* The active layout changed (the shortcut, this menu, Keyboard.app). */
- (void) connectionLayoutDidChange: (DockInputConnection *)connection;
@end

@interface DockInputConnection : NSObject
{
  void *_conn;			/* ws_connection_t */
  NSString *_name;
  id _delegate;			/* not retained */
  NSTimer *_retryTimer;
  BOOL _changed;
  BOOL _layoutChanged;
}

- (id) initWithName: (NSString *)name
	   delegate: (id <DockInputConnectionDelegate>)delegate;
- (void) invalidate;

- (BOOL) isConnected;

/* The layout list, each a dictionary of Layout, Variant and Name (XKB's
 * description), in order; activeIndex gets the active one's index (-1 if
 * none). Empty when not connected. */
- (NSArray *) layoutsWithActiveIndex: (int *)activeIndex;

/* Make layout index of the list active. 0 or an errno value. */
- (int) setActiveLayout: (unsigned)index;

@end
