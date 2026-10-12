import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

const selections = [
  ['sunset-02.jpg', 'Waikiki Beach at Sunset.jpg', 'sunset'],
  ['sunset-03.jpg', 'Horse rider silhouette at sunset (Unsplash).jpg', 'sunset'],
  ['sunset-04.jpg', 'Sunset at Holden Beach Pier - panoramio.jpg', 'sunset'],
  ['sunset-05.jpg', 'Crowded pier after the sunset (Unsplash).jpg', 'sunset'],
  ['sunset-06.jpg', 'Koh Mak, Thailand, Sunset trail.jpg', 'sunset'],
  ['sunset-07.jpg', 'Hermosa Beach Pier at Sunset.jpg', 'sunset'],
  ['sunset-08.jpg', "Haskell's Beach Sunset 2014.jpg", 'sunset'],
  ['cat-play-01.jpg', 'Black and white kitten biting lure from back.jpg', 'cat-play'],
  ['cat-play-02.jpg', 'Black kitten playing with a toy.jpg', 'cat-play'],
  ['cat-play-03.jpg', 'Biscuit.The.Flying.Cat.jpg', 'cat-play'],
  ['cat-play-04.jpg', "'Mata-Hari' doing the 'Indian Rope Trick'.jpg", 'cat-play'],
  ['cat-play-05.jpg', 'Cat dancing in the snow-Tscherno.jpg', 'cat-play'],
  ['cat-play-06.jpg', 'Ancotwo.jpg', 'cat-play'],
  ['cat-play-07.jpg', 'An old cat plays with a towel (55093444529).jpg', 'cat-play'],
  ['cat-play-08.png', 'Cat Jumping.png', 'cat-play'],
];
const headers = { 'User-Agent': 'PiankexunReleasePreparation/1.0' };
const parameters = new URLSearchParams({ action: 'query', format: 'json', prop: 'imageinfo',
  iiprop: 'url|extmetadata|size|mime', iiurlwidth: '640',
  titles: selections.map(([, title]) => `File:${title}`).join('|') });
const response = await fetch(`https://commons.wikimedia.org/w/api.php?${parameters}`, { headers });
if (!response.ok) throw Error(`Campaign source metadata failed: ${response.status}`);
const metadata = await response.json();
if (metadata.error) throw Error(JSON.stringify(metadata.error));
const pages = Object.values(metadata.query.pages);
const output = path.resolve('build', 'app-store', 'campaign-assets');
await fs.mkdir(output, { recursive: true });
const plain = html => html.replace(/<[^>]+>/g, '').trim();
const photos = [];
for (const [name, title, category] of selections) {
  const page = pages.find(item => item.title === `File:${title}`);
  assert.ok(page?.imageinfo?.[0], `Missing licensed photograph: ${title}`);
  const info = page.imageinfo[0];
  const details = info.extmetadata;
  const license = details.LicenseShortName?.value;
  assert.match(license ?? '', /^(Public domain|CC0|CC BY [0-9.]+)$/, title);
  assert.ok(details.Artist?.value, `Missing attribution: ${title}`);
  assert.ok(info.thumburl, `Missing public thumbnail: ${title}`);
  const url = new URL(info.thumburl);
  url.search = '';
  const image = await fetch(url, { headers });
  if (!image.ok) throw Error(`Campaign photo ${title}: HTTP ${image.status}`);
  assert.match(image.headers.get('content-type') ?? '', /^image\/(jpeg|png)/, title);
  const bytes = Buffer.from(await image.arrayBuffer());
  assert.ok(bytes.length > 1000, `Incomplete photo: ${title}`);
  await fs.writeFile(path.join(output, name), bytes);
  photos.push({ name, category, title, author: plain(details.Artist.value), license,
    licenseUrl: details.LicenseUrl?.value ?? '',
    sourcePage: info.descriptionurl, downloadUrl: url.href,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    modifications: 'Scaled Commons thumbnail; square crops in the illustrative result grid.' });
  console.log(`${name}: ${license} — ${title}`);
}
await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify({
  purpose: 'Public photos for clearly labelled marketing result compositions; not device search evidence',
  photos,
}, null, 2) + '\n');
