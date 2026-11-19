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
 * Dock extras: small status tools living in the Dock's status area, like
 * Window Maker's dockapps and macOS's menu extras.
 *
 * A Dock extra is a loadable bundle with the extension .dockextra. The
 * Dock loads them at start from ~/Library/DockExtras, then
 * /Local/Library/DockExtras, then /System/Library/DockExtras (the first
 * bundle with a given CFBundleIdentifier wins), and they run inside the
 * Dock's process. A misbehaving extra is removed by taking it out of the
 * folder.
 *
 * The bundle's principal class conforms to DockExtra. Its Info.plist may
 * carry:
 *
 *   CFBundleIdentifier         the extra's identity, used for its order
 *                              and for hiding it (required)
 *   CFBundleName               the name shown in the Dock's settings
 *   DockExtraDefaultPosition   a number: where it goes, top to bottom,
 *                              until the user drags it elsewhere
 *   DockExtraMenuBarPosition   a number below 1000: where it goes in the
 *                              menu bar, left to right (else the
 *                              DockExtraDefaultPosition)
 *   DockExtraMenuBarPriority   "clock" for the clock, rightmost in the
 *                              menu bar; else "system"
 *
 * The status area runs along the Dock: down a column on a side edge,
 * across a row on the top or bottom edge. Tiles are square, so an extra
 * draws the same either way, and it never assumes which edge the Dock is
 * on: panels go where -dockExtra:panelFrameForSize: says.
 *
 * The extra draws its own tile, at the Dock's cell size, and tells the
 * Dock when it needs redrawing (from its own timer or notification; the
 * Dock never polls it). A click shows the extra's menu; a double-click,
 * if the extra implements -dockExtraOpen:, opens something (an app or a
 * preferences pane) instead. The user orders the extras by dragging them
 * within the status area; they can't be dragged out or into the
 * Recycler, and each one can be hidden from the Dock's settings, or from
 * a settings app's "Show ... in Dock" checkbox (DockExtrasSettings.h).
 *
 * In the Mac menu style (NSMacintoshInterfaceStyle, the menu bar along
 * the top of the screen) the extras leave the Dock and go into the menu
 * bar, as macOS's ControlCenter puts its items there: each one is its
 * own NSStatusItem at the bar's right end, left to right by
 * DockExtraMenuBarPosition, the clock rightmost, drawn in the bar's text
 * colour without a plate (-statusItemTitle, -drawStatusItemInRect:color:
 * below). A click drops its menu below it: -menuForEvent: with a nil
 * event, which answers the menu rather than a panel. Switching the
 * style moves them back and forth at once. "Show in Dock" then means
 * "show in the menu bar".
 *
 * Like a macOS menu extra, an extra's menu gives quick controls and ends
 * with an "Open X Settings..." item for the settings app that has the
 * rest: DockExtraAddSettingsItem() below. An extra shows only where its
 * hardware is (-isAvailable), so a Mac-like list of extras appears by
 * itself.
 */

#import <AppKit/AppKit.h>

/* What the Dock offers an extra. */
@protocol DockExtraHost <NSObject>
/* Redraw the extra's tile (call -drawInRect: again) soon. */
- (void) dockExtraNeedsDisplay: (id)extra;
/* -isAvailable may have changed: the hardware came or went. */
- (void) dockExtraAvailabilityDidChange: (id)extra;
/* The tile, in screen coordinates (NSZeroRect while it isn't shown), to
 * place a panel beside it. */
- (NSRect) screenFrameForDockExtra: (id)extra;
/* Where to put a panel of this size (a calendar, a password panel):
 * beside the tile, toward the middle of the screen, whichever edge the
 * Dock is on, and kept on the screen. */
- (NSRect) dockExtra: (id)extra panelFrameForSize: (NSSize)size;
/* The Dock's cell size: tiles are square. */
- (CGFloat) dockExtraCellSize;
/* YES when the user has asked for test data (the DockExtrasTestData
 * default): extras whose hardware is missing show made-up values, for
 * screenshots and testing. */
- (BOOL) dockExtrasUseTestData;
/* The test data's settings, from the DockExtrasTestData dictionary (an
 * empty dictionary when the default is just YES). */
- (NSDictionary *) dockExtrasTestData;
@optional
/* An "Open ... Settings" item that launches the first of these apps
 * ("Bluetooth", "Energy") found in ~/Applications, /System/Applications,
 * /Local/Applications or /Network/Applications, or nil when none is
 * installed. Its target is the host. Use DockExtraAddSettingsItem(). */
- (NSMenuItem *) dockExtraSettingsItemWithTitle: (NSString *)title
				   applications: (NSArray *)names;
@end

@protocol DockExtra <NSObject>
/* Called once, after the bundle is loaded. Start watching the extra's
 * data source here. */
- (id) initWithDockHost: (id <DockExtraHost>)host;
/* NO when there is nothing to show (no Wi-Fi radio, no battery, no
 * sound device): the Dock then gives the extra no tile. Call
 * -dockExtraAvailabilityDidChange: when this changes. */
- (BOOL) isAvailable;
/* Draw the tile into rect, a square of the Dock's cell size, in the
 * current graphics context, over a transparent background. */
- (void) drawInRect: (NSRect)rect;
/* The tooltip beside the tile. */
- (NSString *) toolTip;
/* The menu to show for a click (a left or right mouse-down), or nil to
 * show none, for an extra that put up a panel of its own instead. In the
 * menu bar the event is nil: answer the menu (the right-click's), which
 * drops below the status item. */
- (NSMenu *) menuForEvent: (NSEvent *)event;
@optional
/*
 * In the menu bar. An extra that shows words there (the clock) answers
 * them here, and the bar draws them in its own font and colours; nil
 * for a glyph. A glyph is drawn by -drawStatusItemInRect:color:, in
 * color (the bar's text colour: one colour, its alpha for dimmed parts)
 * and without a plate, into a rect as tall as the bar and as wide as
 * -statusItemWidthForHeight: says (the height when it isn't
 * implemented). An extra that implements neither gets its tile drawn
 * in one colour, its plate left out. Call -dockExtraNeedsDisplay: when
 * any of these change, as for the tile.
 */
- (NSString *) statusItemTitle;
- (CGFloat) statusItemWidthForHeight: (CGFloat)height;
- (void) drawStatusItemInRect: (NSRect)rect color: (NSColor *)color;
/* Double-click: open an app or a Workspace Preferences pane. An extra
 * that implements this gets its menu a moment after a single click,
 * once it is clear no second click is coming. */
- (void) dockExtraOpen: (id)sender;
/* Scroll-wheel events over the tile (the sound extra's volume). */
- (void) scrollWheel: (NSEvent *)event;
/* The extra is about to be released: hidden in the settings, or the
 * Dock is quitting. Stop timers and notifications. */
- (void) dockExtraWillUnload;
@end

/*
 * The common look: a dark rounded plate inset in the cell, with the
 * extra's glyph or text drawn on it in white. Extras that draw a plate
 * look like one family, and stay readable over any desktop.
 */
static inline NSRect
DockExtraPlateRect(NSRect cell)
{
  CGFloat inset = floor(NSWidth(cell) * 0.08);

  return NSInsetRect(cell, inset, inset);
}

static inline void
DockExtraDrawPlate(NSRect cell)
{
  NSRect plate = DockExtraPlateRect(cell);
  CGFloat radius = floor(NSWidth(plate) * 0.2);
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:plate
						       xRadius:radius
						       yRadius:radius];

  [[NSColor colorWithCalibratedWhite:0.13 alpha:0.86] set];
  [path fill];
  [[NSColor colorWithCalibratedWhite:1.0 alpha:0.16] set];
  [path setLineWidth:1.0];
  [path stroke];
}

/* End menu with a separator and "title" (Open Bluetooth Settings...),
 * which launches the first of the settings apps named that is installed.
 * With none of them installed (or an older Dock), the menu is left as it
 * was. */
static inline void
DockExtraAddSettingsItem(NSMenu *menu, id host, NSString *title,
			 NSArray *applications)
{
  NSMenuItem *item = nil;

  if ([host respondsToSelector:
	      @selector(dockExtraSettingsItemWithTitle:applications:)])
    {
      item = [host dockExtraSettingsItemWithTitle:title
				     applications:applications];
    }
  if (item)
    {
      if ([menu numberOfItems])
	{
	  [menu addItem:[NSMenuItem separatorItem]];
	}
      [menu addItem:item];
    }
}

/* The plate's foreground: white, or dimmed for "off" and "none". */
static inline NSColor *
DockExtraForegroundColor(BOOL dimmed)
{
  return [NSColor colorWithCalibratedWhite:1.0 alpha:dimmed ? 0.38 : 0.95];
}

