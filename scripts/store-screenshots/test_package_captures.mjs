import test from 'node:test';
import assert from 'node:assert/strict';
import { frames, pngDimensions, selectFrames } from './package_captures.mjs';

function png(type = 2, transparency = false) {
  const header = Buffer.alloc(33);
  Buffer.from('89504e470d0a1a0a', 'hex').copy(header);
  header.writeUInt32BE(13, 8);
  header.write('IHDR', 12);
  header.writeUInt32BE(1179, 16);
  header.writeUInt32BE(2556, 20);
  header[24] = 8;
  header[25] = type;
  const end = Buffer.alloc(12);
  end.write('IEND', 4);
  const transparent = Buffer.alloc(12);
  transparent.write('tRNS', 4);
  return Buffer.concat(transparency ? [header, transparent, end] : [header, end]);
}

test('PNG contract rejects alpha, transparency and truncated metadata', () => {
  assert.deepEqual(pngDimensions(png()), [1179, 2556]);
  assert.throws(() => pngDimensions(png(6)), /Alpha/);
  assert.throws(() => pngDimensions(png(2, true)), /Transparency/);
  assert.throws(() => pngDimensions(png().subarray(0, 35)), /Missing PNG end/);
});

test('each device requires exactly six successful captures, not failure evidence', () => {
  const attachments = frames.map((frame, i) => ({
    suggestedHumanReadableName: `Store-${frame}_0_ID.png`,
    exportedFileName: `image-${i}.png`, isAssociatedWithFailure: false,
  }));
  assert.equal(selectFrames([{ attachments }]).length, 6);
  assert.throws(() => selectFrames([{ attachments: attachments.slice(1) }]), /exactly one/);
  assert.throws(() => selectFrames([{ attachments: [...attachments, attachments[0]] }]), /exactly one/);
  assert.throws(() => selectFrames([{ attachments: attachments.map(a => ({ ...a, isAssociatedWithFailure: true })) }]), /Failed capture/);
  assert.throws(() => selectFrames([{ attachments: attachments.map(a => ({ ...a, exportedFileName: '../image.png' })) }]));
});
