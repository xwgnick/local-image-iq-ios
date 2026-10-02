#!/usr/bin/env node
// Read-only public-pack contracts. No downloads, photos, GPS lookups or model dependencies.
// Only --self-test writes files: synthetic fixtures in its own temporary directory.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const packName = 'Places.geojson';
const manifestName = 'places-manifest.json';
const generator = 'local-image-iq-public-places-v1';
const commit = '9469f09592ced973a3448cf66b6100b741b64c0d';
const countries = { CHN: 'China', FRA: 'France', DEU: 'Germany', NLD: 'Netherlands' };
const coverageCountries = Object.values(countries);
const sourceOrder = Object.keys(countries).flatMap(iso => ['ADM1', 'ADM2'].map(level => `${iso}/${level}`));
const countNames = ['raw', 'emitted', 'excluded', 'repairs', 'repairFailures', 'unlabeled',
  'unsupported', 'polygonExtractions', 'discardedNonPolygonComponents', 'missingSourceID',
  'duplicateSourceID', 'parentMatched', 'parentAmbiguous', 'parentUnmatched', 'parentUnlabeled'];
const licenseURLs = {
  geoBoundaries: 'https://creativecommons.org/licenses/by/4.0/',
  'Public Domain': 'https://commons.wikimedia.org/wiki/File',
  'Open Data Commons Public Domain Dedication and License (PDDL) v1.0': 'https://opendatacommons.org/licenses/pddl/1-0/',
  'Etalab Open License 2.0': 'https://github.com/etalab/licence-ouverte/blob/master/LO.md',
  'Data license Germany - Attribution - Version 2.0': 'https://www.govdata.de/dl-de/by-2-0',
  'CC0 1.0 Universal (CC0 1.0) Public Domain Dedication': 'https://creativecommons.org/publicdomain/zero/1.0/',
};

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const json = file => JSON.parse(readFileSync(file, 'utf8'));
const key = source => `${source.iso}/${source.level}`;
const slash = relative => relative.split(path.sep).join('/');

/** Exact existing Swift resolver identity, including wrapping UInt64 and unpadded lowercase hex. */
export function runtimeVersion(bytes) {
  let value = 14695981039346656037n;
  for (const byte of bytes) value = BigInt.asUintN(64, (value ^ BigInt(byte)) * 1099511628211n);
  return `raycast-v1-${value.toString(16)}`;
}

function runtimeCoverageDescription(countries, featureCount) {
  const coverage = countries.length ? `Offline country coverage: ${countries.join(', ')}.` : 'Offline coverage: this pack only.';
  return `${coverage} Administrative boundaries may be incomplete or historical; not live GPS or global coverage. ` +
    `${featureCount} features; 0 unsupported/invalid features skipped.`;
}

function nonempty(value, label) {
  assert.ok(typeof value === 'string' && value.trim().length > 0, `${label} must be nonempty text`);
}

function count(value, label, positive = false) {
  assert.ok(Number.isSafeInteger(value) && value >= (positive ? 1 : 0), `${label} must be a ${positive ? 'positive' : 'nonnegative'} integer`);
}

function validateSources(config) {
  assert.equal(config.schemaVersion, 1, 'Source configuration schema');
  assert.ok(Array.isArray(config.sources), 'Source configuration sources');
  assert.deepEqual(config.sources.map(key), sourceOrder, 'Expected eight pinned CHN/FRA/DEU/NLD ADM1/ADM2 sources');
  for (const source of config.sources) {
    assert.equal(source.country, countries[source.iso], `Source country: ${key(source)}`);
    assert.equal(source.commit, commit, `Source revision: ${key(source)}`);
    assert.equal(source.file, `${source.iso}-${source.level}.geojson`);
    assert.equal(source.url, `https://media.githubusercontent.com/media/wmgeolab/geoBoundaries/${commit}/releaseData/gbOpen/${source.iso}/${source.level}/geoBoundaries-${source.iso}-${source.level}_simplified.geojson`, 'Only pinned public geometry URLs are allowed');
    assert.match(source.sha256, /^[a-f0-9]{64}$/, 'Source SHA-256 pin');
    for (const field of ['canonical', 'boundaryID', 'year', 'license', 'licenseSource', 'source']) {
      nonempty(source[field], `Source ${key(source)} ${field}`);
    }
    assert.ok(Object.hasOwn(licenseURLs, source.license), `Missing license URL for ${key(source)}`);
  }
  return config.sources;
}

function sourceNote(sources) {
  const years = sources.map(s => `${s.country} ${s.level} ${s.year}`).join('; ');
  return `geoBoundaries gbOpen, revision ${commit}; represented boundary years: ${years}. ` +
    'Uses the upstream simplified datasets without additional simplification; invalid polygons ' +
    'may be repaired. Historical administrative approximations, not current addresses or global ' +
    'coverage. ADM2 parent names use unique representative-point containment, not official ' +
    "hierarchy or a photo's position; uncertain parents omitted. Per-source licenses, " +
    'attribution, repairs and exclusions are recorded in places-manifest.json.';
}

// Match the resolver's accepted structural shapes, not a second topology engine or geocoder.
function validateGeometry(geometry) {
  assert.ok(geometry && ['Polygon', 'MultiPolygon'].includes(geometry.type), 'Unsupported geometry');
  const polygons = geometry.type === 'Polygon' ? [geometry.coordinates] : geometry.coordinates;
  assert.ok(Array.isArray(polygons) && polygons.length > 0, 'Empty polygons');
  for (const polygon of polygons) {
    assert.ok(Array.isArray(polygon) && polygon.length > 0, 'Empty polygon rings');
    for (const ring of polygon) {
      assert.ok(Array.isArray(ring) && ring.length >= 4, 'Ring needs at least four positions');
      let first, previous, twiceArea = 0;
      for (const position of ring) {
        assert.ok(Array.isArray(position) && [2, 3].includes(position.length) && position.every(Number.isFinite), 'Invalid position');
        assert.ok(Math.abs(position[0]) <= 180 && Math.abs(position[1]) <= 90, 'Position outside WGS84');
        let [x, y] = position;
        if (previous) {
          while (x - previous[0] > 180) x -= 360;
          while (x - previous[0] < -180) x += 360;
          twiceArea += previous[0] * y - x * previous[1];
        }
        first ??= [x, y];
        previous = [x, y];
      }
      assert.deepEqual(ring[0].slice(0, 2), ring.at(-1).slice(0, 2), 'Unclosed ring');
      assert.deepEqual(first, previous, 'Unclosed longitude-unwrapped ring');
      assert.ok(Number.isFinite(twiceArea) && Math.abs(twiceArea) > 0, 'Zero-area ring');
    }
  }
}

function validateManifest(manifest, collection, bytes, sources) {
  assert.equal(manifest.schemaVersion, 1, 'Places manifest schema');
  assert.equal(manifest.generator, generator, 'Places generator');
  // Python compact(..., ensure_ascii=False) and JSON.stringify agree for these string-only metadata objects.
  assert.equal(manifest.sourceMetadataSHA256, sha256(JSON.stringify(sources)), 'Source metadata SHA-256');
  assert.equal(manifest.shapelyVersion, '2.1.2', 'Pinned Shapely version');
  nonempty(manifest.geosVersion, 'GEOS version');
  nonempty(manifest.parentMethod, 'Parent method');
  assert.equal(manifest.additionalSimplification, false, 'No additional simplification');
  assert.deepEqual(manifest.coverageCountries, coverageCountries, 'Manifest country coverage');
  assert.equal(manifest.sourceNote, sourceNote(sources), 'Manifest source note');
  assert.equal(collection.type, 'FeatureCollection');
  assert.deepEqual(collection.coverageCountries, coverageCountries, 'GeoJSON country coverage');
  assert.equal(collection.sourceNote, manifest.sourceNote, 'GeoJSON source note');
  assert.ok(Array.isArray(collection.features) && collection.features.length > 0, 'Empty feature collection');

  const generated = manifest.generated;
  assert.equal(generated?.file, packName, 'Generated filename');
  count(generated.bytes, 'Generated bytes', true);
  assert.equal(generated.bytes, bytes.length, 'Generated byte count');
  assert.equal(generated.sha256, sha256(bytes), 'Generated SHA-256');
  count(generated.featureCount, 'Generated feature count', true);
  assert.equal(generated.featureCount, collection.features.length, 'Generated feature count');

  // Packaging is the integrity boundary: lightweight app inspection must never
  // read/hash geometry to discover stale metadata after caches have been filtered.
  const runtime = manifest.runtime;
  assert.equal(runtime?.schemaVersion, 1, 'Runtime metadata schema');
  assert.match(runtime.version, /^raycast-v1-(?:0|[1-9a-f][0-9a-f]{0,15})$/, 'Runtime version format');
  assert.equal(runtime.version, runtimeVersion(bytes), 'Runtime version must match exact GeoJSON bytes');
  assert.equal(runtime.coverageDescription, runtimeCoverageDescription(collection.coverageCountries, collection.features.length),
    'Runtime coverage description must match resolver');

  const attribution = manifest.attribution;
  nonempty(attribution?.text, 'Attribution text');
  assert.equal(attribution.bytes, Buffer.byteLength(attribution.text, 'utf8'), 'Attribution byte count');
  assert.equal(attribution.sha256, sha256(attribution.text), 'Attribution SHA-256');
  assert.deepEqual(attribution.licenseURLs, licenseURLs, 'Attribution license URLs');
  assert.ok(Array.isArray(manifest.sources) && manifest.sources.length === sources.length, 'Manifest must contain all eight sources');
  const totals = Object.fromEntries(countNames.map(name => [name, 0]));
  const expectedFeatures = new Map();
  for (let index = 0; index < sources.length; index++) {
    const expected = sources[index], report = manifest.sources[index];
    assert.deepEqual(report.metadata, expected, `Source metadata: ${key(expected)}`);
    assert.equal(report.verified?.sha256, expected.sha256, `Verified source SHA-256: ${key(expected)}`);
    count(report.verified.bytes, `Verified source bytes: ${key(expected)}`, true);
    assert.ok(Array.isArray(report.issues), `Source issues: ${key(expected)}`);
    for (const name of countNames) {
      count(report.counts?.[name], `${key(expected)} ${name}`, name === 'emitted');
      totals[name] += report.counts[name];
    }
    assert.equal(report.counts.raw, report.counts.emitted + report.counts.excluded, 'Raw = emitted + excluded');
    assert.ok(report.counts.repairFailures <= report.counts.repairs, 'Repair failures exceed attempts');
    const parentTotal = ['parentMatched', 'parentAmbiguous', 'parentUnmatched', 'parentUnlabeled']
      .reduce((sum, name) => sum + report.counts[name], 0);
    assert.equal(parentTotal, expected.level === 'ADM2' ? report.counts.emitted : 0, 'Parent outcome count');
    expectedFeatures.set(key(expected), report.counts.emitted);
  }
  assert.deepEqual(manifest.totals, totals, 'Totals must equal the eight source reports');
  assert.equal(totals.emitted, generated.featureCount, 'Sum of emitted source features');
  const actualFeatures = new Map(sourceOrder.map(name => [name, 0]));
  for (const feature of collection.features) {
    assert.equal(feature.type, 'Feature');
    const properties = feature.properties;
    assert.ok(properties && actualFeatures.has(key(properties)), 'Feature source coverage');
    assert.equal(properties.country, countries[properties.iso], 'Feature country');
    nonempty(properties.label, 'Feature label');
    assert.ok(properties.label.endsWith(`, ${properties.country}`), 'Feature label must include country');
    nonempty(properties.sourceBoundaryID, 'Feature source identity');
    validateGeometry(feature.geometry);
    actualFeatures.set(key(properties), actualFeatures.get(key(properties)) + 1);
  }
  assert.deepEqual(actualFeatures, expectedFeatures, 'Features per country/administrative level');
}

function findPair(directory, appBundle) {
  // Exact spelling matters even when the checker runs on case-insensitive Windows/macOS.
  // Never search a test bundle, Frameworks, Models, or a sibling build configuration.
  const candidates = appBundle ? [[], ['Places'], ['Resources', 'Places']] : [[]];
  for (const parts of candidates) {
    let folder = directory, present = true;
    for (const part of parts) {
      if (!readdirSync(folder).includes(part) || !statSync(path.join(folder, part)).isDirectory()) {
        present = false;
        break;
      }
      folder = path.join(folder, part);
    }
    if (!present) continue;
    const entries = readdirSync(folder);
    if (!entries.includes(packName)) continue;
    const pack = path.join(folder, packName), manifest = path.join(folder, manifestName);
    assert.ok(statSync(pack).isFile(), `Not a regular pack file: ${pack}`);
    assert.ok(entries.includes(manifestName) && statSync(manifest).isFile(), `Missing colocated ${manifestName}: ${folder}`);
    return { pack, manifest };
  }
  throw Error(`Missing ${packName} and ${manifestName} in ${directory}${appBundle ? ' (app root, Places, or Resources/Places)' : ''}`);
}

/** Required-pack validator shared by CI and the device packager. Returns only small provenance/coverage metadata. */
export function validatePlaces(directory, { appBundle = false } = {}) {
  directory = path.resolve(directory);
  const sources = validateSources(json(path.join(root, 'scripts', 'place_sources.json')));
  const files = findPair(directory, appBundle);
  const bytes = readFileSync(files.pack), manifestBytes = readFileSync(files.manifest);
  const manifest = JSON.parse(manifestBytes.toString('utf8'));
  validateManifest(manifest, JSON.parse(bytes.toString('utf8')), bytes, sources);
  return {
    schemaVersion: manifest.schemaVersion, generator: manifest.generator,
    file: slash(path.relative(directory, files.pack)), manifest: slash(path.relative(directory, files.manifest)),
    sha256: manifest.generated.sha256, bytes: manifest.generated.bytes, featureCount: manifest.generated.featureCount,
    manifestSHA256: sha256(manifestBytes), manifestBytes: manifestBytes.length,
    runtime: { ...manifest.runtime },
    coverageCountries: manifest.coverageCountries, sourceCount: manifest.sources.length,
    sourceMetadataSHA256: manifest.sourceMetadataSHA256, sourceNote: manifest.sourceNote,
    parentMethod: manifest.parentMethod, additionalSimplification: manifest.additionalSimplification,
    shapelyVersion: manifest.shapelyVersion, geosVersion: manifest.geosVersion,
    attributionSHA256: manifest.attribution.sha256,
    sources: manifest.sources.map(({ metadata, verified, counts }) => ({
      iso: metadata.iso, country: metadata.country, level: metadata.level, year: metadata.year,
      url: metadata.url, license: metadata.license, sha256: verified.sha256, bytes: verified.bytes,
      featureCount: counts.emitted,
    })),
  };
}

function fixture(sources) {
  // Invented squares and labels only; source fingerprints below are contract values,
  // NOT a claim that these fixtures contain or verify the upstream source geometry.
  const ring = [[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]];
  const collection = { type: 'FeatureCollection', coverageCountries, sourceNote: sourceNote(sources),
    features: sources.map((s, index) => ({ type: 'Feature',
      properties: { iso: s.iso, country: s.country, level: s.level,
        label: `Synthetic region, ${s.country}`, sourceBoundaryID: `synthetic-${index}` },
      geometry: index % 2 ? { type: 'MultiPolygon', coordinates: [[ring]] } : { type: 'Polygon', coordinates: [ring] },
    })) };
  const reports = sources.map(metadata => ({ metadata,
    verified: { sha256: metadata.sha256, bytes: 1 }, issues: [],
    counts: { ...Object.fromEntries(countNames.map(name => [name, 0])), raw: 1, emitted: 1,
      parentMatched: metadata.level === 'ADM2' ? 1 : 0 },
  }));
  const text = 'Synthetic attribution — schema test only, not source verification.\n';
  const manifest = { schemaVersion: 1, generator, sourceMetadataSHA256: sha256(JSON.stringify(sources)),
    shapelyVersion: '2.1.2', geosVersion: 'synthetic', coverageCountries, sourceNote: collection.sourceNote,
    parentMethod: 'Synthetic parent-method description; no location lookup performed.', additionalSimplification: false,
    sources: reports, totals: Object.fromEntries(countNames.map(name => [name, reports.reduce((sum, s) => sum + s.counts[name], 0)])),
    attribution: { text, licenseURLs, sha256: sha256(text), bytes: Buffer.byteLength(text) },
    generated: { file: packName, featureCount: sources.length },
  };
  const result = structuredClone({ collection, manifest });
  refreshFingerprint(result);
  return result;
}

function fixtureBytes(value) { return Buffer.from(JSON.stringify(value.collection) + '\n'); }
function refreshFingerprint(value) {
  const bytes = fixtureBytes(value);
  Object.assign(value.manifest.generated, { bytes: bytes.length, sha256: sha256(bytes) });
  value.manifest.runtime = { schemaVersion: 1, version: runtimeVersion(bytes),
    coverageDescription: runtimeCoverageDescription(value.collection.coverageCountries, value.collection.features.length) };
}
function writeFixture(folder, value) {
  mkdirSync(folder, { recursive: true });
  writeFileSync(path.join(folder, packName), fixtureBytes(value));
  writeFileSync(path.join(folder, manifestName), JSON.stringify(value.manifest) + '\n');
}

function selfTest() {
  for (const [text, hex] of [['', 'cbf29ce484222325'], ['a', 'af63dc4c8601ec8c'], ['fo', '8985907b541d342'],
    ['hello', 'a430d84680aabd0b'], ['foobar', '85944171f73967e8']]) {
    assert.equal(runtimeVersion(Buffer.from(text)), `raycast-v1-${hex}`, 'Fixed FNV-1a vector; no zero padding');
  }
  // Exact fixture shared with Python and native PlacePackMetadataTests, including LF.
  const smallGeometry = Buffer.from('{"type":"FeatureCollection","coverageCountries":["Synthetic"],"features":[{"type":"Feature","properties":{"label":"Square, Synthetic","level":"ADM1"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,1],[0,0]]]}}]}\n');
  assert.equal(runtimeVersion(smallGeometry), 'raycast-v1-4b2d9ec5135d4ccc');
  assert.equal(runtimeVersion(smallGeometry.subarray(0, -1)), 'raycast-v1-da2e3970db8ea20e');
  const sources = validateSources(json(path.join(root, 'scripts', 'place_sources.json')));
  const valid = fixture(sources);
  const temporary = mkdtempSync(path.join(tmpdir(), 'imageiq-places-contract-'));
  try {
    const direct = path.join(temporary, 'direct');
    writeFixture(direct, valid);
    const report = validatePlaces(direct);
    assert.equal(report.file, packName);
    assert.equal(report.manifest, manifestName);
    assert.equal(report.bytes, fixtureBytes(valid).length);
    assert.equal(report.sha256, sha256(fixtureBytes(valid)));
    assert.equal(report.manifestSHA256, sha256(readFileSync(path.join(direct, manifestName))));
    assert.equal(report.featureCount, 8);
    assert.equal(report.sourceCount, 8);
    assert.deepEqual(report.coverageCountries, coverageCountries);
    assert.equal(report.sources.reduce((sum, s) => sum + s.featureCount, 0), report.featureCount);
    assert.equal(report.sourceNote, valid.manifest.sourceNote);
    assert.deepEqual(report.runtime, valid.manifest.runtime);
    assert.equal(report.attributionSHA256, valid.manifest.attribution.sha256);
    assert.doesNotMatch(JSON.stringify(report), /"coordinates"|"features"/);
    assert.deepEqual(JSON.parse(JSON.stringify({ places: report })).places, report, 'Device report JSON contract');

    const rejectManifest = (mutate, pattern) => {
      const value = structuredClone(valid);
      mutate(value.manifest);
      writeFixture(direct, value);
      assert.throws(() => validatePlaces(direct), pattern);
    };
    rejectManifest(m => { m.schemaVersion = 2; }, /manifest schema/);
    rejectManifest(m => { delete m.runtime; }, /Runtime metadata schema/);
    rejectManifest(m => { m.runtime = null; }, /Runtime metadata schema/);
    rejectManifest(m => { m.runtime.schemaVersion = 2; }, /Runtime metadata schema/);
    rejectManifest(m => { m.runtime.schemaVersion = '1'; }, /Runtime metadata schema/);
    rejectManifest(m => { delete m.runtime.version; }, /string|Runtime version format/);
    for (const version of ['', 'places-unavailable', 'raycast-v2-abc', 'raycast-v1-ABC',
      'raycast-v1-01', 'raycast-v1-', 'raycast-v1-1234567890abcdef0', 'raycast-v1-abc\n']) {
      rejectManifest(m => { m.runtime.version = version; }, /Runtime version/);
    }
    rejectManifest(m => { m.runtime.version = 'raycast-v1-0'; }, /Runtime version must match/);
    rejectManifest(m => { delete m.runtime.coverageDescription; }, /Runtime coverage description/);
    rejectManifest(m => { m.runtime.coverageDescription = ''; }, /Runtime coverage description/);
    rejectManifest(m => { m.runtime.coverageDescription += ' changed'; }, /Runtime coverage description/);
    rejectManifest(m => { m.generated.sha256 = '0'.repeat(64); }, /Generated SHA-256/);
    rejectManifest(m => { m.generated.bytes++; }, /Generated byte count/);
    rejectManifest(m => { m.generated.featureCount++; }, /Generated feature count/);
    rejectManifest(m => { m.coverageCountries.pop(); }, /Manifest country coverage/);
    rejectManifest(m => { m.sources.pop(); }, /eight sources/);
    rejectManifest(m => { m.sources[1] = m.sources[0]; }, /Source metadata/);
    rejectManifest(m => { m.sources[0].metadata.url = 'https://example.invalid/not-public-geometry'; }, /Source metadata/);
    rejectManifest(m => { m.sources[0].metadata.license = 'unknown'; }, /Source metadata/);
    rejectManifest(m => { m.sources[0].verified.sha256 = '0'.repeat(64); }, /Verified source SHA-256/);
    rejectManifest(m => { m.sources[0].verified.bytes = 0; }, /Verified source bytes/);
    rejectManifest(m => { m.sourceMetadataSHA256 = '0'.repeat(64); }, /Source metadata SHA-256/);
    rejectManifest(m => { m.sources[0].counts.emitted = 0; }, /emitted must be a positive integer/);
    rejectManifest(m => { m.sources[0].counts.raw++; }, /Raw = emitted/);
    rejectManifest(m => { m.sources[1].counts.parentMatched = 0; }, /Parent outcome count/);
    rejectManifest(m => { m.totals.emitted++; }, /Totals must equal/);
    rejectManifest(m => { m.attribution.text += 'modified'; }, /Attribution byte count/);
    rejectManifest(m => { m.attribution.sha256 = '0'.repeat(64); }, /Attribution SHA-256/);
    rejectManifest(m => { delete m.attribution.licenseURLs.geoBoundaries; }, /Attribution license URLs/);
    rejectManifest(m => { delete m.sourceNote; }, /Manifest source note/);

    // Resealing SHA alone must not hide stale geography cache identity. Even
    // semantically identical geometry with one extra byte has a new identity.
    writeFixture(direct, valid);
    const changedBytes = Buffer.concat([fixtureBytes(valid), Buffer.from(' ')]);
    const stale = structuredClone(valid.manifest);
    Object.assign(stale.generated, { bytes: changedBytes.length, sha256: sha256(changedBytes) });
    writeFileSync(path.join(direct, packName), changedBytes);
    writeFileSync(path.join(direct, manifestName), JSON.stringify(stale));
    assert.throws(() => validatePlaces(direct), /Runtime version must match exact GeoJSON bytes/);
    stale.runtime.version = runtimeVersion(changedBytes);
    writeFileSync(path.join(direct, manifestName), JSON.stringify(stale));
    assert.equal(validatePlaces(direct).runtime.version, stale.runtime.version);

    const rejectPack = (mutate, pattern) => {
      const value = structuredClone(valid);
      mutate(value.collection);
      refreshFingerprint(value); // Deliberately re-seal to test content, not just checksum failures.
      writeFixture(direct, value);
      assert.throws(() => validatePlaces(direct), pattern);
    };
    rejectPack(c => { c.features = []; }, /Empty feature collection/);
    rejectPack(c => { c.coverageCountries = ['China']; }, /GeoJSON country coverage/);
    rejectPack(c => { c.sourceNote = ''; }, /GeoJSON source note/);
    rejectPack(c => { c.features[0].properties.label = ''; }, /Feature label/);
    rejectPack(c => { c.features[0].properties.iso = 'USA'; }, /Feature source coverage/);
    rejectPack(c => { c.features[0].properties = structuredClone(c.features[1].properties); }, /Features per country/);
    rejectPack(c => { c.features[0].geometry.coordinates = []; }, /Empty polygon rings/);

    for (const [index, relative] of ['', 'Places', 'Resources/Places'].entries()) {
      const app = path.join(temporary, `layout-${index}.app`);
      writeFixture(path.join(app, relative), valid);
      const bundled = validatePlaces(app, { appBundle: true });
      assert.equal(bundled.file, relative ? `${relative}/${packName}` : packName);
      assert.equal(bundled.manifest, relative ? `${relative}/${manifestName}` : manifestName);
    }
    const wrongCase = path.join(temporary, 'wrong-case.app');
    writeFixture(wrongCase, valid);
    rmSync(path.join(wrongCase, packName));
    writeFileSync(path.join(wrongCase, 'places.geojson'), fixtureBytes(valid));
    assert.throws(() => validatePlaces(wrongCase, { appBundle: true }), /Missing Places.geojson/);
    // Separate directories avoid case-preserving overwrite behavior on Windows/APFS.
    const wrongManifestCase = path.join(temporary, 'wrong-manifest-case.app');
    writeFixture(wrongManifestCase, valid);
    rmSync(path.join(wrongManifestCase, manifestName));
    writeFileSync(path.join(wrongManifestCase, 'Places-manifest.json'), JSON.stringify(valid.manifest));
    assert.throws(() => validatePlaces(wrongManifestCase, { appBundle: true }), /Missing colocated/);
    const wrongFolder = path.join(temporary, 'wrong-folder.app');
    writeFixture(path.join(wrongFolder, 'places'), valid);
    assert.throws(() => validatePlaces(wrongFolder, { appBundle: true }), /Missing Places.geojson/);
    const testsOnly = path.join(temporary, 'tests-only.app');
    writeFixture(path.join(testsOnly, 'PlugIns', 'Tests.xctest'), valid);
    assert.throws(() => validatePlaces(testsOnly, { appBundle: true }), /Missing Places.geojson/);
    const split = path.join(temporary, 'split.app');
    writeFixture(split, valid);
    rmSync(path.join(split, manifestName));
    writeFixture(path.join(split, 'Places'), valid);
    assert.throws(() => validatePlaces(split, { appBundle: true }), /Missing colocated/);
    const absent = path.join(temporary, 'missing.app');
    mkdirSync(absent);
    assert.throws(() => validatePlaces(absent, { appBundle: true }), /Missing Places.geojson/);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
  console.log('PASS: synthetic Places schema, SHA/FNV fingerprints, runtime metadata/stale-version rejection, coverage, source totals, attribution, bundle paths and report contracts; no downloads/GPS/native tests.');
}

function main(args) {
  if (args.length === 1 && args[0] === '--self-test') return selfTest();
  if (args.length === 1 && args[0] === '--help') {
    console.log('node scripts/check_places.mjs\nnode scripts/check_places.mjs --self-test\nnode scripts/check_places.mjs --pack-dir Resources/Places\nnode scripts/check_places.mjs --app-dir path/to/LocalImageIQ.app\nNo arguments: source metadata only; generated files not required. Explicit pack/app modes never skip a missing pack.');
    return;
  }
  if (args.length === 0) {
    validateSources(json(path.join(root, 'scripts', 'place_sources.json')));
    console.log('PASS: eight pinned public source metadata records; generated Places pack not checked in this source-only mode.');
    return;
  }
  assert.ok(args.length === 2 && ['--pack-dir', '--app-dir'].includes(args[0]) && !args[1].startsWith('--'), 'Expected --pack-dir DIRECTORY or --app-dir APP; use --help');
  console.log(JSON.stringify(validatePlaces(args[1], { appBundle: args[0] === '--app-dir' }), null, 2));
}

// Importing from package_device.mjs must not execute this CLI or its self-tests.
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(`FAIL: Places: ${error.message}`); process.exitCode = 1; }
}