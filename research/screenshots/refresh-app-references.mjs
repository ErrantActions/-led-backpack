import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const definitions = [
  { id: 1237452417, category: 'LED and pixel tools', question: 'How do gallery browsing, creation and device sending relate?', targets: ['Library', 'Create', 'Send & Play'] },
  { id: 1562961996, category: 'LED and pixel tools', question: 'What does a close functional peer expose for text, animation and hardware?', targets: ['Create', 'Backpack', 'Live'] },
  { id: 6446207239, category: 'LED and pixel tools', question: 'How can device selection and light controls stay direct?', targets: ['Backpack', 'Scenes'] },
  { id: 1049333656, category: 'Connected devices', question: 'How are rooms/devices, scenes and live control separated?', targets: ['Backpack', 'Scenes'] },
  { id: 1055281310, category: 'Connected devices', question: 'How are immediate controls distinguished from saved scenes?', targets: ['Backpack', 'Scenes'] },
  { id: 1110145103, category: 'Connected devices', question: 'How does a native home/device hierarchy provide contextual controls?', targets: ['Backpack', 'My devices'] },
  { id: 1514844621, category: 'Connected devices', question: 'How are device identity, current status and recovery actions grouped?', targets: ['My devices', 'Recovery'] },
  { id: 874139669, category: 'Messaging', question: 'How do conversation hierarchy and composing support a focused private task?', targets: ['Messages', 'Recovery'] },
  { id: 686449807, category: 'Messaging', question: 'How are rich media and secondary conversation tools exposed?', targets: ['Messages', 'Sharing'] },
  { id: 310633997, category: 'Messaging', question: 'How are primary conversation actions kept recognizable?', targets: ['Messages', 'Recovery'] },
  { id: 985746746, category: 'Messaging', question: 'How are communities, channels and conversations distinguished without confusing the current audience?', targets: ['Messages', 'Groups', 'Events'] },
  { id: 454638411, category: 'Messaging', question: 'How are recent people, chats and media entry actions presented?', targets: ['Messages', 'Sharing'] },
  { id: 618783545, category: 'Messaging', question: 'How can channels, threads and activity organize a large conversation space?', targets: ['Groups', 'Events', 'Messages'] },
  { id: 389801252, category: 'Social and community', question: 'How do media discovery, profiles and direct sharing form separate contexts?', targets: ['Discovery', 'Community uploads', 'Profiles'] },
  { id: 429047995, category: 'Social and community', question: 'How can visual search, collecting and boards inspire artwork organization?', targets: ['Discovery', 'Library', 'Collections'] },
  { id: 1064216828, category: 'Social and community', question: 'How do communities, posts and threaded replies communicate context?', targets: ['Community', 'Events', 'Reports'] },
  { id: 6444370199, category: 'Social and community', question: 'How are feed, discovery, profiles and public conversation distinguished?', targets: ['Community', 'Profiles', 'Social'] },
  { id: 1571998974, category: 'Social and community', question: 'How can a community client make account/server and public conversation context visible?', targets: ['Account', 'Community', 'Social'] },
  { id: 426826309, category: 'Outdoor and GPS', question: 'How are recording, route context and community activity distinguished?', targets: ['GPS games', 'Live', 'Social'] },
  { id: 447374873, category: 'Outdoor and GPS', question: 'How are route discovery, route review and navigation made legible?', targets: ['GPS games', 'Event routes'] },
  { id: 893687399, category: 'Outdoor and GPS', question: 'How can route review and ride controls coexist without crowding the map?', targets: ['GPS games', 'Event routes'] },
  { id: 405075943, category: 'Outdoor and GPS', question: 'How are discovery cards, route facts and map context connected?', targets: ['Discovery', 'GPS games'] },
  { id: 975571447, category: 'Motorcycling', question: 'How are motorcycle route discovery, ride recording and community kept distinct?', targets: ['Riding setup', 'GPS games', 'Social rides'] },
  { id: 1209129603, category: 'Motorcycling', question: 'How can route review communicate road preferences and ride context before starting?', targets: ['Event routes', 'Riding setup'] },
  { id: 1373032762, category: 'Motorcycling', question: 'How are planning, an active ride and safety-related services communicated separately?', targets: ['Riding setup', 'Live', 'Session state'] },
  { id: 1087005682, category: 'Motorcycling', question: 'How can group ride and route context stay understandable?', targets: ['Social rides', 'Events'] },
  { id: 1089668246, category: 'Motorcycling', question: 'How can map context, route choices and navigation status remain readable?', targets: ['Event routes', 'GPS games'] },
  { id: 1250173746, category: 'Motorcycling', question: 'How are vehicle connection and ride/navigation information related?', targets: ['Backpack status', 'Live', 'Hardware capability'] },
  { id: 1255766787, category: 'Motorcycling', question: 'How are recorded routes and ride statistics presented after the session?', targets: ['Session history', 'Social rides'] },
  { id: 583446403, category: 'Activity and status', question: 'How are current status, detail and connected hardware surfaced?', targets: ['Backpack status', 'Live diagnostics'] },
  { id: 1576857102, category: 'Activity and status', question: 'How can one clear status story replace a wall of equally weighted metrics?', targets: ['Live', 'Session state'] },
  { id: 1584215428, category: 'Media and editing', question: 'How can artwork browsing stay dominant while actions remain available?', targets: ['Library', 'Selection'] },
  { id: 953286746, category: 'Media and editing', question: 'How do editing tools stay subordinate to the visual result?', targets: ['GIF Studio', 'Timing', 'Library'] },
  { id: 916366645, category: 'Media and editing', question: 'How can a small-screen canvas offer powerful tools without permanent forms?', targets: ['Pixel editor', 'GIF Studio'] },
  { id: 888422857, category: 'Media and editing', question: 'How can playback state and queue/collection hierarchy remain clear?', targets: ['Playlists', 'Phone playback'] },
  { id: 324684580, category: 'Mainstream products', question: 'How can browsing, a collection and current playback stay distinct?', targets: ['Discovery', 'Library', 'Phone playback'] },
  { id: 363590051, category: 'Mainstream products', question: 'How are media discovery, item review and continuing a session related?', targets: ['Discovery', 'Artwork detail', 'Playback'] },
  { id: 544007664, category: 'Mainstream products', question: 'How are media viewing and secondary creator/community context separated?', targets: ['Artwork detail', 'Community', 'Creator attribution'] },
  { id: 1232780281, category: 'Mainstream products', question: 'How can a deep workspace hierarchy retain current page context?', targets: ['Collections', 'Events', 'Settings'] },
  { id: 904237743, category: 'Premium product references', question: 'How can a focused task list use restrained hierarchy and progressive detail?', targets: ['Preparation', 'Device setup', 'Requests'] },
  { id: 718043190, category: 'Premium product references', question: 'How are event overview and selected detail connected across sizes?', targets: ['Events', 'Event detail', 'Duo list/detail'] },
  { id: 1358823008, category: 'Premium product references', question: 'How can a current operation communicate time, freshness and changing state?', targets: ['Transfers', 'Connection status', 'Live'] },
  { id: 1016366447, category: 'Premium product references', question: 'How can collection hierarchy and an active draft remain quiet and clear?', targets: ['Collections', 'Text editor', 'Drafts'] },
  { id: 885697368, category: 'Premium product references', question: 'How do professional tools remain subordinate to an active preview?', targets: ['GIF Studio', 'Pixel editor', 'Preview'] },
];

const response = await fetch(
  `https://itunes.apple.com/lookup?country=us&id=${definitions.map(app => app.id).join(',')}`,
  { signal: AbortSignal.timeout(60000) },
);
assert.ok(response.ok, `App Store lookup failed: HTTP ${response.status}`);
const payload = await response.json();
assert.ok(Array.isArray(payload.results), 'Missing App Store results.');
const records = new Map(payload.results.map(app => [app.trackId, app]));
const apps = definitions.map(definition => {
  const app = records.get(definition.id);
  assert.ok(app, `App ${definition.id} is missing; inspect the listing before refreshing.`);
  assert.ok(app.trackName && app.sellerName && app.trackViewUrl, `Incomplete listing: ${definition.id}`);
  const select = (urls, device, limit) => (urls ?? []).slice(0, limit).map((url, index) => {
    const parsed = new URL(url);
    assert.ok(parsed.protocol === 'https:' && parsed.hostname.endsWith('.mzstatic.com'), `Unexpected image host: ${url}`);
    return { url, device, position: index + 1, review: 'Publisher screenshot; exact depicted app build and pose are not independently verified.' };
  });
  const screenshots = [
    ...select(app.screenshotUrls, 'iPhone', 6),
    ...select(app.ipadScreenshotUrls, 'iPad', 2),
  ];
  assert.ok(screenshots.length, `No published screenshots: ${app.trackName}`);
  return {
    ...definition,
    name: app.trackName,
    publisher: app.sellerName,
    listingUrl: app.trackViewUrl,
    listingVersion: app.version,
    listingReleaseDate: app.currentVersionReleaseDate,
    availableIPhoneScreenshots: app.screenshotUrls?.length ?? 0,
    availableIPadScreenshots: app.ipadScreenshotUrls?.length ?? 0,
    screenshots,
  };
});

const data = {
  retrievedAt: new Date().toISOString(),
  storefront: 'US',
  source: 'Apple iTunes lookup API and linked publisher App Store listings',
  sourceUrl: `https://itunes.apple.com/lookup?country=us&id=${definitions.map(app => app.id).join(',')}`,
  selection: 'Up to the first six published iPhone screenshots and first two iPad screenshots per app, in publisher order.',
  limitations: 'Published marketing images, not hands-on captures. Listing update dates do not date the screenshot or establish Duo support. No third-party image binaries are stored in this repository.',
  apps,
};
const boardPath = fileURLToPath(new URL('./app-reference-board.html', import.meta.url));
const board = await readFile(boardPath, 'utf8');
const marker = /<script id="reference-data" type="application\/json">[\s\S]*?<\/script>/;
assert.ok(marker.test(board), 'The board is missing its embedded-data marker.');
const json = JSON.stringify(data, null, 2);
const embedded = json.replaceAll('<', '\\u003c').replaceAll('>', '\\u003e');
await writeFile(fileURLToPath(new URL('./app-references.json', import.meta.url)), `${json}\n`, 'utf8');
await writeFile(boardPath, board.replace(marker, () =>
  `<script id="reference-data" type="application/json">\n${embedded}\n</script>`), 'utf8');
console.log(`Collected ${apps.length} official app listings and ${apps.reduce((sum, app) => sum + app.screenshots.length, 0)} screenshot references.`);
