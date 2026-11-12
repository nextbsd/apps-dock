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

#import <AppKit/AppKit.h>

@class DockItem;

/* Keeps the separate icon windows ordered with the dock on GNUstep. */
@interface DockWindow : NSWindow
@end

typedef enum
  {
    DockRunningIndicatorModeRunningDot = 0,
    DockRunningIndicatorModeNotRunningDots = 1
  } DockRunningIndicatorMode;

@protocol DockViewDelegate
- (void) dockViewDidReceivePaths: (NSArray *)paths;
- (void) dockViewDidReceivePaths: (NSArray *)paths
			 atIndex: (NSUInteger)index;
- (void) dockViewDidReceivePathsInRecycler: (NSArray *)paths;
- (void) dockViewDidActivateItem: (DockItem *)item;
- (void) dockViewDidActivateTopIcon;
- (void) dockViewDidActivateRecycler;
- (void) dockViewDidMoveItemFromIndex: (NSUInteger)fromIndex
                              toIndex: (NSUInteger)toIndex;
- (void) dockViewDidRemoveItemAtIndex: (NSUInteger)index;
- (BOOL) dockView: (id)dockView canRemoveItemAtIndex: (NSUInteger)index;
- (BOOL) dockView: (id)dockView itemIsKeptInDock: (DockItem *)item;
- (void) dockView: (id)dockView didToggleKeepInDockForItem: (DockItem *)item;
- (BOOL) dockView: (id)dockView itemIsOpenAtLogin: (DockItem *)item;
- (void) dockView: (id)dockView didToggleOpenAtLoginForItem: (DockItem *)item;
- (void) dockView: (id)dockView didShowItemInFileViewer: (DockItem *)item;
- (BOOL) dockView: (id)dockView canShowSettingsForItem: (DockItem *)item;
- (void) dockView: (id)dockView didShowSettingsForItem: (DockItem *)item;
- (BOOL) dockView: (id)dockView canRestoreItem: (DockItem *)item;
- (NSArray *) dockView: (id)dockView minimizedWindowsForItem: (DockItem *)item;
- (void) dockView: (id)dockView restoreWindows: (NSArray *)windows
          forItem: (DockItem *)item;
- (void) dockView: (id)dockView didQuitItem: (DockItem *)item;
/* The item's windows for its menu, front to back: dictionaries with
 * window (NSNumber), title, minimized and key (NSNumber BOOLs). Empty
 * where the Dock can't see windows (X11). */
- (NSArray *) dockView: (id)dockView windowsForItem: (DockItem *)item;
- (void) dockView: (id)dockView activateWindow: (NSNumber *)window
	  forItem: (DockItem *)item;
- (void) dockViewDidEmptyRecycler: (id)dockView;
@end

@interface DockView : NSView
{
  NSMutableArray *_items;
  NSMutableDictionary *_iconWindows;
  NSWindow *_tooltipWindow;
  BOOL _syncingIconWindows;
  id _delegate;
  BOOL _draggingPaths;
  BOOL _performedDragOperation;
  NSPasteboard *_dragPasteboard;
  NSImage *_topTileIcon;
  NSImage *_recyclerIcon;
  NSImage *_cellBackgroundImage;
  NSColor *_backgroundColor;
  CGFloat _backgroundAlpha;
  CGFloat _cellSize;
  CGFloat _dockGap;
  CGFloat _dockPad;
  CGFloat _hoverIconScale;
  NSTimeInterval _tooltipDelay;
  BOOL _usesCellBackgroundTile;
  BOOL _allowsGaps;
  BOOL _showsBorder;
  BOOL _magnifiesHoveredIcons;
  DockRunningIndicatorMode _runningIndicatorMode;
  BOOL _recyclerHasContents;
  BOOL _horizontal;
  NSTimer *_tooltipTimer;
  NSTimer *_wiggleTimer;
  NSTimer *_recyclerWiggleTimer;
  DockItem *_wiggleItem;
  NSTimeInterval _wiggleStartTime;
  BOOL _wiggleRepeatsUntilAcknowledged;
  NSTimeInterval _recyclerWiggleStartTime;
  NSInteger _hoveredItemIndex;
  NSInteger _tooltipItemIndex;
  NSTrackingRectTag _trackingRectTag;
  NSPoint _mouseDownPoint;
  NSUInteger _mouseDownItemIndex;
  NSUInteger _draggedItemIndex;
  NSUInteger _dropIndex;
  NSUInteger _pinnedItemCount;
  NSUInteger _lastMouseDownIndex;
  NSTimeInterval _lastMouseDownTime;
  BOOL _singleClickLaunchesApplications;
  BOOL _fillsColumn;
  CGFloat _statusAreaLength;
}

- (void) setDelegate: (id)delegate;
- (void) setItems: (NSArray *)items;
- (void) setPinnedItemCount: (NSUInteger)count;
- (void) setBackgroundColor: (NSColor *)color;
- (void) setBackgroundAlpha: (CGFloat)alpha;
- (void) setShowsBorder: (BOOL)showsBorder;
- (BOOL) showsBorder;
- (void) setRunningIndicatorMode: (DockRunningIndicatorMode)mode;
/* The top tile's icon: Workspace's, or the GNUstep logo when nil. */
- (void) setTopTileIcon: (NSImage *)icon;
- (DockRunningIndicatorMode) runningIndicatorMode;
- (void) setRecyclerHasContents: (BOOL)hasContents;
- (void) setIconCellSize: (CGFloat)cellSize
		     gap: (CGFloat)gap
		 padding: (CGFloat)padding;
- (void) setMagnifiesHoveredIcons: (BOOL)magnifies;
- (BOOL) magnifiesHoveredIcons;
- (void) setHoverIconScale: (CGFloat)scale;
- (CGFloat) hoverIconScale;
- (void) setTooltipDelay: (NSTimeInterval)delay;
- (NSTimeInterval) tooltipDelay;
- (void) setSingleClickLaunchesApplications: (BOOL)singleClickLaunches;
- (BOOL) singleClickLaunchesApplications;
- (void) setUsesCellBackgroundTile: (BOOL)usesTile;
- (void) setAllowsGaps: (BOOL)allows;
- (BOOL) usesCellBackgroundTile;
- (void) setHorizontal: (BOOL)horizontal;
- (BOOL) isHorizontal;
/*
 * The NextBSD column (WindowServer sessions): the view fills the whole
 * screen edge, top to bottom: the top tile, the items (pinned apps,
 * running apps, minimized windows, each section set off by a
 * separator), the status area for Dock extras, a flexible gap that
 * takes the rest and accepts drops, and the Recycler fixed at the
 * bottom. Otherwise the Recycler follows the last item.
 */
- (void) setFillsColumn: (BOOL)fills;
- (BOOL) fillsColumn;
/* The status area's length along the column (0: empty for now; the
 * Dock extras of apps-dock#5 will fill it). */
- (void) setStatusAreaLength: (CGFloat)length;

@end

@interface DockView (Wiggle)
- (void) startWiggleForItem: (DockItem *)item;
- (void) startAttentionWiggleForItem: (DockItem *)item;
- (void) acknowledgeWiggleForItem: (DockItem *)item;
- (void) startRecyclerWiggle;
@end

@interface DockView (Layout)
- (NSRect) topTileRect;
- (NSRect) recyclerTileRect;
- (NSPoint) cellOriginAtIndex: (NSUInteger)index;
- (NSSize) cellSize;
@end

@interface DockView (IconWindows)
- (void) repairIconWindowStacking;

@end
