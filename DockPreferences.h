/*
 * DockWM
 *
 * Copyright (C) 2026 Gregory Casamento <greg.casamento@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#import <AppKit/AppKit.h>
#import "DockView.h"
#import "X11DockManager.h"

/* The desktop setting for the Dock's edge, and the distributed
 * notification Workspace Preferences posts when it changes (the
 * userInfo's "key" and its effective "value"); see nextbsd-theme's
 * NBDesktopSettings.h. */
#define DockPositionDefaultsKey @"NBDockPosition"
/* The Dock position is kept per window mode: the mode, the user's
 * choices per mode (NSGlobalDomain) and the theme's (Info.plist). */
#define DockWindowModeDefaultsKey @"NBWindowMode"
#define DockModeSettingsKey @"NBModeSettings"
#define DockModeDefaultsKey @"NBModeDefaults"
#define DockDesktopSettingsChangedNotification \
  @"org.nextbsd.DesktopSettingsChanged"

enum
{
  DockCellSizeModeCurrent = 0,
  DockCellSizeMode64 = 1
};

@interface DockPreferences : NSObject

+ (CGFloat) dockCellSize;
+ (CGFloat) padForCellSizeMode: (NSInteger)mode;
+ (CGFloat) gapForCellSizeMode: (NSInteger)mode;
+ (CGFloat) windowWidthForCellSizeMode: (NSInteger)mode;
+ (NSString *) largerCellSizeTitle;
+ (BOOL) placementIsHorizontal: (DockPlacement)placement;
+ (DockEdge) edgeForPlacement: (DockPlacement)placement;
+ (DockPlacement) placementForEdge: (DockEdge)edge;
/* An NBDockPosition value (right, left, top, bottom) as a placement:
 * NO when it isn't one of them. */
+ (BOOL) placement: (DockPlacement *)placement forDockPosition: (id)position;
+ (NSColor *) calibratedBackgroundColor: (NSColor *)color;

- (DockPlacement) savedDockPlacement;
/* The window mode in effect, stacking or tiling (NBWindowMode). */
+ (NSString *) windowMode;
/* On WindowServer: one of the four edge placements, from the desktop
 * setting NBDockPosition in the current window mode (see nextbsd-theme's
 * NBDesktopSettings.h). */
- (DockPlacement) savedWindowServerDockPlacement;
- (void) saveDockPlacement: (DockPlacement)placement;
/* The user's NBDockPosition for the current window mode, in
 * NSGlobalDomain's NBModeSettings, for the placement's edge, as
 * Workspace Preferences writes it; then tells other apps. */
- (void) saveDockPosition: (DockPlacement)placement;
- (NSColor *) savedBackgroundColor;
- (void) saveBackgroundColor: (NSColor *)color;
- (CGFloat) savedWindowAlpha;
- (void) saveWindowAlpha: (CGFloat)alpha;
- (BOOL) savedShowDockBorder;
- (void) saveShowDockBorder: (BOOL)showDockBorder;
- (NSInteger) savedDockCellSizeMode;
- (void) saveDockCellSizeMode: (NSInteger)mode;
- (DockRunningIndicatorMode) savedRunningIndicatorMode;
- (void) saveRunningIndicatorMode: (DockRunningIndicatorMode)mode;
- (BOOL) savedAllowsGaps;
- (void) saveAllowsGaps: (BOOL)allows;
- (BOOL) savedUseCellTileBackground;
- (void) saveUseCellTileBackground: (BOOL)useCellTileBackground;
- (BOOL) savedMagnifiesHoveredIcons;
- (void) saveMagnifiesHoveredIcons: (BOOL)magnifiesHoveredIcons;
- (NSTimeInterval) savedTooltipDelay;
- (void) saveTooltipDelay: (NSTimeInterval)delay;
- (CGFloat) savedHoverIconScale;
- (void) saveHoverIconScale: (CGFloat)scale;
- (BOOL) savedWigglesOnLaunch;
- (void) saveWigglesOnLaunch: (BOOL)wiggles;
- (BOOL) savedWigglesOnActivation;
- (void) saveWigglesOnActivation: (BOOL)wiggles;
- (BOOL) savedWigglesOnAttentionRequest;
- (void) saveWigglesOnAttentionRequest: (BOOL)wiggles;
- (BOOL) savedPlaysSoundOnRemove;
- (void) savePlaysSoundOnRemove: (BOOL)playsSound;
- (BOOL) savedSingleClickLaunchesApplications;
- (void) saveSingleClickLaunchesApplications: (BOOL)singleClickLaunches;
- (BOOL) savedKeepsMissingApplications;
- (void) saveKeepsMissingApplications: (BOOL)keep;
- (void) applyIconManagerPreference;
- (BOOL) savedUsesIconManager;
- (void) saveUsesIconManager: (BOOL)useIconManager;
/* nil inherits the global preference; NSNumber provides an app override. */
- (NSNumber *) iconManagerOverrideForDomain: (NSString *)domain;
- (void) setIconManagerOverride: (NSNumber *)value forDomain: (NSString *)domain;
- (BOOL) savedHidesMiniwindows;
- (void) saveHidesMiniwindows: (BOOL)hidesMiniwindows;
- (CGFloat) savedDockScale;
- (void) saveDockScale: (CGFloat)scale;

@end
