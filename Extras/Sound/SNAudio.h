/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copied unchanged from Sound.app (nextbsd/apps-settings Sound/SNAudio.h,
 * b3d97c0): the sound extra reads and sets the devices the same way.
 * Copy it again when the app's changes.
 *
 * SNAudio: the computer's sound devices, as a plain C interface, so the
 * app needn't see Mach's headers (GNUstep has its own; see the
 * GNUmakefile). The Dock's sound extra (apps-dock Extras/Sound) carries
 * a copy of this file and SNAudio.c; keep the two in step.
 *
 * NextBSD has no audio daemon. A sound device is one of:
 *
 *   - a kernel device, pcmN in /dev/sndstat: its volume and mute are
 *     its mixer's (/dev/mixerN ioctls, as any user). /dev/dsp and
 *     /dev/mixer follow hw.snd.default_unit, which only root may set;
 *   - a Bluetooth headset: bluetoothd runs a virtual_oss for it, which
 *     makes /dev/dsp.btN (and, when the headset takes the default, a
 *     /dev/dsp of its own) and a control device /dev/dsp.btN.ctl. Its
 *     name, AVRCP absolute volume and microphone come from bluetoothd
 *     (bluetooth.defs 31080-31086). The volume is the headset's own
 *     (AVRCP SetAbsoluteVolume), as on macOS; mute, and the volume of a
 *     headset without absolute volume, are virtual_oss's (its control
 *     device's ioctls, <virtual_oss.h>). Its microphone is its
 *     hands-free link: bluetoothd points the virtual_oss's recording
 *     side at it (bt_audio_route 2) or at /dev/null (1, stereo);
 *   - another userspace device (/dev/sndstat's "from userspace"): it's
 *     listed, and controlled when it has a NAME.ctl control device.
 *
 * Live updates: bluetoothd's org.nextbsd.bluetooth.{audio,device}
 * notifications write a byte to the wake descriptor given to
 * SNAudioOpen. OSS posts nothing, so mixers are read again by polling.
 */

#ifndef _SN_AUDIO_H_
#define _SN_AUDIO_H_

#define SNAudioMaxDevices 32

/* What a device is. */
#define SNAudioKernel 0		/* pcmN */
#define SNAudioBluetooth 1	/* a headset, through bluetoothd */
#define SNAudioVirtual 2	/* another userspace device */

typedef struct
{
  char ident[32];		/* "pcm0", "dsp.bt0": unique, stable */
  char name[256];		/* "Realtek ALC257 (Analog)", the headset's */
  int kind;			/* SNAudio* */
  int unit;			/* pcmN's N; -1 */
  int play;			/* it's an output */
  int record;			/* it's an input (a headset: hands-free) */
  int defaultOut;		/* /dev/dsp plays to it */
  int defaultIn;		/* /dev/dsp records from it (and it's live) */
  char dsp[64];			/* "/dev/dsp0", "/dev/dsp.bt0" */
  char ctl[64];			/* virtual_oss's control device, or "" */

  /* A Bluetooth headset. */
  char address[32];		/* "F8:73:DF:DF:1F:E9" */
  int absoluteVolume;		/* AVRCP absolute volume, 0-127; -1 none */
  int handsFree;		/* its hands-free channel is up */
  int microphone;		/* its microphone is open (route 2) */
  int battery;			/* percent; -1 unknown */
  int linkUp;			/* connected; a headset that isn't has no
                                   play or record, and isn't listed */
} SNAudioDevice;

typedef struct SNAudio SNAudio;
typedef struct SNAudioMeter SNAudioMeter;

/* Start watching bluetoothd; wakeFD (or -1) gets a byte per change.
   Never NULL. */
SNAudio *SNAudioOpen (int wakeFD);
void SNAudioClose (SNAudio *audio);

/* Read every device again, outputs and inputs together, kernel devices
   first in unit order. Returns how many (at most max). */
int SNAudioCopyDevices (SNAudio *audio, SNAudioDevice *devices, int max);

/* The output the system plays to, from a list SNAudioCopyDevices made:
   the device with defaultOut, else -1. Likewise the input. */
int SNAudioDefaultOutput (const SNAudioDevice *devices, int count);
int SNAudioDefaultInput (const SNAudioDevice *devices, int count);

/* An output's volume (0-100) and mute. Each returns 0, or -1 with errno
   set (ENODEV: it has no control; ENOTCONN: bluetoothd isn't
   answering). */
int SNAudioGetOutputVolume (SNAudio *audio, const SNAudioDevice *device,
                            int *volume, int *muted);
int SNAudioSetOutputVolume (SNAudio *audio, SNAudioDevice *device,
                            int volume);
int SNAudioSetOutputMuted (SNAudio *audio, const SNAudioDevice *device,
                           int muted);
/* Whether the output's volume can be set at all, and whether in fine
   steps (a mixer, AVRCP) or only in 6 dB ones (virtual_oss's gain). */
int SNAudioOutputHasVolume (const SNAudioDevice *device);
int SNAudioOutputVolumeIsCoarse (const SNAudioDevice *device);

/* An input's gain (0-100): a kernel device's recording level. A
   headset's microphone gain is set on the headset, so ENODEV. */
int SNAudioGetInputVolume (SNAudio *audio, const SNAudioDevice *device,
                           int *volume);
int SNAudioSetInputVolume (SNAudio *audio, const SNAudioDevice *device,
                           int volume);

/* Open or close a headset's microphone (bt_audio_route: hands-free or
   stereo). Returns 0 or -1 with errno set. */
int SNAudioSetMicrophone (SNAudio *audio, const SNAudioDevice *device,
                          int on);

/* A live input level for a meter: open one per device shown, read it
   as often as the meter is drawn, close it when the meter is hidden.
   A kernel device is recorded from (its dsp, opened read-only); a
   headset's level is virtual_oss's input peak, which takes nothing
   from anyone recording. The level is the peak since the last read,
   0.0-1.0. */
SNAudioMeter *SNAudioMeterOpen (const SNAudioDevice *device);
float SNAudioMeterLevel (SNAudioMeter *meter);
void SNAudioMeterClose (SNAudioMeter *meter);

#endif
