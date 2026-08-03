/**
 * Ported from functions/src/youtubeSync.ts — same categorization rules,
 * same duration parsing, same live-detection logic. Kept deliberately
 * identical rather than "improved," so behavior doesn't silently drift
 * between the two implementations while both exist.
 */

import { FirestoreClient } from './firestoreClient';

const YT_BASE = 'https://www.googleapis.com/youtube/v3';
// Mirrors AppConfig.youtubeChannelId / functions/src/youtubeSync.ts's
// CHANNEL_ID — hand-synced across three places now (Dart, Cloud
// Function, this Worker). Same tradeoff already accepted in
// functions/src/config.ts's header comment: no cross-language codegen
// in this repo.
const CHANNEL_ID = 'UC4zsqN5YdXfxkkdVvwNA3JA';

const CATEGORY_KEYWORDS: Record<string, string[]> = {
  'Sunday Service': ['sunday', 'communion'],
  'Bible Study': ['bible study'],
  Revival: ['revival', 'crusade'],
  GCK: ['gck', 'global crusade'],
  'Impact Academy': ['impact academy', 'leadership training'],
  'Special Messages': ['special message', 'memorial', 'ordination'],
};

function categorize(title: string): string {
  const lower = title.toLowerCase();
  for (const [category, keywords] of Object.entries(CATEGORY_KEYWORDS)) {
    if (keywords.some((k) => lower.includes(k))) return category;
  }
  return 'Programs';
}

function parseIso8601Duration(iso?: string): number | null {
  if (!iso) return null;
  const match = iso.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/);
  if (!match) return null;
  const hours = parseInt(match[1] || '0', 10);
  const minutes = parseInt(match[2] || '0', 10);
  const seconds = parseInt(match[3] || '0', 10);
  return hours * 3600 + minutes * 60 + seconds;
}

function bestThumbnail(thumbnails: Record<string, { url?: string }> | undefined): string {
  if (!thumbnails) return '';
  for (const quality of ['maxres', 'high', 'medium', 'default']) {
    const t = thumbnails[quality];
    if (t?.url) return t.url;
  }
  return '';
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function videoEntryFromApiItem(item: any): Record<string, unknown> {
  const snippet = item.snippet ?? {};
  const contentDetails = item.contentDetails;
  const liveDetails = item.liveStreamingDetails;

  let liveStatus = 'none';
  if (liveDetails) {
    if (liveDetails.actualStartTime && !liveDetails.actualEndTime) {
      liveStatus = 'live';
    } else if (liveDetails.scheduledStartTime && !liveDetails.actualStartTime) {
      liveStatus = 'upcoming';
    }
  }

  return {
    video_id: item.id,
    title: snippet.title ?? 'Untitled',
    description: snippet.description ?? '',
    thumbnail_url: bestThumbnail(snippet.thumbnails),
    published_at: snippet.publishedAt ?? new Date().toISOString(),
    channel: snippet.channelTitle ?? 'DCLM',
    duration_seconds: liveStatus === 'none' ? parseIso8601Duration(contentDetails?.duration) : null,
    live_status: liveStatus,
    category: categorize(snippet.title ?? ''),
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function fetchJson(url: string): Promise<any> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`YouTube API ${res.status}: ${await res.text()}`);
  return res.json();
}

export async function syncYoutube(
  apiKey: string,
  firestore: FirestoreClient,
): Promise<{ videos: number; live: boolean; liveTransition: { title: string; videoId: string } | null }> {
  const channelUrl = `${YT_BASE}/channels?part=contentDetails&id=${CHANNEL_ID}&key=${apiKey}`;
  const channelJson = await fetchJson(channelUrl);
  const uploadsPlaylistId = channelJson.items?.[0]?.contentDetails?.relatedPlaylists?.uploads;
  if (!uploadsPlaylistId) throw new Error('Could not resolve uploads playlist id');

  const playlistUrl = `${YT_BASE}/playlistItems?part=snippet&playlistId=${uploadsPlaylistId}&maxResults=25&key=${apiKey}`;
  const playlistJson = await fetchJson(playlistUrl);
  const videoIds = (playlistJson.items ?? [])
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    .map((item: any) => item.snippet?.resourceId?.videoId)
    .filter(Boolean)
    .join(',');

  let written = 0;
  if (videoIds) {
    const detailsUrl = `${YT_BASE}/videos?part=snippet,contentDetails,liveStreamingDetails&id=${videoIds}&key=${apiKey}`;
    const detailsJson = await fetchJson(detailsUrl);
    // Firestore REST has no batch-write convenience here the way
    // admin-SDK's WriteBatch does — writing sequentially. 25 videos max
    // per sync (maxResults above), so this is a bounded, small loop, not
    // a scaling concern.
    for (const item of detailsJson.items ?? []) {
      const entry = videoEntryFromApiItem(item);
      await firestore.mergeSet(`youtube_videos/${entry.video_id}`, entry);
      written++;
    }
  }

  // Live/upcoming detection via search.list (the only endpoint that
  // reports this without already knowing a video id) — costs ~100 quota
  // units per call, same reasoning as the Cloud Function version this
  // was ported from: only run on the schedule, never per-screen-open.
  const searchUrl = `${YT_BASE}/search?part=snippet&channelId=${CHANNEL_ID}&eventType=live&type=video&key=${apiKey}`;
  const searchJson = await fetchJson(searchUrl);
  const liveVideoId = searchJson.items?.[0]?.id?.videoId;

  // Read the doc's previous state before overwriting it — this is what
  // replaces `onLiveStatusChanged` (a Firestore-triggered Cloud Function,
  // which only exists in that runtime). Only fires the notification on
  // the not-live -> live transition, same rule the original had, just
  // computed inline instead of via a before/after trigger diff.
  const previous = await firestore.get('config/youtube_live_status');
  const wasLive = !!previous?.video_id && previous?.live_status === 'live';

  let isLive = false;
  let liveTransition: { title: string; videoId: string } | null = null;
  if (liveVideoId) {
    const detailsUrl = `${YT_BASE}/videos?part=snippet,contentDetails,liveStreamingDetails&id=${liveVideoId}&key=${apiKey}`;
    const detailsJson = await fetchJson(detailsUrl);
    const item = detailsJson.items?.[0];
    if (item) {
      const entry = videoEntryFromApiItem(item);
      await firestore.mergeSet('config/youtube_live_status', entry);
      isLive = true;
      if (!wasLive) {
        liveTransition = { title: (entry.title as string) ?? 'DCLM is live now', videoId: liveVideoId };
      }
    }
  }
  if (!isLive) {
    await firestore.mergeSet('config/youtube_live_status', { video_id: null, live_status: 'none' });
  }

  return { videos: written, live: isLive, liveTransition };
}
