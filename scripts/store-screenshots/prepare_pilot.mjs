import fs from 'node:fs/promises';
import { createHash } from 'node:crypto';

const url = 'https://upload.wikimedia.org/wikipedia/commons/9/9f/Sunset_pier.jpg';
const response = await fetch(url, { headers: { 'User-Agent': 'PiankexunReleasePreparation/1.0' } });
if (!response.ok) throw Error(`Sunset source download failed: ${response.status}`);
const bytes = Buffer.from(await response.arrayBuffer());
const hash = '9b505bd5d5af1b046add5e9b17a92af5a2ae766ce0e0490974a63f8cc38c0cc4';
if (createHash('sha256').update(bytes).digest('hex') !== hash) throw Error('Sunset source hash mismatch');
await fs.writeFile('build/store-source-photos/sunset-pier.jpg', bytes);
const file = 'build/store-source-photos/provenance.json';
const provenance = JSON.parse(await fs.readFile(file, 'utf8'));
provenance.license = 'Per-source public-domain/CC0; original demo artwork';
provenance.sources.push({
  file: 'sunset-pier.jpg', url, sha256: hash, author: 'Jon Sullivan (PDPhoto.org)',
  license: 'Public domain dedication; worldwide unrestricted permission where dedication is unavailable',
  evidence: 'https://commons.wikimedia.org/wiki/File:Sunset_pier.jpg',
});
provenance.usage = 'Priority-scene pilot only. Three distinct source photos plus eight original fictional demonstration cards/menus. No private documents, valid identity numbers, state insignia or fabricated app results.';
await fs.writeFile(file, JSON.stringify(provenance, null, 2) + '\n');
