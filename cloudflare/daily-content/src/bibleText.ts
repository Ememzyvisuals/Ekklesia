/**
 * Ported from functions/src/bibleText.ts — identical logic, only change
 * is using the runtime's native `fetch` instead of `node-fetch` (Workers
 * doesn't need the polyfill Cloud Functions' Node runtime did).
 */

const WLDEH_BASE = 'https://cdn.jsdelivr.net/gh/wldeh/bible-api/bibles';

// Same 66-book slug map as functions/src/bibleText.ts / bible_service.dart's
// _bookSlugs — hand-synced across three places now, same tradeoff noted
// in config.ts's header comment.
const BOOK_SLUGS: Record<string, string> = {
  genesis: 'genesis', exodus: 'exodus', leviticus: 'leviticus',
  numbers: 'numbers', deuteronomy: 'deuteronomy', joshua: 'joshua',
  judges: 'judges', ruth: 'ruth', '1 samuel': '1-samuel',
  '2 samuel': '2-samuel', '1 kings': '1-kings', '2 kings': '2-kings',
  '1 chronicles': '1-chronicles', '2 chronicles': '2-chronicles',
  ezra: 'ezra', nehemiah: 'nehemiah', esther: 'esther', job: 'job',
  psalms: 'psalms', psalm: 'psalms', proverbs: 'proverbs',
  ecclesiastes: 'ecclesiastes', 'song of solomon': 'song-of-solomon',
  isaiah: 'isaiah', jeremiah: 'jeremiah', lamentations: 'lamentations',
  ezekiel: 'ezekiel', daniel: 'daniel', hosea: 'hosea', joel: 'joel',
  amos: 'amos', obadiah: 'obadiah', jonah: 'jonah', micah: 'micah',
  nahum: 'nahum', habakkuk: 'habakkuk', zephaniah: 'zephaniah',
  haggai: 'haggai', zechariah: 'zechariah', malachi: 'malachi',
  matthew: 'matthew', mark: 'mark', luke: 'luke', john: 'john',
  acts: 'acts', romans: 'romans', '1 corinthians': '1-corinthians',
  '2 corinthians': '2-corinthians', galatians: 'galatians',
  ephesians: 'ephesians', philippians: 'philippians',
  colossians: 'colossians', '1 thessalonians': '1-thessalonians',
  '2 thessalonians': '2-thessalonians', '1 timothy': '1-timothy',
  '2 timothy': '2-timothy', titus: 'titus', philemon: 'philemon',
  hebrews: 'hebrews', james: 'james', '1 peter': '1-peter',
  '2 peter': '2-peter', '1 john': '1-john', '2 john': '2-john',
  '3 john': '3-john', jude: 'jude', revelation: 'revelation',
};

interface ParsedReference {
  bookSlug: string;
  chapter: number;
  startVerse?: number;
  endVerse?: number;
}

function parseReference(reference: string): ParsedReference | null {
  const match = reference.trim().match(/^(.+?)\s+(\d+)(?::(\d+)(?:-(\d+))?)?$/);
  if (!match) return null;

  const bookName = match[1].trim().toLowerCase();
  const slug = BOOK_SLUGS[bookName];
  if (!slug) return null;

  return {
    bookSlug: slug,
    chapter: parseInt(match[2], 10),
    startVerse: match[3] ? parseInt(match[3], 10) : undefined,
    endVerse: match[4] ? parseInt(match[4], 10) : undefined,
  };
}

/**
 * English-only fetch, returns null on any failure so the caller can
 * still write a reference-only doc rather than failing the whole run
 * over a transient CDN error — same fallback behavior as the Cloud
 * Function version this was ported from.
 */
export async function fetchEnglishVerseText(reference: string): Promise<string | null> {
  const parsed = parseReference(reference);
  if (!parsed) return null;

  try {
    const url = `${WLDEH_BASE}/en-kjv/books/${parsed.bookSlug}/chapters/${parsed.chapter}.json`;
    const res = await fetch(url);
    if (!res.ok) return null;

    const json = (await res.json()) as { verses?: Array<{ verse: number; text: string }> };
    const allVerses = json.verses ?? [];
    const selected = parsed.startVerse
      ? allVerses.filter(
          (v) => v.verse >= parsed.startVerse! && v.verse <= (parsed.endVerse ?? parsed.startVerse!),
        )
      : allVerses;

    if (selected.length === 0) return null;
    return selected.map((v) => (v.text || '').trim()).join(' ');
  } catch {
    return null;
  }
}
