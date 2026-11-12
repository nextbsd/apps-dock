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
 * Recycler, and each one can be hidden from the Dock's settings.
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
 * show none, for an extra that put up a panel of its own instead. */
- (NSMenu *) menuForEvent: (NSEvent *)event;
@optional
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

/* The plate's foreground: white, or dimmed for "off" and "none". */
static inline NSColor *
DockExtraForegroundColor(BOOL dimmed)
{
  return [NSColor colorWithCalibratedWhite:1.0 alpha:dimmed ? 0.38 : 0.95];
}

