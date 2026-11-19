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
 * The sound Dock extra: a speaker showing the volume and mute of the
 * output the system plays to: a kernel device (pcmN, through its mixer)
 * or a Bluetooth headset (through bluetoothd and its virtual_oss), the
 * way Sound.app (nextbsd/apps-settings) reads them, with the same code
 * (SNAudio.c, copied from it).
 *
 * A click opens a small panel with a volume slider, Mute and the output
 * device; the right-click menu has Mute, volume steps, the outputs and
 * Open Sound Settings.... Scrolling over the tile changes the volume. A
 * headset's volume is its own (AVRCP absolute volume), as on macOS.
 *
 * The extra shows whenever there's an output, a headset included, as on
 * a laptop whose only sound is Bluetooth. bluetoothd's notifications
 * bring headsets at once; OSS posts nothing, so the volume is read
 * every 1.5 seconds, and with no output the devices are looked for
 * every 10 seconds. A headset's mixer that stops answering (the headset
 * went away) is never waited on: SNAudio gives up on it in 400 ms.
 */

#import <AppKit/AppKit.h>
#import <GNUstepBase/GNUstep.h>
#import "DockExtra.h"
#import "SNAudio.h"

#include <sys/types.h>
#include <sys/sysctl.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <unistd.h>

#define DockSoundPollInterval 1.5
#define DockSoundSearchInterval 10.0
#define DockSoundDevicesEvery 4		/* polls between device reads */
#define DockSoundStep 5

@interface DockSoundExtra : NSObject <DockExtra>
{
  id <DockExtraHost> _host;
  SNAudio *_audio;
  SNAudioDevice _devices[SNAudioMaxDevices];
  int _count;
  int _output;			/* index into _devices, or -1 */
  int _volume;
  BOOL _muted;
  BOOL _hasVolume;		/* the output's volume can be read */
  unsigned _polls;
  int _pipe[2];
  NSFileHandle *_handle;
  NSTimer *_timer;
  NSPanel *_panel;
  NSSlider *_slider;
  NSButton *_muteButton;
  NSPopUpButton *_outputPopup;
}
- (void) update: (NSTimer *)timer;
- (void) reloadDevices;
- (void) setMuted: (BOOL)muted;
- (void) fillOutputPopup;
@end

static NSArray *
DockSoundRunLoopModes(void)
{
  return [NSArray arrayWithObjects:NSDefaultRunLoopMode,
		  NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode, nil];
}

static NSString *
DockSoundName(const SNAudioDevice *device)
{
  NSString *name = [NSString stringWithUTF8String:device->name];

  return name ? name : @"";
}

@implementation DockSoundExtra

- (id) initWithDockHost: (id <DockExtraHost>)host
{
  self = [super init];
  if (self)
    {
      NSUInteger i;

      _host = host;
      _output = -1;
      _pipe[0] = _pipe[1] = -1;
      if (pipe(_pipe) == 0)
	{
	  for (i = 0; i < 2; i++)
	    {
	      (void)fcntl(_pipe[i], F_SETFL,
			  fcntl(_pipe[i], F_GETFL) | O_NONBLOCK);
	      (void)fcntl(_pipe[i], F_SETFD, FD_CLOEXEC);
	    }
	  _handle = [[NSFileHandle alloc] initWithFileDescriptor:_pipe[0]
						  closeOnDealloc:NO];
	  [[NSNotificationCenter defaultCenter]
	    addObserver:self
	       selector:@selector(bluetoothChanged:)
		   name:NSFileHandleDataAvailableNotification
		 object:_handle];
	  [_handle waitForDataInBackgroundAndNotifyForModes:
		     DockSoundRunLoopModes()];
	}
      else
	{
	  NSLog(@"Sound extra: no pipe for notifications: %s",
		strerror(errno));
	}
      /* bluetoothd's audio and device notifications write a byte to
       * the pipe; without one the regular looks still run. */
      _audio = SNAudioOpen(_pipe[1]);
      [self reloadDevices];
      [self update:nil];
    }
  return self;
}

- (void) dockExtraWillUnload
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_timer invalidate];
  DESTROY(_timer);
  [_panel close];
  DESTROY(_panel);
  DESTROY(_slider);
  DESTROY(_muteButton);
  DESTROY(_outputPopup);
  if (_audio)
    {
      /* Waits out a notification being handled, so the pipe can go. */
      SNAudioClose(_audio);
      _audio = NULL;
    }
  [_handle closeFile];
  DESTROY(_handle);
  if (_pipe[1] >= 0)
    {
      close(_pipe[1]);
    }
  _pipe[0] = _pipe[1] = -1;
  _host = nil;
}

- (void) dealloc
{
  [self dockExtraWillUnload];
  DEALLOC;
}

- (SNAudioDevice *) output
{
  return _output >= 0 && _output < _count ? &_devices[_output] : NULL;
}

/* ---- reading the devices ---- */

- (void) bluetoothChanged: (NSNotification *)notification
{
  char buffer[256];

  while (_pipe[0] >= 0 && read(_pipe[0], buffer, sizeof(buffer)) > 0)
    {
    }
  [self reloadDevices];
  [self update:nil];
  [_handle waitForDataInBackgroundAndNotifyForModes:
	     DockSoundRunLoopModes()];
}

- (void) reloadDevices
{
  if (_audio == NULL)
    {
      return;
    }
  _count = SNAudioCopyDevices(_audio, _devices, SNAudioMaxDevices);
  _output = SNAudioDefaultOutput(_devices, _count);
}

- (void) scheduleUpdate
{
  NSTimeInterval interval = [self isAvailable] ? DockSoundPollInterval
    : DockSoundSearchInterval;

  if (_timer && [_timer timeInterval] == interval)
    {
      return;
    }
  [_timer invalidate];
  DESTROY(_timer);
  _timer = RETAIN([NSTimer timerWithTimeInterval:interval
					  target:self
					selector:@selector(update:)
					userInfo:nil
					 repeats:YES]);
  [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSDefaultRunLoopMode];
  [[NSRunLoop currentRunLoop] addTimer:_timer
			       forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSModalPanelRunLoopMode];
}

- (void) updateControls
{
  SNAudioDevice *output = [self output];

  if (!_panel)
    {
      return;
    }
  [_slider setIntValue:_volume];
  [_slider setEnabled:_hasVolume && output && SNAudioOutputHasVolume(output)];
  [_muteButton setState:_muted ? NSOnState : NSOffState];
  [_muteButton setEnabled:_hasVolume];
}

- (void) update: (NSTimer *)timer
{
  BOOL wasAvailable = [self isAvailable];
  SNAudioDevice *output;
  int volume = 0, muted = 0;
  BOOL hasVolume;

  /* With no output, every look reads the devices; with one, every few
   * (bluetoothd's notifications bring headsets at once anyway). */
  if (timer != nil && (!wasAvailable || ++_polls % DockSoundDevicesEvery == 0))
    {
      [self reloadDevices];
    }
  output = [self output];
  hasVolume = output != NULL
    && SNAudioGetOutputVolume(_audio, output, &volume, &muted) == 0;
  if (output != NULL && !hasVolume && errno != ETIMEDOUT && errno != EBUSY)
    {
      /* Gone, not just slow: look again now. */
      [self reloadDevices];
      output = [self output];
      hasVolume = output != NULL
	&& SNAudioGetOutputVolume(_audio, output, &volume, &muted) == 0;
    }
  [self scheduleUpdate];
  if ([self isAvailable] != wasAvailable)
    {
      [_host dockExtraAvailabilityDidChange:self];
    }
  if (!hasVolume)
    {
      volume = 0;
      muted = 0;
    }
  if (volume != _volume || (muted != 0) != _muted || hasVolume != _hasVolume)
    {
      _volume = volume;
      _muted = muted != 0;
      _hasVolume = hasVolume;
      [self updateControls];
      [_host dockExtraNeedsDisplay:self];
    }
}

/* ---- changing them ---- */

- (void) setVolume: (int)volume
{
  SNAudioDevice *output = [self output];

  if (output == NULL)
    {
      return;
    }
  volume = MAX(0, MIN(100, volume));
  if (SNAudioSetOutputVolume(_audio, output, volume) != 0)
    {
      NSLog(@"Sound extra: can't set the volume of %@ (%s)",
	    DockSoundName(output), strerror(errno));
      return;
    }
  /* Changing the volume unmutes, as on macOS. */
  if (_muted)
    {
      [self setMuted:NO];
    }
  [self update:nil];
}

- (void) setMuted: (BOOL)muted
{
  SNAudioDevice *output = [self output];

  if (output == NULL || SNAudioSetOutputMuted(_audio, output, muted) != 0)
    {
      NSLog(@"Sound extra: can't set mute (%s)", strerror(errno));
      return;
    }
  _muted = muted;
  [self updateControls];
  [_host dockExtraNeedsDisplay:self];
}

- (BOOL) isAvailable
{
  int i;

  for (i = 0; i < _count; i++)
    {
      if (_devices[i].play)
	{
	  return YES;
	}
    }
  return NO;
}

/* A speaker, with up to three waves for the volume, or a cross when
 * muted. */
- (void) drawInRect: (NSRect)rect
{
  NSRect plate = DockExtraPlateRect(rect);
  CGFloat s = NSWidth(plate);
  CGFloat x = NSMinX(plate) + s * 0.18;
  CGFloat y = NSMidY(plate);
  NSBezierPath *speaker = [NSBezierPath bezierPath];
  NSColor *white = DockExtraForegroundColor(NO);
  NSInteger waves = _muted || _volume == 0 ? 0
    : (_volume < 34 ? 1 : (_volume < 67 ? 2 : 3));
  NSInteger i;

  DockExtraDrawPlate(rect);
  [speaker moveToPoint:NSMakePoint(x, y - s * 0.09)];
  [speaker lineToPoint:NSMakePoint(x + s * 0.12, y - s * 0.09)];
  [speaker lineToPoint:NSMakePoint(x + s * 0.27, y - s * 0.22)];
  [speaker lineToPoint:NSMakePoint(x + s * 0.27, y + s * 0.22)];
  [speaker lineToPoint:NSMakePoint(x + s * 0.12, y + s * 0.09)];
  [speaker lineToPoint:NSMakePoint(x, y + s * 0.09)];
  [speaker closePath];
  [(_muted ? DockExtraForegroundColor(YES) : white) set];
  [speaker fill];
  if (_muted)
    {
      NSBezierPath *cross = [NSBezierPath bezierPath];
      CGFloat cx = x + s * 0.47;
      CGFloat r = s * 0.11;

      [cross moveToPoint:NSMakePoint(cx - r, y - r)];
      [cross lineToPoint:NSMakePoint(cx + r, y + r)];
      [cross moveToPoint:NSMakePoint(cx - r, y + r)];
      [cross lineToPoint:NSMakePoint(cx + r, y - r)];
      [cross setLineWidth:MAX(1.5, s * 0.05)];
      [cross setLineCapStyle:NSRoundLineCapStyle];
      [white set];
      [cross stroke];
    }
  for (i = 0; i < 3; i++)
    {
      NSBezierPath *wave = [NSBezierPath bezierPath];
      CGFloat radius = s * (0.12 + 0.11 * i);

      [wave appendBezierPathWithArcWithCenter:NSMakePoint(x + s * 0.27, y)
				       radius:radius
				   startAngle:-45.0
				     endAngle:45.0];
      [wave setLineWidth:MAX(1.5, s * 0.05)];
      [wave setLineCapStyle:NSRoundLineCapStyle];
      if (i < waves)
	{
	  [white set];
	  [wave stroke];
	}
      else if (!_muted)
	{
	  [DockExtraForegroundColor(YES) set];
	  [wave stroke];
	}
    }
}

- (NSString *) toolTip
{
  SNAudioDevice *output = [self output];
  NSString *volume;

  if (output == NULL)
    {
      return @"No sound output";
    }
  if (!_hasVolume)
    {
      return [NSString stringWithFormat:@"%@: not answering",
		       DockSoundName(output)];
    }
  volume = _muted ? [NSString stringWithFormat:@"muted (%d%%)", _volume]
    : [NSString stringWithFormat:@"%d%%", _volume];
  /* Say which output when it isn't obvious: a headset, or one of
   * several. */
  if (output->kind == SNAudioBluetooth || _count > 1)
    {
      return [NSString stringWithFormat:@"Volume: %@ (%@)", volume,
		       DockSoundName(output)];
    }
  return [NSString stringWithFormat:@"Volume: %@", volume];
}

- (void) scrollWheel: (NSEvent *)event
{
  CGFloat delta = [event deltaY];
  int steps = (int)MIN(4.0, MAX(1.0, rint(fabs(delta))));

  if (delta > 0.0)
    {
      [self setVolume:_volume + DockSoundStep * steps];
    }
  else if (delta < 0.0)
    {
      [self setVolume:_volume - DockSoundStep * steps];
    }
}

- (void) volumeChanged: (id)sender
{
  [self setVolume:[sender intValue]];
}

- (void) muteChanged: (id)sender
{
  [self setMuted:[sender state] == NSOnState];
}

- (void) toggleMute: (id)sender
{
  [self setMuted:!_muted];
}

- (void) chooseVolume: (id)sender
{
  [self setVolume:(int)[sender tag]];
}

/* Only a kernel device can be chosen, by setting hw.snd.default_unit,
 * which needs root for now; a headset takes the output by itself when it
 * connects. The tag is the device's index. */
- (void) chooseOutput: (id)sender
{
  int index = (int)[([sender isKindOfClass:[NSPopUpButton class]]
		     ? [sender selectedItem] : sender) tag];
  int unit;

  if (index < 0 || index >= _count || index == _output
      || _devices[index].kind != SNAudioKernel)
    {
      return;
    }
  unit = _devices[index].unit;
  if (sysctlbyname("hw.snd.default_unit", NULL, NULL, &unit, sizeof(unit)) != 0)
    {
      NSLog(@"Sound extra: can't choose pcm%d as the output (%s)",
	    unit, strerror(errno));
      NSBeep();
    }
  [self reloadDevices];
  [self update:nil];
  [self fillOutputPopup];
}

/* Can the output be switched to device i from here? */
- (BOOL) canChoose: (int)i
{
  SNAudioDevice *output = [self output];

  return i == _output
    || (geteuid() == 0 && _devices[i].kind == SNAudioKernel
	&& (output == NULL || output->kind == SNAudioKernel));
}

- (void) fillOutputPopup
{
  BOOL choosable = NO;
  int i;

  [_outputPopup removeAllItems];
  for (i = 0; i < _count; i++)
    {
      if (!_devices[i].play)
	{
	  continue;
	}
      [_outputPopup addItemWithTitle:DockSoundName(&_devices[i])];
      [[_outputPopup lastItem] setTag:i];
      if (i == _output)
	{
	  [_outputPopup selectItem:[_outputPopup lastItem]];
	}
      if (i != _output && [self canChoose:i])
	{
	  choosable = YES;
	}
    }
  if ([_outputPopup numberOfItems] == 0)
    {
      [_outputPopup addItemWithTitle:@"No output"];
    }
  [_outputPopup setEnabled:choosable];
}

- (void) makePanel
{
  NSView *content;
  NSTextField *label;

  _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 240, 118)
				      styleMask:NSTitledWindowMask
					     | NSClosableWindowMask
					     | NSUtilityWindowMask
					backing:NSBackingStoreBuffered
					  defer:NO];
  [_panel setTitle:@"Sound"];
  [_panel setReleasedWhenClosed:NO];
  [_panel setHidesOnDeactivate:YES];
  [_panel setFloatingPanel:YES];
  content = [_panel contentView];

  label = AUTORELEASE([[NSTextField alloc]
			initWithFrame:NSMakeRect(12, 86, 216, 18)]);
  [label setStringValue:@"Output volume"];
  [label setEditable:NO];
  [label setSelectable:NO];
  [label setBezeled:NO];
  [label setDrawsBackground:NO];
  [content addSubview:label];

  _slider = [[NSSlider alloc] initWithFrame:NSMakeRect(12, 62, 216, 22)];
  [_slider setMinValue:0.0];
  [_slider setMaxValue:100.0];
  [_slider setContinuous:YES];
  [_slider setTarget:self];
  [_slider setAction:@selector(volumeChanged:)];
  [content addSubview:_slider];

  _muteButton = [[NSButton alloc] initWithFrame:NSMakeRect(12, 38, 216, 22)];
  [_muteButton setButtonType:NSSwitchButton];
  [_muteButton setTitle:@"Mute"];
  [_muteButton setTarget:self];
  [_muteButton setAction:@selector(muteChanged:)];
  [content addSubview:_muteButton];

  _outputPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(10, 8, 220, 26)
					    pullsDown:NO];
  [_outputPopup setTarget:self];
  [_outputPopup setAction:@selector(chooseOutput:)];
  [_outputPopup setToolTip:@"The output device. A Bluetooth headset takes "
		@"the output when it connects; choosing a built-in one needs "
		@"administrator rights."];
  [content addSubview:_outputPopup];
}

- (void) showPanel
{
  if ([_panel isVisible])
    {
      [_panel orderOut:self];
      return;
    }
  if (!_panel)
    {
      [self makePanel];
    }
  [self fillOutputPopup];
  [self updateControls];
  [_panel setFrame:[_host dockExtra:self panelFrameForSize:[_panel frame].size]
	   display:YES];
  [NSApp activateIgnoringOtherApps:YES];
  [_panel makeKeyAndOrderFront:self];
}

- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSMenu *menu;
  NSMenu *outputs;
  NSMenuItem *item;
  NSUInteger i;
  int steps[] = { 0, 25, 50, 75, 100 };
  int d, shown = 0;

  if ([event type] == NSLeftMouseDown)
    {
      [self showPanel];
      return nil;
    }
  menu = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Sound"]);
  [menu setAutoenablesItems:NO];
  item = (NSMenuItem *)[menu addItemWithTitle:[self toolTip] action:NULL
				 keyEquivalent:@""];
  [item setEnabled:NO];
  item = (NSMenuItem *)[menu addItemWithTitle:@"Mute"
				       action:@selector(toggleMute:)
				keyEquivalent:@""];
  [item setTarget:self];
  [item setState:_muted ? NSOnState : NSOffState];
  [item setEnabled:_hasVolume];
  [menu addItem:[NSMenuItem separatorItem]];
  for (i = 0; i < sizeof(steps) / sizeof(steps[0]); i++)
    {
      item = (NSMenuItem *)[menu addItemWithTitle:
				   [NSString stringWithFormat:@"Volume %d%%",
					     steps[i]]
					   action:@selector(chooseVolume:)
				    keyEquivalent:@""];
      [item setTarget:self];
      [item setTag:steps[i]];
      [item setEnabled:_hasVolume];
      [item setState:!_muted && abs(_volume - steps[i]) < 13
	    ? NSOnState : NSOffState];
    }
  outputs = AUTORELEASE([[NSMenu alloc] initWithTitle:@"Output"]);
  [outputs setAutoenablesItems:NO];
  for (d = 0; d < _count; d++)
    {
      if (!_devices[d].play)
	{
	  continue;
	}
      item = (NSMenuItem *)[outputs addItemWithTitle:DockSoundName(&_devices[d])
					      action:@selector(chooseOutput:)
				       keyEquivalent:@""];
      [item setTarget:self];
      [item setTag:d];
      [item setState:d == _output ? NSOnState : NSOffState];
      [item setEnabled:[self canChoose:d]];
      shown++;
    }
  if (shown)
    {
      [menu addItem:[NSMenuItem separatorItem]];
      item = (NSMenuItem *)[menu addItemWithTitle:@"Output" action:NULL
				    keyEquivalent:@""];
      [menu setSubmenu:outputs forItem:item];
    }
  DockExtraAddSettingsItem(menu, _host, @"Open Sound Settings…",
			   [NSArray arrayWithObject:@"Sound"]);
  return menu;
}

@end
