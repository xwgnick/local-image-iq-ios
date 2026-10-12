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
const identityUrl = 'https://upload.wikimedia.org/wikipedia/commons/e/e7/The_People%27s_Republic_of_China_resident_identity_card_%28SAMPLE%29.png';
const identityResponse = await fetch(identityUrl, { headers: { 'User-Agent': 'PiankexunReleasePreparation/1.0' } });
if (!identityResponse.ok) throw Error(`Identity specimen download failed: ${identityResponse.status}`);
const identityBytes = Buffer.from(await identityResponse.arrayBuffer());
const identityHash = '0837498d3f13f3b7a391d29cccb3e756a8f524a81f406dc302a5930b24094321';
if (createHash('sha256').update(identityBytes).digest('hex') !== identityHash) throw Error('Identity specimen hash mismatch');
await fs.writeFile('build/store-source-photos/identity-sample-both.png', identityBytes);
provenance.sources.push({
  file: 'identity-sample-both.png', url: identityUrl, sha256: identityHash,
  author: 'Official PRC specimen; Commons uploader Discovery23',
  license: 'Public domain (Commons PD-PRC-exempt; Copyright Law Article 5)',
  evidence: "https://commons.wikimedia.org/wiki/File:The_People%27s_Republic_of_China_resident_identity_card_(SAMPLE).png",
  usage: 'Retain SAMPLE markings and placeholder fields. Four staged views of the same public specimen, not four real identities. State insignia appears only in the existing licensed specimen, not newly drawn.',
});
provenance.usage = 'Priority-scene pilot only. Three source photos, four staged front/back specimen views and four original menus. No private identity scans, real personal information, valid identity numbers or fabricated app results.';
await fs.writeFile(file, JSON.stringify(provenance, null, 2) + '\n');
