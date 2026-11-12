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

#import "DockPreferences.h"
#import <GNUstepGUI/GSTheme.h>

static CGFloat DockCell = 64.0;
static CGFloat DockGap = 2.0;
static CGFloat DockCompactGap = 1.0;
static CGFloat DockPad = 10.0;
static CGFloat DockCompactPad = 0.0;
static NSString *DockBackgroundColorDefaultsKey = @"DockBackgroundColor";
static NSString *DockWindowAlphaDefaultsKey = @"DockWindowAlpha";
static NSString *DockShowBorderDefaultsKey = @"DockShowBorder";
static NSString *DockCellSizeModeDefaultsKey = @"DockCellSizeMode";
static NSString *DockUseCellTileBackgroundDefaultsKey = @"DockUseCellTileBackground";
static NSString *DockRunningIndicatorModeDefaultsKey = @"DockRunningIndicatorMode";
static NSString *DockMagnifiesHoveredIconsDefaultsKey = @"DockMagnifiesHoveredIcons";
static NSString *DockHoverIconScaleDefaultsKey = @"DockHoverIconScale";
static NSString *DockWigglesOnLaunchDefaultsKey = @"DockWigglesOnLaunch";
static NSString *DockWigglesOnActivationDefaultsKey = @"DockWigglesOnActivation";
static NSString *DockWigglesOnAttentionRequestDefaultsKey = @"DockWigglesOnAttentionRequest";
static NSString *DockPlaysSoundOnRemoveDefaultsKey = @"DockPlaysSoundOnRemove";
static NSString *DockSingleClickLaunchesApplicationsDefaultsKey = @"DockSingleClickLaunchesApplications";
static NSString *DockHidesMiniwindowsDefaultsKey = @"DockHidesMiniwindows";
static NSString *DockScaleDefaultsKey = @"DockScale";

@implementation DockPreferences

+ (CGFloat) dockCellSize
{
  return DockCell;
}

+ (CGFloat) padForCellSizeMode: (NSInteger)mode
{
  return mode == DockCellSizeMode64 ? DockCompactPad : DockPad;
}

+ (CGFloat) gapForCellSizeMode: (NSInteger)mode
{
  return mode == DockCellSizeMode64 ? DockCompactGap : DockGap;
}

+ (CGFloat) windowWidthForCellSizeMode: (NSInteger)mode
{
  return DockCell + [self padForCellSizeMode:mode] * 2.0;
}

+ (NSString *) largerCellSizeTitle
{
  CGFloat tileSize = DockCell + DockPad * 2.0;

  return [NSString stringWithFormat:@"%.0f x %.0f", tileSize, tileSize];
}

+ (BOOL) placementIsHorizontal: (DockPlacement)placement
{
  return placement == DockPlacementTopCenter || placement == DockPlacementBottomCenter;
}

+ (DockEdge) edgeForPlacement: (DockPlacement)placement
{
  switch (placement)
    {
    case DockPlacementLeftTop:
    case DockPlacementLeftCenter:
      return DockEdgeLeft;
    case DockPlacementTopCenter:
      return DockEdgeTop;
    case DockPlacementBottomCenter:
      return DockEdgeBottom;
    case DockPlacementRightTop:
    case DockPlacementRightCenter:
    default:
      return DockEdgeRight;
    }
}

+ (DockPlacement) placementForEdge: (DockEdge)edge
{
  switch (edge)
    {
    case DockEdgeLeft:
      return DockPlacementLeftTop;
    case DockEdgeTop:
      return DockPlacementTopCenter;
    case DockEdgeBottom:
      return DockPlacementBottomCenter;
    case DockEdgeRight:
    default:
      return DockPlacementRightTop;
    }
}

+ (BOOL) placement: (DockPlacement *)placement forDockPosition: (id)position
{
  if (![position isKindOfClass:[NSString class]])
    {
      return NO;
    }
  if ([position isEqualToString:@"right"])
    {
      *placement = DockPlacementRightTop;
    }
  else if ([position isEqualToString:@"left"])
    {
      *placement = DockPlacementLeftTop;
    }
  else if ([position isEqualToString:@"top"])
    {
      *placement = DockPlacementTopCenter;
    }
  else if ([position isEqualToString:@"bottom"])
    {
      *placement = DockPlacementBottomCenter;
    }
  else
    {
      return NO;
    }
  return YES;
}

static NSString *
dockPositionForPlacement(DockPlacement placement)
{
  switch ([DockPreferences edgeForPlacement:placement])
    {
    case DockEdgeLeft:
      return @"left";
    case DockEdgeTop:
      return @"top";
    case DockEdgeBottom:
      return @"bottom";
    case DockEdgeRight:
    default:
      return @"right";
    }
}

/*
 * The DockPlacement default as a placement: a number (0 to 5), or an
 * edge's name, so that `defaults write DockWM DockPlacement top` works
 * as well as `... DockPlacement 4`. NO when it is neither.
 */
static BOOL
placementFromDefault(id value, DockPlacement *placement)
{
  NSInteger number;

  if ([value isKindOfClass:[NSString class]])
    {
      NSString *name = [[value stringByTrimmingCharactersInSet:
	[NSCharacterSet whitespaceCharacterSet]] lowercaseString];

      if ([name isEqualToString:@"left"])
	{
	  *placement = DockPlacementLeftTop;
	  return YES;
	}
      if ([name isEqualToString:@"right"])
	{
	  *placement = DockPlacementRightTop;
	  return YES;
	}
      if ([name isEqualToString:@"top"])
	{
	  *placement = DockPlacementTopCenter;
	  return YES;
	}
      if ([name isEqualToString:@"bottom"])
	{
	  *placement = DockPlacementBottomCenter;
	  return YES;
	}
      if ([name length] == 0 ||
	  [name rangeOfCharacterFromSet:
	    [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location
	  != NSNotFound)
	{
	  return NO;
	}
    }
  else if (![value isKindOfClass:[NSNumber class]])
    {
      return NO;
    }
  number = [value integerValue];
  if (number < DockPlacementLeftTop || number > DockPlacementBottomCenter)
    {
      return NO;
    }
  *placement = (DockPlacement)number;
  return YES;
}

+ (NSColor *) calibratedBackgroundColor: (NSColor *)color
{
  NSColor *rgbColor = nil;
  CGFloat red = 0.0;
  CGFloat green = 0.0;
  CGFloat blue = 0.0;
  CGFloat alpha = 1.0;

  if (!color)
    {
      return [NSColor blackColor];
    }

  NS_DURING
    rgbColor = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  if (!rgbColor)
    {
      rgbColor = [color colorUsingColorSpaceName:NSDeviceRGBColorSpace];
    }
  if (rgbColor)
    {
      [rgbColor getRed:&red green:&green blue:&blue alpha:&alpha];
    }
  NS_HANDLER
    rgbColor = nil;
  NS_ENDHANDLER

    if (!rgbColor)
      {
	return [NSColor blackColor];
      }

  return [NSColor colorWithCalibratedRed:red
                                   green:green
                                    blue:blue
                                   alpha:alpha];
}

- (DockPlacement) savedDockPlacement
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  DockPlacement placement;

  if (placementFromDefault([defaults objectForKey:@"DockPlacement"], &placement))
    {
      return placement;
    }

  if ([defaults boolForKey:@"DockOnRight"])
    {
      return [defaults boolForKey:@"DockCentered"] ? DockPlacementRightCenter : DockPlacementRightTop;
    }

  return [defaults boolForKey:@"DockCentered"] ? DockPlacementLeftCenter : DockPlacementLeftTop;
}

/*
 * On WindowServer the Dock fills a whole screen edge, from the desktop
 * setting NBDockPosition, looked up as nextbsd-theme's
 * NBDesktopSettings.h does (keep them in step). It's kept per window
 * mode (NBWindowMode: stacking, tiling): the user's choice for the mode
 * (NBModeSettings[mode] in NSGlobalDomain, which Workspace Preferences
 * writes; in stacking, a plain NBDockPosition from before counts too),
 * then the active theme's NBModeDefaults[mode], then its plain
 * NBDockPosition, then the right edge. DockPlacement stays X11's
 * (Gershwin's); WindowServer ignores it and X11's DockOnRight and
 * DockCentered.
 */
static id
modeValue(id modes, NSString *mode, NSString *key)
{
  id entry;

  if (![modes isKindOfClass:[NSDictionary class]])
    {
      return nil;
    }
  entry = [modes objectForKey:mode];
  if (![entry isKindOfClass:[NSDictionary class]])
    {
      return nil;
    }
  return [entry objectForKey:key];
}

+ (NSString *) windowMode
{
  NSArray *modes = [NSArray arrayWithObjects:@"stacking", @"tiling", nil];
  id mode = [[NSUserDefaults standardUserDefaults]
	      objectForKey:DockWindowModeDefaultsKey];

  if ([mode isKindOfClass:[NSString class]] && [modes containsObject:mode])
    {
      return mode;
    }
  mode = [[[GSTheme theme] infoDictionary]
	   objectForKey:DockWindowModeDefaultsKey];
  if ([mode isKindOfClass:[NSString class]] && [modes containsObject:mode])
    {
      return mode;
    }
  return @"stacking";
}

- (DockPlacement) savedWindowServerDockPlacement
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDictionary *info = [[GSTheme theme] infoDictionary];
  NSString *mode = [DockPreferences windowMode];
  DockPlacement placement;

  if ([DockPreferences placement:&placement
		 forDockPosition:modeValue([defaults objectForKey:DockModeSettingsKey],
					   mode, DockPositionDefaultsKey)])
    {
      return placement;
    }
  if ([mode isEqual:@"stacking"]
      && [DockPreferences placement:&placement
		    forDockPosition:[defaults objectForKey:DockPositionDefaultsKey]])
    {
      return placement;
    }
  if ([DockPreferences placement:&placement
		 forDockPosition:modeValue([info objectForKey:DockModeDefaultsKey],
					   mode, DockPositionDefaultsKey)])
    {
      return placement;
    }
  if ([DockPreferences placement:&placement
		 forDockPosition:[info objectForKey:DockPositionDefaultsKey]])
    {
      return placement;
    }
  return DockPlacementRightTop;
}

- (void) saveDockPlacement: (DockPlacement)placement
{
  [[NSUserDefaults standardUserDefaults] setInteger:placement
					     forKey:@"DockPlacement"];
}

- (void) saveDockPosition: (DockPlacement)placement
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDictionary *existing = [defaults persistentDomainForName:NSGlobalDomain];
  NSMutableDictionary *domain = existing
    ? [NSMutableDictionary dictionaryWithDictionary:existing]
    : [NSMutableDictionary dictionary];
  NSString *position = dockPositionForPlacement(placement);
  NSMutableDictionary *modes = [NSMutableDictionary dictionary];
  NSMutableDictionary *entry;
  NSString *mode = [DockPreferences windowMode];
  id saved = [domain objectForKey:DockModeSettingsKey];
  id legacy = [domain objectForKey:DockPositionDefaultsKey];
  DockPlacement legacyPlacement;
  NSEnumerator *e;
  id key;

  /* The choice is the current window mode's, in NBModeSettings. A plain
   * NBDockPosition from before was the stacking one: it moves there. */
  if ([saved isKindOfClass:[NSDictionary class]])
    {
      e = [saved keyEnumerator];
      while ((key = [e nextObject]) != nil)
	{
	  if ([[saved objectForKey:key] isKindOfClass:[NSDictionary class]])
	    {
	      [modes setObject:[[[saved objectForKey:key] mutableCopy] autorelease]
			forKey:key];
	    }
	}
    }
  if ([DockPreferences placement:&legacyPlacement forDockPosition:legacy])
    {
      entry = [modes objectForKey:@"stacking"];
      if (entry == nil)
	{
	  entry = [NSMutableDictionary dictionary];
	  [modes setObject:entry forKey:@"stacking"];
	}
      if ([entry objectForKey:DockPositionDefaultsKey] == nil)
	{
	  [entry setObject:legacy forKey:DockPositionDefaultsKey];
	}
    }
  [domain removeObjectForKey:DockPositionDefaultsKey];
  entry = [modes objectForKey:mode];
  if (entry == nil)
    {
      entry = [NSMutableDictionary dictionary];
      [modes setObject:entry forKey:mode];
    }
  [entry setObject:position forKey:DockPositionDefaultsKey];
  [domain setObject:modes forKey:DockModeSettingsKey];
  [defaults setPersistentDomain:domain forName:NSGlobalDomain];
  [defaults synchronize];

  NS_DURING
    [[NSDistributedNotificationCenter defaultCenter]
      postNotificationName:DockDesktopSettingsChangedNotification
		    object:nil
		  userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
					   DockPositionDefaultsKey, @"key",
					 position, @"value", nil]
	deliverImmediately:YES];
  NS_HANDLER
    NSLog(@"DockWM: can't post %@: %@",
	  DockDesktopSettingsChangedNotification, [localException reason]);
  NS_ENDHANDLER
}

- (NSColor *) savedBackgroundColor
{
  id savedColor = [[NSUserDefaults standardUserDefaults]
		    objectForKey:DockBackgroundColorDefaultsKey];
  NSColor *color = nil;

  if ([savedColor isKindOfClass:[NSDictionary class]])
    {
      NSNumber *red = [savedColor objectForKey:@"Red"];
      NSNumber *green = [savedColor objectForKey:@"Green"];
      NSNumber *blue = [savedColor objectForKey:@"Blue"];
      NSNumber *alpha = [savedColor objectForKey:@"Alpha"];

      if (red && green && blue)
        {
          color = [NSColor colorWithCalibratedRed:[red doubleValue]
                                            green:[green doubleValue]
                                             blue:[blue doubleValue]
                                            alpha:alpha ? [alpha doubleValue] : 1.0];
        }
    }
  else if ([savedColor isKindOfClass:[NSData class]])
    {
      NS_DURING
        color = [NSUnarchiver unarchiveObjectWithData:savedColor];
      NS_HANDLER
        color = nil;
      NS_ENDHANDLER
	}

  return [DockPreferences calibratedBackgroundColor:color];
}

- (void) saveBackgroundColor: (NSColor *)backgroundColor
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSColor *color = [DockPreferences calibratedBackgroundColor:backgroundColor];
  NSMutableDictionary *components = [NSMutableDictionary dictionary];
  CGFloat red = 0.0;
  CGFloat green = 0.0;
  CGFloat blue = 0.0;
  CGFloat alpha = 1.0;

  [color getRed:&red green:&green blue:&blue alpha:&alpha];
  [components setObject:[NSNumber numberWithDouble:red] forKey:@"Red"];
  [components setObject:[NSNumber numberWithDouble:green] forKey:@"Green"];
  [components setObject:[NSNumber numberWithDouble:blue] forKey:@"Blue"];
  [components setObject:[NSNumber numberWithDouble:alpha] forKey:@"Alpha"];
  [defaults setObject:components forKey:DockBackgroundColorDefaultsKey];
}

- (CGFloat) savedWindowAlpha
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  id savedAlpha = [defaults objectForKey:DockWindowAlphaDefaultsKey];
  CGFloat alpha;

  if (!savedAlpha)
    {
      return 1.0;
    }

  alpha = [defaults floatForKey:DockWindowAlphaDefaultsKey];
  if (alpha < 0.0)
    {
      alpha = 0.0;
    }
  else if (alpha > 1.0)
    {
      alpha = 1.0;
    }

  return alpha;
}

- (void) saveWindowAlpha: (CGFloat)alpha
{
  [[NSUserDefaults standardUserDefaults] setFloat:alpha
					   forKey:DockWindowAlphaDefaultsKey];
}

- (BOOL) savedShowDockBorder
{
  return [[NSUserDefaults standardUserDefaults]
	   boolForKey:DockShowBorderDefaultsKey];
}

- (void) saveShowDockBorder: (BOOL)showDockBorder
{
  [[NSUserDefaults standardUserDefaults] setBool:showDockBorder
					  forKey:DockShowBorderDefaultsKey];
}

- (NSInteger) savedDockCellSizeMode
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  id savedMode = [defaults objectForKey:DockCellSizeModeDefaultsKey];

  if (savedMode)
    {
      NSInteger mode = [defaults integerForKey:DockCellSizeModeDefaultsKey];
      if (mode == DockCellSizeModeCurrent || mode == DockCellSizeMode64)
	{
	  return mode;
	}
    }

  return DockCellSizeMode64;
}

- (void) saveDockCellSizeMode: (NSInteger)mode
{
  [[NSUserDefaults standardUserDefaults] setInteger:mode
					     forKey:DockCellSizeModeDefaultsKey];
}

- (DockRunningIndicatorMode) savedRunningIndicatorMode
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  id savedMode = [defaults objectForKey:DockRunningIndicatorModeDefaultsKey];

  if (savedMode)
    {
      NSInteger mode = [defaults integerForKey:DockRunningIndicatorModeDefaultsKey];
      if (mode == DockRunningIndicatorModeNotRunningDots)
	{
	  return DockRunningIndicatorModeNotRunningDots;
	}
    }

  return DockRunningIndicatorModeRunningDot;
}

- (void) saveRunningIndicatorMode: (DockRunningIndicatorMode)mode
{
  [[NSUserDefaults standardUserDefaults] setInteger:mode
					     forKey:DockRunningIndicatorModeDefaultsKey];
}

- (BOOL) savedUseCellTileBackground
{
  return [[NSUserDefaults standardUserDefaults]
	   boolForKey:DockUseCellTileBackgroundDefaultsKey];
}

- (void) saveUseCellTileBackground: (BOOL)useCellTileBackground
{
  [[NSUserDefaults standardUserDefaults] setBool:useCellTileBackground
					  forKey:DockUseCellTileBackgroundDefaultsKey];
}

- (BOOL) savedMagnifiesHoveredIcons
{
  return [[NSUserDefaults standardUserDefaults]
	   boolForKey:DockMagnifiesHoveredIconsDefaultsKey];
}

- (void) saveMagnifiesHoveredIcons: (BOOL)magnifiesHoveredIcons
{
  [[NSUserDefaults standardUserDefaults] setBool:magnifiesHoveredIcons
					  forKey:DockMagnifiesHoveredIconsDefaultsKey];
}

- (NSTimeInterval) savedTooltipDelay
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if (![defaults objectForKey:@"DockTooltipDelay"])
    {
      return 0.25;
    }
  return MIN(2.0, MAX(0.0, [defaults doubleForKey:@"DockTooltipDelay"]));
}

- (void) saveTooltipDelay: (NSTimeInterval)delay
{
  [[NSUserDefaults standardUserDefaults] setDouble:MIN(2.0, MAX(0.0, delay))
                                           forKey:@"DockTooltipDelay"];
}

- (CGFloat) savedHoverIconScale
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  id savedScale = [defaults objectForKey:DockHoverIconScaleDefaultsKey];
  CGFloat scale;

  if (!savedScale)
    {
      return 1.2;
    }

  scale = [defaults floatForKey:DockHoverIconScaleDefaultsKey];
  if (scale < 1.0)
    {
      scale = 1.0;
    }
  else if (scale > 1.5)
    {
      scale = 1.5;
    }

  return scale;
}

- (void) saveHoverIconScale: (CGFloat)scale
{
  if (scale < 1.0)
    {
      scale = 1.0;
    }
  else if (scale > 1.5)
    {
      scale = 1.5;
    }

  [[NSUserDefaults standardUserDefaults] setFloat:scale
					   forKey:DockHoverIconScaleDefaultsKey];
}

- (BOOL) savedWigglesOnLaunch
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  if (![defaults objectForKey:DockWigglesOnLaunchDefaultsKey])
    {
      return YES;
    }

  return [defaults boolForKey:DockWigglesOnLaunchDefaultsKey];
}

- (void) saveWigglesOnLaunch: (BOOL)wiggles
{
  [[NSUserDefaults standardUserDefaults] setBool:wiggles
					  forKey:DockWigglesOnLaunchDefaultsKey];
}

- (BOOL) savedWigglesOnActivation
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  if (![defaults objectForKey:DockWigglesOnActivationDefaultsKey])
    {
      return YES;
    }

  return [defaults boolForKey:DockWigglesOnActivationDefaultsKey];
}

- (void) saveWigglesOnActivation: (BOOL)wiggles
{
  [[NSUserDefaults standardUserDefaults] setBool:wiggles
					  forKey:DockWigglesOnActivationDefaultsKey];
}

- (BOOL) savedWigglesOnAttentionRequest
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  if (![defaults objectForKey:DockWigglesOnAttentionRequestDefaultsKey])
    {
      return YES;
    }

  return [defaults boolForKey:DockWigglesOnAttentionRequestDefaultsKey];
}

- (void) saveWigglesOnAttentionRequest: (BOOL)wiggles
{
  [[NSUserDefaults standardUserDefaults] setBool:wiggles
					  forKey:DockWigglesOnAttentionRequestDefaultsKey];
}

- (BOOL) savedPlaysSoundOnRemove
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  if (![defaults objectForKey:DockPlaysSoundOnRemoveDefaultsKey])
    {
      return YES;
    }

  return [defaults boolForKey:DockPlaysSoundOnRemoveDefaultsKey];
}

- (void) savePlaysSoundOnRemove: (BOOL)playsSound
{
  [[NSUserDefaults standardUserDefaults] setBool:playsSound
					  forKey:DockPlaysSoundOnRemoveDefaultsKey];
}

- (BOOL) savedSingleClickLaunchesApplications
{
  return [[NSUserDefaults standardUserDefaults]
	   boolForKey:DockSingleClickLaunchesApplicationsDefaultsKey];
}

- (void) saveSingleClickLaunchesApplications: (BOOL)singleClickLaunches
{
  [[NSUserDefaults standardUserDefaults] setBool:singleClickLaunches
					  forKey:DockSingleClickLaunchesApplicationsDefaultsKey];
}

- (void) applyIconManagerPreference
{
  [self saveUsesIconManager:[self savedUsesIconManager]];
}

- (BOOL) savedUsesIconManager
{
  NSDictionary *domain = [[NSUserDefaults standardUserDefaults]
    persistentDomainForName:NSGlobalDomain];
  id value = [domain objectForKey:@"GSUseIconManager"];

  return value == nil || [value boolValue];
}

- (void) saveUsesIconManager: (BOOL)useIconManager
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDictionary *existing = [defaults persistentDomainForName:NSGlobalDomain];
  NSMutableDictionary *domain = existing
    ? [NSMutableDictionary dictionaryWithDictionary:existing]
    : [NSMutableDictionary dictionary];

  [domain setObject:[NSNumber numberWithBool:useIconManager]
            forKey:@"GSUseIconManager"];
  [defaults setPersistentDomain:domain forName:NSGlobalDomain];
  [defaults synchronize];
}

- (NSNumber *) iconManagerOverrideForDomain: (NSString *)domain
{
  if (![domain length])
    {
      return nil;
    }
  return [[[NSUserDefaults standardUserDefaults] persistentDomainForName:domain]
    objectForKey:@"GSUseIconManager"];
}

- (void) setIconManagerOverride: (NSNumber *)value forDomain: (NSString *)domain
{
  NSUserDefaults *defaults;
  NSDictionary *existing;
  NSMutableDictionary *values;

  if (![domain length] || [domain isEqual:NSGlobalDomain])
    {
      return;
    }
  defaults = [NSUserDefaults standardUserDefaults];
  [defaults synchronize];
  existing = [defaults persistentDomainForName:domain];
  values = existing ? [NSMutableDictionary dictionaryWithDictionary:existing]
    : [NSMutableDictionary dictionary];
  if (value != nil)
    {
      [values setObject:value forKey:@"GSUseIconManager"];
    }
  else
    {
      [values removeObjectForKey:@"GSUseIconManager"];
    }
  [defaults setPersistentDomain:values forName:domain];
  [defaults synchronize];
}

- (BOOL) savedHidesMiniwindows
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  if (![defaults objectForKey:DockHidesMiniwindowsDefaultsKey])
    {
      return YES;
    }

  return [defaults boolForKey:DockHidesMiniwindowsDefaultsKey];
}

- (void) saveHidesMiniwindows: (BOOL)hidesMiniwindows
{
  [[NSUserDefaults standardUserDefaults] setBool:hidesMiniwindows
					  forKey:DockHidesMiniwindowsDefaultsKey];
}

- (CGFloat) savedDockScale
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  CGFloat scale;

  if (![defaults objectForKey:DockScaleDefaultsKey])
    {
      return 1.0;
    }

  scale = [defaults floatForKey:DockScaleDefaultsKey];
  return MIN(1.5, MAX(0.5, scale));
}

- (void) saveDockScale: (CGFloat)scale
{
  [[NSUserDefaults standardUserDefaults] setFloat:MIN(1.5, MAX(0.5, scale))
					   forKey:DockScaleDefaultsKey];
}

- (BOOL) savedKeepsMissingApplications
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  return [defaults objectForKey:@"DockKeepsMissingApplications"] == nil ||
    [defaults boolForKey:@"DockKeepsMissingApplications"];
}

- (void) saveKeepsMissingApplications: (BOOL)keep
{
  [[NSUserDefaults standardUserDefaults] setBool:keep
                                        forKey:@"DockKeepsMissingApplications"];
}

- (BOOL) savedAllowsGaps
{
  return [[NSUserDefaults standardUserDefaults] boolForKey:@"DockAllowsGaps"];
}

- (void) saveAllowsGaps: (BOOL)allows
{
  [[NSUserDefaults standardUserDefaults] setBool:allows forKey:@"DockAllowsGaps"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
