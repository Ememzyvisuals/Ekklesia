import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { defineSecret } from "firebase-functions/params";
import fetch from "node-fetch";
import { getFirestore } from "firebase-admin/firestore";
import { COLLECTIONS, DOCS } from "./config";

// Set with: firebase functions:secrets:set YOUTUBE_API_KEY
export const youtubeApiKeySecret = defineSecret("YOUTUBE_API_KEY");

const YT_BASE = "https://www.googleapis.com/youtube/v3";
// Mirrors AppConfig.youtubeChannelId — see config.ts's header note on
// hand-syncing constants across the two codebases.
const CHANNEL_ID = "UC4zsqN5YdXfxkkdVvwNA3JA";

const CATEGORY_KEYWORDS: Record<string, string[]> = {
  "Sunday Service": ["sunday", "communion"],
  "Bible Study": ["bible study"],
  Revival: ["revival", "crusade"],
  GCK: ["gck", "global crusade"],
  "Impact Academy": ["impact academy", "leadership training"],
  "Special Messages": ["special message", "memorial", "ordination"],
};

function categorize(title: string): string {
  const lower = title.toLowerCase();
  for (const [category, keywords] of Object.entries(CATEGORY_KEYWORDS)) {
    if (keywords.some((k) => lower.includes(k))) return category;
  }
  return "Programs";
}

function parseIso8601Duration(iso?: string): number | null {
  if (!iso) return null;
  const match = iso.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/);
  if (!match) return null;
  const hours = parseInt(match[1] || "0", 10);
  const minutes = parseInt(match[2] || "0", 10);
  const seconds = parseInt(match[3] || "0", 10);
  return hours * 3600 + minutes * 60 + seconds;
}

function bestThumbnail(thumbnails: Record<string, { url?: string }> | undefined): string {
  if (!thumbnails) return "";
  for (const quality of ["maxres", "high", "medium", "default"]) {
    const t = thumbnails[quality];
    if (t?.url) return t.url;
  }
  return "";
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function videoEntryFromApiItem(item: any): Record<string, unknown> {
  const snippet = item.snippet ?? {};
  const contentDetails = item.contentDetails;
  const liveDetails = item.liveStreamingDetails;

  let liveStatus = "none";
  if (liveDetails) {
    if (liveDetails.actualStartTime && !liveDetails.actualEndTime) {
      liveStatus = "live";
    } else if (liveDetails.scheduledStartTime && !liveDetails.actualStartTime) {
      liveStatus = "upcoming";
    }
  }

  return {
    video_id: item.id,
    title: snippet.title ?? "Untitled",
    description: snippet.description ?? "",
    thumbnail_url: bestThumbnail(snippet.thumbnails),
    published_at: snippet.publishedAt ?? new Date().toISOString(),
    channel: snippet.channelTitle ?? "DCLM",
    duration_seconds: liveStatus === "none" ? parseIso8601Duration(contentDetails?.duration) : null,
    live_status: liveStatus,
    category: categorize(snippet.title ?? ""),
  };
}

async function fetchJson(url: string): Promise<any> { // eslint-disable-line @typescript-eslint/no-explicit-any
  const res = await fetch(url);
  if (!res.ok) throw new Error(`YouTube API ${res.status}: ${await res.text()}`);
  return res.json();
}

async function syncYoutube(apiKey: string): Promise<{ videos: number; live: boolean }> {
  const db = getFirestore();

  const channelUrl = `${YT_BASE}/channels?part=contentDetails&id=${CHANNEL_ID}&key=${apiKey}`;
  const channelJson = await fetchJson(channelUrl);
  const uploadsPlaylistId = channelJson.items?.[0]?.contentDetails?.relatedPlaylists?.uploads;
  if (!uploadsPlaylistId) throw new Error("Could not resolve uploads playlist id");

  const playlistUrl = `${YT_BASE}/playlistItems?part=snippet&playlistId=${uploadsPlaylistId}&maxResults=25&key=${apiKey}`;
  const playlistJson = await fetchJson(playlistUrl);
  const videoIds = (playlistJson.items ?? [])
    .map((item: any) => item.snippet?.resourceId?.videoId) // eslint-disable-line @typescript-eslint/no-explicit-any
    .filter(Boolean)
    .join(",");

  let written = 0;
  if (videoIds) {
    const detailsUrl = `${YT_BASE}/videos?part=snippet,contentDetails,liveStreamingDetails&id=${videoIds}&key=${apiKey}`;
    const detailsJson = await fetchJson(detailsUrl);
    const batch = db.batch();
    for (const item of detailsJson.items ?? []) {
      const entry = videoEntryFromApiItem(item);
      const ref = db.collection(COLLECTIONS.youtubeVideos).doc(entry.video_id as string);
      batch.set(ref, entry, { merge: true });
      written++;
    }
    await batch.commit();
  }

  // Live/upcoming detection via search.list (the only endpoint that
  // reports this without already knowing a video id) — costs ~100 quota
  // units per call, which is why this only runs on the schedule below,
  // never per-screen-open.
  const searchUrl = `${YT_BASE}/search?part=snippet&channelId=${CHANNEL_ID}&eventType=live&type=video&key=${apiKey}`;
  const searchJson = await fetchJson(searchUrl);
  const liveVideoId = searchJson.items?.[0]?.id?.videoId;

  let isLive = false;
  if (liveVideoId) {
    const detailsUrl = `${YT_BASE}/videos?part=snippet,contentDetails,liveStreamingDetails&id=${liveVideoId}&key=${apiKey}`;
    const detailsJson = await fetchJson(detailsUrl);
    const item = detailsJson.items?.[0];
    if (item) {
      const entry = videoEntryFromApiItem(item);
      await db.collection(COLLECTIONS.config).doc(DOCS.youtubeLiveStatus).set(entry);
      isLive = true;
    }
  }
  if (!isLive) {
    await db.collection(COLLECTIONS.config).doc(DOCS.youtubeLiveStatus).set({ video_id: null });
  }

  return { videos: written, live: isLive };
}

/**
 * Runs every 15 minutes. This used to be additive alongside a client-side
 * YoutubeWorker that called the YouTube API directly — that client path
 * (YoutubeRemoteDatasource) has since been removed; YoutubeRepository.refresh()
 * now calls `syncYoutubeNow` below instead. This schedule and that callable
 * both write to the same `youtube_videos` / `config/youtube_live_status`
 * docs, so whichever runs most recently "wins" and the app doesn't care
 * which one populated its cache.
 */
export const youtubeSyncSchedule = onSchedule(
  { schedule: "every 15 minutes", region: "us-central1", secrets: [youtubeApiKeySecret] },
  async () => {
    try {
      const result = await syncYoutube(youtubeApiKeySecret.value());
      logger.info("YouTube sync complete", result);
    } catch (e) {
      logger.error("YouTube sync failed", { error: `${e}` });
    }
  }
);

export const syncYoutubeNow = onCall(
  { region: "us-central1", secrets: [youtubeApiKeySecret] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    return syncYoutube(youtubeApiKeySecret.value());
  }
);
