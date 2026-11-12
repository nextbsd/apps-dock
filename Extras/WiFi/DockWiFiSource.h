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
 * The Wi-Fi extra's data source: the State:/Network/Interface/<if>/AirPort
 * entries wland publishes in SystemConfiguration's dynamic store, watched
 * with SCDynamicStore notifications. A plain C interface, so that the
 * extra itself needn't see CoreFoundation's headers (GNUstep has its
 * own).
 */

#ifndef _DOCK_WIFI_SOURCE_H_
#define _DOCK_WIFI_SOURCE_H_

typedef struct
{
  char interface[16];
  int authenticated;	/* keyed: the 4-way handshake is done */
  char ssid[33];
  char bssid[18];
  int rssi;		/* dBm */
  int channel;
  char security[32];
} DockWiFiState;

/* Watch the AirPort entries: each change writes a byte to wakeFD (from
 * a dispatch queue). NULL if configd can't be reached. */
void *DockWiFiOpen(int wakeFD);
/* Fill up to max states, one per interface wland manages; returns how
 * many there are. */
int DockWiFiRead(void *store, DockWiFiState *states, int max);
void DockWiFiClose(void *store);

#endif
