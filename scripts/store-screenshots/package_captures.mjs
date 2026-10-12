import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const frames = [
  '01-coffee-search', '02-cat-search', '03-cleanup-overview',
  '04-cleanup-selection', '05-cleanup-detail', '06-privacy',
];
const devices = { 'iphone-medium': [1179, 2556], 'iphone-large': [1320, 2868], 'ipad-13': [2064, 2752] };

export function pngDimensions(bytes) {
  assert.ok(bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')), 'Expected PNG');
  assert.equal(bytes.toString('ascii', 12, 16), 'IHDR');
  assert.equal(bytes[24], 8, 'Expected 8-bit RGB');
  assert.equal(bytes[25], 2, 'Alpha or indexed PNG is not accepted');
  let ended = false;
  for (let offset = 8; offset + 12 <= bytes.length;) {
    const length = bytes.readUInt32BE(offset);
    assert.ok(offset + length + 12 <= bytes.length, 'Truncated PNG');
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    assert.notEqual(type, 'tRNS', 'Transparency is not accepted');
    offset += length + 12;
    if (type === 'IEND') {
      assert.equal(offset, bytes.length, 'Unexpected bytes after PNG');
      ended = true;
      break;
    }
  }
  assert.ok(ended, 'Missing PNG end');
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

export function selectFrames(manifest) {
  const attachments = manifest.flatMap(test => test.attachments);
  return frames.map(frame => {
    const matches = attachments.filter(a => a.suggestedHumanReadableName.startsWith(`Store-${frame}_`)
      && a.exportedFileName.endsWith('.png'));
    assert.equal(matches.length, 1, `Expected exactly one ${frame}`);
    assert.equal(matches[0].isAssociatedWithFailure, false, `Failed capture: ${frame}`);
    assert.match(matches[0].exportedFileName, /^[A-Za-z0-9-]+\.png$/);
    return { frame, attachment: matches[0] };
  });
}

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

function packageCaptures(input, output) {
  assert.ok(input && output, 'Usage: node package_captures.mjs INPUT_DIRECTORY NEW_OUTPUT_DIRECTORY');
  const source = path.resolve(input), destination = path.resolve(output);
  assert.ok(!fs.existsSync(destination), 'Output must be a new directory');
  const planned = [];
  for (const [device, target] of Object.entries(devices)) {
    const manifest = JSON.parse(fs.readFileSync(path.join(source, device, 'manifest.json')));
    for (const { frame, attachment } of selectFrames(manifest)) {
      const file = path.join(source, device, attachment.exportedFileName);
      const bytes = fs.readFileSync(file), dimensions = pngDimensions(bytes);
      const pad = device === 'iphone-medium' && dimensions[0] === 1178 && dimensions[1] === 2556;
      assert.ok(pad || dimensions.every((value, index) => value === target[index]), `Unexpected size: ${file}`);
      planned.push({ device, frame, attachment, file, bytes, dimensions, target, pad });
    }
  }
  const provenance = fs.readFileSync(path.join(source, 'provenance.json'));
  assert.equal(JSON.parse(provenance).license, 'CC0-1.0');
  fs.mkdirSync(destination, { recursive: true });
  const report = [];
  for (const entry of planned) {
    const relative = `${entry.device}/${entry.frame}.png`;
    const file = path.join(destination, entry.device, `${entry.frame}.png`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    if (entry.pad) {
      const result = spawnSync('ffmpeg', [
        '-hide_banner', '-loglevel', 'error', '-n', '-i', entry.file,
        '-vf', 'format=rgb24,pad=1179:2556:0:0,fillborders=right=1:mode=smear',
        '-frames:v', '1', '-update', '1', file,
      ], { encoding: 'utf8' });
      if (result.error) throw result.error;
      assert.equal(result.status, 0, result.stderr);
    } else {
      fs.copyFileSync(entry.file, file, fs.constants.COPYFILE_EXCL);
    }
    const bytes = fs.readFileSync(file);
    assert.deepEqual(pngDimensions(bytes), entry.target);
    report.push({
      file: relative, width: entry.target[0], height: entry.target[1], sha256: sha256(bytes),
      sourceFile: entry.attachment.exportedFileName, sourceSHA256: sha256(entry.bytes),
      sourceDimensions: entry.dimensions, deviceName: entry.attachment.deviceName,
      operation: entry.pad ? 'Replicate rightmost column once; no rescale or content edit' : 'Unchanged native PNG',
    });
  }
  fs.writeFileSync(path.join(destination, 'photo-provenance.json'), provenance);
  fs.writeFileSync(path.join(destination, 'manifest.json'), JSON.stringify({
    status: 'candidate-not-submitted',
    sourceRun: path.basename(source),
    note: 'Real native UI with licensed photo variants. English queries; no OCR or side-by-side comparison capture. Owner approval and final submission-build review remain required.',
    screenshots: report,
  }, null, 2) + '\n');
  console.log(JSON.stringify({ output: destination, screenshots: report.length, devices: Object.keys(devices) }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  packageCaptures(process.argv[2], process.argv[3]);
}
