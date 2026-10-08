import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { parseSelectors, makeArgs, validateTestResults, runNativeChecks } from './native_dev.mjs';

test('defaults select only the four relevant classes, not a full target', () => {
  assert.equal(parseSelectors().length, 4);
  assert.ok(parseSelectors().every(s => s.startsWith('LocalImageIQTests/')));
});
test('selectors trim, preserve order and deduplicate exact entries', () => {
  assert.deepEqual(parseSelectors('LocalImageIQTests/Foo\r\n LocalImageIQTests/Foo\nLocalImageIQUITests/Bar/testThing '),
    ['LocalImageIQTests/Foo', 'LocalImageIQUITests/Bar/testThing']);
});
test('reject empty, whole target, unknown target and shell/option injection', () => {
  for (const value of ['', ' \n', 'LocalImageIQTests', '-skip-testing:All', 'Other/Foo',
    'LocalImageIQTests/Foo; echo bad', 'LocalImageIQTests/Foo\n-quiet', 'LocalImageIQTests/Foo/*',
    'LocalImageIQTests/../Foo', 'LocalImageIQTests/Foo/notTest']) assert.throws(() => parseSelectors(value));
});
test('run uses explicit only-testing arguments and disables model requirements', () => {
  const args = makeArgs(['LocalImageIQTests/Foo'], 'A0000000-0000-0000-0000-000000000000', false);
  assert.equal(args[0], 'test');
  assert.ok(args.includes('-only-testing:LocalImageIQTests/Foo'));
  assert.ok(args.includes('IMAGEIQ_REQUIRE_MODELS=0'));
  assert.ok(!args.some(a => a.includes('iphoneos')));
});
test('build-only compiles tests without executing or pretending to produce a test result', () => {
  const args = makeArgs(['LocalImageIQTests/Foo'], 'A0000000-0000-0000-0000-000000000000', true);
  assert.equal(args[0], 'build-for-testing');
  assert.ok(!args.includes('-resultBundlePath'));
  assert.ok(!args.some(a => a.startsWith('-only-testing:')));
  assert.throws(() => makeArgs([], 'id; command', false));
});

// All fixtures below are SYNTHETIC, not captured output from this app or Xcode 16.4.
// Accepted schema vocabulary: https://qiita.com/irgaly/items/1221133786bbb76d9ba2
// testNodes -> children, spaced nodeType, name/nodeIdentifier, result on Test Case.
// Name-only bundle/suite and Class/testMethod() identifiers model the published example.
// Identifier-only/path-suffixed alternatives below test the explicit matching contract;
// they do not claim those alternatives have been observed in a native run.
const UNIT = 'LocalImageIQTests';
const UI = 'LocalImageIQUITests';
const SIMULATOR = 'A0000000-0000-0000-0000-000000000000';
const summary = (overrides = {}) => ({ totalTestCount: 1, passedTests: 1, failedTests: 0, skippedTests: 0, ...overrides });
const testCase = (name = 'testOne()', result = 'Passed') => ({
  nodeType: 'Test Case', name, nodeIdentifier: `Foo/${name}`, result,
});
const suite = (name = 'Foo', children = [{ ...testCase(), nodeIdentifier: `${name}/testOne()` }]) =>
  ({ nodeType: 'Test Suite', name, children });
const bundle = (name = UNIT, children = [suite()]) => ({
  nodeType: name === UI ? 'UI test bundle' : 'Unit test bundle', name, children,
});
const tree = (...bundles) => ({ testNodes: [{ nodeType: 'Test Plan', name: 'LocalImageIQ', children: bundles }] });
const validate = (nodes = tree(bundle()), selectors = [`${UNIT}/Foo`], counts = summary()) =>
  validateTestResults(counts, nodes, selectors);
function reject(nodes, selectors, counts, message) {
  const report = validate(nodes, selectors, counts);
  assert.equal(report.status, 'failed');
  assert.ok(report.errors.length > 0);
  if (message) assert.match(report.errors.join('\n'), message);
  return report;
}

test('documented spaced types validate a class and an exact XCTest method', () => {
  const report = validate(tree(bundle()), [`${UNIT}/Foo`, `${UNIT}/Foo/testOne`]);
  assert.equal(report.status, 'passed');
  assert.deepEqual(report.errors, []);
  assert.deepEqual(report.counts, summary());
  assert.deepEqual(report.selections.map(s => [s.matchedSuites, s.executedTests, s.passedTests]), [[1, 1, 1], [1, 1, 1]]);
});
test('synthetic defaults require executed cases in all four requested suites', () => {
  const selectors = parseSelectors();
  const nodes = tree(bundle(UNIT, selectors.map(s => suite(s.split('/')[1]))));
  assert.equal(validate(nodes, selectors, summary({ totalTestCount: 4, passedTests: 4 })).status, 'passed');
  nodes.testNodes[0].children[0].children.pop();
  reject(nodes, selectors, summary({ totalTestCount: 3, passedTests: 3 }), /Requested class suite not found/);
});
test('zero-test success and positive total with no passed tests are rejected', () => {
  reject(tree(bundle()), undefined, summary({ totalTestCount: 0, passedTests: 0 }), /totalTestCount is zero/);
  reject(tree(bundle(UNIT, [suite('Foo', [testCase('testOne()', 'Skipped')])])), undefined,
    summary({ passedTests: 0, skippedTests: 1 }), /skip-only run/);
});
test('missing, string, negative and fractional summary counters never become zero or success', () => {
  for (const field of Object.keys(summary())) {
    for (const value of [undefined, null, '1', -1, 0.5, NaN, Infinity, true]) {
      reject(tree(bundle()), undefined, summary({ [field]: value }), new RegExp(field));
    }
  }
});
test('summary failures and actual failed cases independently prevent success', () => {
  reject(tree(bundle()), undefined, summary({ failedTests: 1 }), /Summary reports 1 failed tests/);
  const failure = testCase('testOne()', 'Failed');
  failure.children = [{ nodeType: 'Failure Message', name: 'Assertion failed', result: 'Failed' }];
  reject(tree(bundle(UNIT, [suite('Foo', [failure, testCase('testOther()')])])), undefined,
    summary(), /Test Case failed: Foo\/testOne\(\)/);
});
test('every selector must match even when other requested tests passed', () => {
  for (const missing of [`${UNIT}/Fooo`, `${UNIT}/Foo/testOn`, `${UNIT}/Foo/testOneExtra`]) {
    const report = reject(tree(bundle()), [`${UNIT}/Foo`, missing]);
    assert.ok(report.errors.some(e => e.includes(missing)));
  }
});
test('a class or selected method with only skipped cases fails despite passed siblings', () => {
  const nodes = tree(bundle(UNIT, [
    suite('Foo', [testCase('testOne()', 'Skipped')]),
    suite('Bar', [{ ...testCase(), nodeIdentifier: 'Bar/testOne()' }]),
  ]));
  reject(nodes, [`${UNIT}/Foo`, `${UNIT}/Bar`], summary({ totalTestCount: 2, skippedTests: 1 }), /no executed/);
  const methods = tree(bundle(UNIT, [suite('Foo', [testCase('testOne()', 'Skipped'), testCase('testOther()')])]));
  assert.equal(validate(methods).status, 'passed');
  reject(methods, [`${UNIT}/Foo`, `${UNIT}/Foo/testOne`], summary(), /no executed/);
});
test('mixed passed and skipped class reports skips explicitly without counting them as execution', () => {
  const report = validate(tree(bundle(UNIT, [suite('Foo', [testCase(), testCase('testOther()', 'Skipped')])])),
    undefined, summary({ totalTestCount: 2, skippedTests: 1 }));
  assert.equal(report.status, 'passed');
  assert.equal(report.selections[0].skippedTests, 1);
  assert.equal(report.selections[0].executedTests, 1);
});
test('correct class names in a different target, untyped target, or wrong bundle kind do not match', () => {
  for (const targetNode of [
    bundle(UI), bundle(`${UNIT}Extra`),
    { ...bundle(), nodeType: 'Test Suite' },
    { ...bundle(), nodeType: 'UI test bundle' },
  ]) reject(tree(targetNode), undefined, undefined, /Requested class suite not found/);
});
test('UI tests are opt-in and require their own exact UI bundle', () => {
  const nodes = tree(bundle(UI));
  assert.equal(validate(nodes, [`${UI}/Foo/testOne`]).status, 'passed');
  reject(nodes, [`${UNIT}/Foo/testOne`]);
  assert.ok(parseSelectors().every(s => !s.startsWith(`${UI}/`)));
});
test('bundle identifier can identify the exact target, not arbitrary suffix or mentions', () => {
  const nodes = tree({ ...bundle(), name: 'Display label', nodeIdentifier: UNIT });
  assert.equal(validate(nodes).status, 'passed');
  for (const id of [`Other/${UNIT}`, `${UNIT}Extra`, `mentions ${UNIT}`]) {
    nodes.testNodes[0].children[0].nodeIdentifier = id;
    reject(nodes);
  }
});
test('class identity allows exact identifiers or target/class path suffixes, not loose suffixes', () => {
  for (const id of ['Foo', `${UNIT}/Foo`, `Project/${UNIT}/Foo`]) {
    assert.equal(validate(tree(bundle(UNIT, [{ ...suite('Display label'), nodeIdentifier: id }]))).status, 'passed');
  }
  for (const id of ['Other/Foo', `${UNIT}/FooExtra`, `Other${UNIT}/Foo`, `mentions ${UNIT}/Foo`]) {
    reject(tree(bundle(UNIT, [{ ...suite('Display label'), nodeIdentifier: id }])));
  }
});
test('method matching strips only terminal empty parentheses', () => {
  for (const name of ['testOne', 'testOne()']) {
    assert.equal(validate(tree(bundle(UNIT, [suite('Foo', [testCase(name)])])), [`${UNIT}/Foo/testOne`]).status, 'passed');
    const nameOnly = { nodeType: 'Test Case', name, result: 'Passed' };
    assert.equal(validate(tree(bundle(UNIT, [suite('Foo', [nameOnly])])), [`${UNIT}/Foo/testOne`]).status, 'passed');
  }
  for (const name of ['testOne(1)', 'testOne(value:)', 'testOne(_:)', 'testOne()Extra', 'testOne()()', ' testOne()', 'testone()']) {
    reject(tree(bundle(UNIT, [suite('Foo', [testCase(name)])])), [`${UNIT}/Foo/testOne`]);
  }
});
test('exact method identifiers work without matching display names and reject near matches', () => {
  for (const id of ['testOne()', 'Foo/testOne()', `${UNIT}/Foo/testOne()`, `Project/${UNIT}/Foo/testOne()`]) {
    const leaf = { ...testCase('Display label'), nodeIdentifier: id };
    assert.equal(validate(tree(bundle(UNIT, [suite('Foo', [leaf])])), [`${UNIT}/Foo/testOne`]).status, 'passed');
  }
  for (const id of ['Bar/testOne()', 'Foo/testOne(1)', `${UNIT}/FooExtra/testOne()`, `Other${UNIT}/Foo/testOne()`]) {
    reject(tree(bundle(UNIT, [suite('Foo', [{ ...testCase('Display label'), nodeIdentifier: id }])])), [`${UNIT}/Foo/testOne`]);
  }
});
test('same-named method elsewhere cannot satisfy an empty class or nested different class', () => {
  const other = suite('Bar', [{ ...testCase(), nodeIdentifier: 'Bar/testOne()' }]);
  reject(tree(bundle(UNIT, [suite('Foo', []), other])), [`${UNIT}/Foo/testOne`]);
  reject(tree(bundle(UNIT, [suite('Foo', [other])])), [`${UNIT}/Foo/testOne`]);
  reject(tree(bundle(UNIT, [suite('Foo', [bundle(UI)])])), [`${UNIT}/Foo`]);
});
test('known container children are traversed at arbitrary depth and across all branches', () => {
  const wrapped = { nodeType: 'Device', name: 'iPhone', children: [
    { nodeType: 'Test Plan Configuration', name: 'Default', children: [
      suite('Foo', [{ nodeType: 'Repetition', name: '1', children: [testCase()] }]),
      suite('Bar', [{ ...testCase('testOther()'), nodeIdentifier: 'Bar/testOther()' }]),
    ] },
  ] };
  const report = validate(tree(bundle(UNIT, [wrapped])), [`${UNIT}/Foo/testOne`, `${UNIT}/Bar/testOther`],
    summary({ totalTestCount: 2, passedTests: 2 }));
  assert.equal(report.status, 'passed');
  assert.equal(report.selections.length, 2);
});
test('suite/container results and metadata mentions cannot invent a passed test', () => {
  for (const nodeType of ['Failure Message', 'Attachment', 'Test Case Run', 'Test Suite']) {
    reject(tree(bundle(UNIT, [{ ...suite('Foo', [{ nodeType, name: 'testOne()', result: 'Passed' }]), result: 'Passed' }])));
  }
  const nodes = tree(bundle(UNIT, [suite('Foo', [])]));
  nodes.metadata = [testCase()];
  nodes.testNodes[0].children[0].children[0].details = JSON.stringify(testCase());
  reject(nodes);
});
test('aggregate case pass cannot hide a skipped actual leaf', () => {
  const aggregate = { ...testCase(), children: [testCase('testOne(1)', 'Skipped')] };
  reject(tree(bundle(UNIT, [suite('Foo', [aggregate])])), undefined, undefined, /No passed Test Case leaf/);
});
test('unknown schemas, node types, children shapes and results fail rather than silently skip', () => {
  for (const nodes of [null, {}, { testNodes: {} }, { tests: [bundle()] }, { testNodes: [] },
    { testNodes: [null] }, { testNodes: [[bundle()]] }, tree({ ...bundle(), children: {} })]) reject(nodes);
  for (const nodeType of ['TestCase', 'TestSuite', 'TestBundle', 'Test Bundle', 'Future Container']) {
    reject(tree(bundle(UNIT, [suite('Foo', [testCase(), { ...testCase('testOther()'), nodeType }])])),
      undefined, undefined, /Unsupported nodeType/);
  }
  for (const result of [undefined, 'Success', 'Expected Failure', 'unknown', 'passed']) {
    reject(tree(bundle(UNIT, [suite('Foo', [testCase(), { ...testCase('testOther()'), result }])])),
      undefined, undefined, /Unsupported Test Case result/);
  }
});

// Injected process/file functions: these tests never start xcodebuild/xcrun or write artifacts.
function simulate({ buildOnly = false, buildResult = { status: 0 }, bundleExists = true,
  selectors = [`${UNIT}/Foo`], reports = {} } = {}) {
  const calls = [];
  const writes = new Map();
  const events = [];
  const extracted = {
    summary: { status: 0, stdout: JSON.stringify(summary()) },
    tests: { status: 0, stdout: JSON.stringify(tree(bundle())) },
    ...reports,
  };
  const result = runNativeChecks(selectors, SIMULATOR, buildOnly, {
    run(command, args, options) {
      calls.push({ command, args, options });
      events.push(`run:${command === 'xcodebuild' ? command : args[3]}`);
      return command === 'xcodebuild' ? buildResult : extracted[args[3]];
    },
    writeFile(file, value) { writes.set(file, value); events.push(`write:${file}`); },
    exists(file) { assert.equal(file, 'build/DevTests.xcresult'); return bundleExists; },
  });
  events.push('returned');
  assert.deepEqual(JSON.parse(writes.get('build/dev-validation.json')), result.report);
  assert.deepEqual(events.slice(-2), ['write:build/dev-validation.json', 'returned']);
  return { ...result, calls, writes, events };
}
test('xcodebuild success must query both JSON reports; full build output is never piped', () => {
  const result = simulate({ bundleExists: false });
  assert.equal(result.exitCode, 0);
  assert.equal(result.report.testsValidated, true);
  assert.equal(result.report.status, 'passed');
  assert.equal(result.calls.length, 3);
  assert.deepEqual(result.calls[0].options, { stdio: 'inherit' });
  for (const [index, kind] of [[1, 'summary'], [2, 'tests']]) {
    assert.deepEqual(result.calls[index], {
      command: 'xcrun',
      args: ['xcresulttool', 'get', 'test-results', kind, '--path', 'build/DevTests.xcresult'],
      options: { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
    });
  }
  assert.ok(result.writes.has('build/dev-test-summary.json'));
  assert.ok(result.writes.has('build/dev-test-tree.json'));
});
test('successful native exit with typo or zero tests becomes a failed validation with saved evidence', () => {
  const typo = simulate({ selectors: [`${UNIT}/Fooo`] });
  assert.equal(typo.exitCode, 1);
  assert.equal(typo.report.testsValidated, false);
  assert.equal(typo.report.status, 'failed');
  assert.ok(typo.writes.has('build/dev-test-summary.json'));
  const empty = simulate({ reports: {
    summary: { status: 0, stdout: JSON.stringify(summary({ totalTestCount: 0, passedTests: 0 })) },
    tests: { status: 0, stdout: JSON.stringify({ testNodes: [] }) },
  } });
  assert.equal(empty.exitCode, 1);
  assert.match(empty.report.errors.join('\n'), /totalTestCount is zero/);
});
test('failed native exit remains failed even if both exported reports look successful', () => {
  const result = simulate({ buildResult: { status: 65 } });
  assert.equal(result.exitCode, 65);
  assert.equal(result.report.status, 'failed');
  assert.equal(result.report.testsValidated, false);
  assert.equal(result.calls.length, 3);
  assert.ok(result.writes.has('build/dev-test-summary.json'));
  assert.ok(result.writes.has('build/dev-test-tree.json'));
});
test('native signal/spawn error fails and missing bundle does not pretend to validate tests', () => {
  for (const buildResult of [{ status: null, signal: 'SIGTERM' }, { status: null, error: Error('spawn failed') }]) {
    const result = simulate({ buildResult, bundleExists: false });
    assert.equal(result.exitCode, 1);
    assert.equal(result.report.testsValidated, false);
    assert.equal(result.calls.length, 1);
    assert.match(result.report.errors.join('\n'), /No result bundle/);
  }
});
test('report command failures or invalid JSON cannot be masked by a valid other report', () => {
  for (const kind of ['summary', 'tests']) {
    for (const extracted of [
      { status: 1, stdout: '{}', stderr: 'unsupported option' },
      { status: null, signal: 'SIGTERM', stdout: '{}' },
      { status: null, error: Error('spawn failed') },
      { status: null, error: Error('ENOBUFS'), stdout: '{"partial":' },
      { status: 0, stdout: '{invalid json' },
      { status: 0, stdout: '' },
    ]) {
      const result = simulate({ reports: { [kind]: extracted } });
      assert.equal(result.exitCode, 1);
      assert.equal(result.report.testsValidated, false);
      assert.equal(result.calls.length, 3);
      assert.match(result.report.errors.join('\n'), new RegExp(`xcresulttool ${kind}:`));
      if (extracted.stdout) assert.equal(result.writes.get(kind === 'summary' ? 'build/dev-test-summary.json' : 'build/dev-test-tree.json'), extracted.stdout);
    }
  }
});
test('unknown tree JSON is retained unchanged before a failed validation report is written', () => {
  const raw = '{"newSchema":{"name":"Foo","result":"Passed"}}';
  const result = simulate({ reports: { tests: { status: 0, stdout: raw } } });
  assert.equal(result.exitCode, 1);
  assert.equal(result.writes.get('build/dev-test-tree.json'), raw);
  assert.ok(result.events.indexOf('write:build/dev-test-summary.json') < result.events.indexOf('run:tests'));
  assert.match(result.report.errors.join('\n'), /testNodes must be an array/);
});
test('build-only never reads stale xcresults or asserts tests, and clearly reports compiled-only', () => {
  const result = simulate({ buildOnly: true, bundleExists: true, selectors: [`${UNIT}/Typo`] });
  assert.equal(result.exitCode, 0);
  assert.equal(result.report.status, 'compiled-only');
  assert.equal(result.report.testsValidated, false);
  assert.match(result.report.note, /no tests executed or validated/);
  assert.equal(result.calls.length, 1);
  assert.equal(result.calls[0].args[0], 'build-for-testing');
  assert.equal(result.writes.size, 1);
  assert.equal('counts' in result.report, false);
  const failed = simulate({ buildOnly: true, buildResult: { status: 65 } });
  assert.equal(failed.exitCode, 65);
  assert.equal(failed.report.status, 'failed');
  assert.equal(failed.calls.length, 1);
});
test('workflow pins Xcode by environment, checks version, and uploads evidence without re-extraction', () => {
  const workflow = fs.readFileSync(new URL('../.github/workflows/ios-dev.yml', import.meta.url), 'utf8');
  assert.match(workflow, /DEVELOPER_DIR: \/Applications\/Xcode_16\.4\.app\/Contents\/Developer/);
  assert.ok(workflow.includes('[ ! -d "$DEVELOPER_DIR" ]'));
  assert.ok(workflow.includes("grep -Eq '^Xcode 16\\.4$'"));
  assert.ok(workflow.indexOf('Select and verify preinstalled Xcode 16.4') < workflow.indexOf('Validate selectors and inspect toolchain'));
  assert.doesNotMatch(workflow, /xcode-select|xcresulttool|continue-on-error|actions\/cache/);
  assert.match(workflow, /Record development-only result\s+if: always\(\)/);
  assert.match(workflow, /actions\/upload-artifact@v4\s+if: always\(\)/);
  for (const file of ['dev-request.json', 'dev-test-summary.json', 'dev-test-tree.json', 'dev-validation.json', 'DevTests.xcresult']) {
    assert.ok(workflow.slice(workflow.indexOf('path: |')).includes(`build/${file}`));
  }
});