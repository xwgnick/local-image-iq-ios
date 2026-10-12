import fs from 'node:fs/promises';
import { createHash } from 'node:crypto';

const revision = 'e8a42ba85aaf5fd9322ef9ca51bc21063b22fcae';
const sources = [
  { file: 'coffee.png', author: 'Rachel Michetti', sha256: 'cc02f8ca188b167c775a7101b5d767d1e71792cf762c33d6fa15a4599b5a8de7' },
  { file: 'chelsea.png', author: 'Stefan van der Walt', sha256: '596aa1e7cb875eb79f437e310381d26b338a81c2da23439704a73c4651e8c4bb' },
];
await fs.mkdir('build/store-source-photos', { recursive: true });
for (const source of sources) {
  source.url = `https://raw.githubusercontent.com/scikit-image/scikit-image/${revision}/skimage/data/${source.file}`;
  const response = await fetch(source.url);
  if (!response.ok) throw Error(`Photo download failed: ${source.file}: ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (createHash('sha256').update(bytes).digest('hex') !== source.sha256) {
    throw Error(`Photo hash mismatch: ${source.file}`);
  }
  await fs.writeFile(`build/store-source-photos/${source.file}`, bytes);
}
await fs.writeFile('build/store-source-photos/provenance.json', JSON.stringify({
  license: 'CC0-1.0',
  evidence: `https://github.com/scikit-image/scikit-image/blob/${revision}/skimage/data/_fetchers.py`,
  sources,
  usage: 'Public demonstration only, no endorsement. Six small crop variants per original are imported into a fresh simulator and indexed by the real app.',
}, null, 2));
