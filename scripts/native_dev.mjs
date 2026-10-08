import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const defaults = [
  'LocalImageIQTests/PhotoIncrementalSyncTests',
  'LocalImageIQTests/PhotoSyncStateTests',
  'LocalImageIQTests/PhotoSyncDiagnosticTests',
  'LocalImageIQTests/PhotoSyncFailureStageTests',
];

export function parseSelectors(value = defaults.join('\n')) {
  const selectors = value.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  if (!selectors.length) throw Error('Specify at least one exact test class or method.');
  for (const selector of selectors) {
    if (!/^(LocalImageIQTests|LocalImageIQUITests)\/[A-Za-z_][A-Za-z0-9_]*(?:\/test[A-Za-z0-9_]+)?$/.test(selector)) {
      throw Error('Invalid XCTest selector; expected target/class[/testMethod].');
    }
  }
  return [...new Set(selectors)];
}

export function makeArgs(selectors, simulator, buildOnly) {
  if (!/^[a-fA-F0-9-]+$/.test(simulator ?? '')) throw Error('Invalid simulator ID.');
  return [buildOnly ? 'build-for-testing' : 'test', '-project', 'LocalImageIQ.xcodeproj', '-scheme', 'LocalImageIQ',
    '-destination', `platform=iOS Simulator,id=${simulator}`, '-derivedDataPath', 'build/DevDerivedData',
    ...(!buildOnly ? ['-resultBundlePath', 'build/DevTests.xcresult', ...selectors.map(s => `-only-testing:${s}`)] : []),
    'CODE_SIGNING_ALLOWED=NO', 'IMAGEIQ_REQUIRE_MODELS=0', 'IMAGEIQ_TEST_ALL_COMPUTE_UNITS=0'];
}

// Xcode 16's test-results schema uses spaced node types, not TestCase/TestSuite.
// Public schema/example: https://qiita.com/irgaly/items/1221133786bbb76d9ba2
// This is a supported-shape contract, not evidence of a local Xcode 16.4 run.
const bundleTypes = new Set(['Unit test bundle', 'UI test bundle']);
const nodeTypes = new Set([
  'Test Plan', ...bundleTypes, 'Test Suite', 'Test Case', 'Device',
  'Test Plan Configuration', 'Arguments', 'Repetition', 'Test Case Run',
  'Failure Message', 'Source Code Reference', 'Attachment', 'Expression', 'Test Value',
]);
const caseResults = new Set(['Passed', 'Failed', 'Skipped']);
const withoutEmptyParentheses = value => typeof value === 'string' ? value.replace(/\(\)$/, '') : value;
const exactOrPathSuffix = (value, suffix) => typeof value === 'string'
  && (value === suffix || value.endsWith(`/${suffix}`));

export function validateTestResults(summary, tree, selectors) {
  selectors = parseSelectors(selectors.join('\n'));
  const errors = [];
  const counts = {};
  for (const key of ['totalTestCount', 'passedTests', 'failedTests', 'skippedTests']) {
    const value = summary?.[key];
    counts[key] = Number.isSafeInteger(value) && value >= 0 ? value : null;
    if (counts[key] === null) errors.push(`Unknown summary shape: ${key} must be a nonnegative integer.`);
  }
  if (counts.totalTestCount === 0) errors.push('No tests ran: totalTestCount is zero.');
  if (counts.passedTests === 0) errors.push('No tests passed: a skip-only run is not validation.');
  if (counts.failedTests > 0) errors.push(`Summary reports ${counts.failedTests} failed tests.`);

  const suites = [];
  const cases = [];
  function walk(nodes, ancestors = []) {
    let hasTestCase = false;
    for (const node of nodes) {
      if (!node || typeof node !== 'object' || Array.isArray(node)) {
        errors.push('Unknown test tree shape: each test node must be an object.');
        continue;
      }
      const label = node.nodeIdentifier ?? node.name ?? '(unnamed)';
      if (!nodeTypes.has(node.nodeType)) errors.push(`Unsupported nodeType ${JSON.stringify(node.nodeType)} at ${label}.`);
      if (node.children !== undefined && !Array.isArray(node.children)) {
        errors.push(`Unknown test tree shape: children must be an array at ${label}.`);
      }
      // Traverse only structural children, at any depth; never scan metadata or log strings.
      const childHasCase = walk(Array.isArray(node.children) ? node.children : [], [...ancestors, node]);
      if (node.nodeType === 'Test Suite') suites.push({ node, ancestors });
      if (node.nodeType === 'Test Case') {
        if (!caseResults.has(node.result)) errors.push(`Unsupported Test Case result ${JSON.stringify(node.result)} at ${label}.`);
        if (node.result === 'Failed') errors.push(`Test Case failed: ${label}.`);
        // Failure-message children are not cases; aggregate cases with child cases are not leaves.
        if (!childHasCase) cases.push({ node, ancestors });
      }
      hasTestCase ||= node.nodeType === 'Test Case' || childHasCase;
    }
    return hasTestCase;
  }
  if (!Array.isArray(tree?.testNodes)) errors.push('Unknown test tree shape: testNodes must be an array.');
  else walk(tree.testNodes);
  if (!cases.some(({ node }) => node.result === 'Passed')) errors.push('No passed Test Case leaf in the test tree.');

  const nearestBundle = ancestors => ancestors.findLast(node => bundleTypes.has(node.nodeType));
  const selections = selectors.map(selector => {
    const [target, className, method] = selector.split('/');
    const expectedBundleType = target === 'LocalImageIQTests' ? 'Unit test bundle' : 'UI test bundle';
    const matchedSuites = suites.filter(({ node, ancestors }) => {
      const bundle = nearestBundle(ancestors);
      return bundle?.nodeType === expectedBundleType
        && (bundle.name === target || bundle.nodeIdentifier === target)
        && (node.name === className || node.nodeIdentifier === className
          || exactOrPathSuffix(node.nodeIdentifier, `${target}/${className}`));
    });
    const matchingCases = cases.filter(({ node, ancestors }) => matchedSuites.some(suite => {
      if (!ancestors.includes(suite.node) || nearestBundle(ancestors) !== nearestBundle(suite.ancestors)) return false;
      if (!method) return true;
      // A same-named method in another (nested) class is not the requested method.
      if (ancestors.findLast(parent => parent.nodeType === 'Test Suite') !== suite.node) return false;
      const name = withoutEmptyParentheses(node.name);
      const id = withoutEmptyParentheses(node.nodeIdentifier);
      return name === method || id === method || id === `${className}/${method}`
        || exactOrPathSuffix(id, `${target}/${className}/${method}`);
    }));
    const passedTests = matchingCases.filter(({ node }) => node.result === 'Passed').length;
    const failedTests = matchingCases.filter(({ node }) => node.result === 'Failed').length;
    const skippedTests = matchingCases.filter(({ node }) => node.result === 'Skipped').length;
    const executedTests = passedTests + failedTests;
    if (!matchedSuites.length) errors.push(`Requested class suite not found under its test bundle: ${selector}.`);
    else if (!matchingCases.length) errors.push(`No matching Test Case leaf for requested selector: ${selector}.`);
    else if (!executedTests) errors.push(`Requested selector has no executed (Passed/Failed) tests: ${selector}.`);
    return { selector, matchedSuites: matchedSuites.length, passedTests, failedTests, skippedTests, executedTests };
  });
  return { status: errors.length ? 'failed' : 'passed', counts, selections, errors };
}

export function runNativeChecks(selectors, simulator, buildOnly, {
  run = spawnSync, writeFile = fs.writeFileSync, exists = fs.existsSync,
} = {}) {
  // Full build output stays on inherited streams; only the two small JSON reports are piped.
  const result = run('xcodebuild', makeArgs(selectors, simulator, buildOnly), { stdio: 'inherit' });
  const buildSucceeded = !result.error && result.status === 0 && !result.signal;
  const report = {
    status: 'failed', buildOnly, testsValidated: false, selectors,
    xcodebuildStatus: result.status ?? null, xcodebuildSignal: result.signal ?? null,
    errors: [],
  };
  if (!buildSucceeded) report.errors.push(`xcodebuild failed: ${result.error?.message ?? result.signal ?? result.status ?? 'unknown status'}.`);
  if (buildOnly) {
    report.status = buildSucceeded ? 'compiled-only' : 'failed';
    report.note = 'Compile only: no tests executed or validated.';
  } else if (buildSucceeded || exists('build/DevTests.xcresult')) {
    const reports = {};
    for (const [kind, output] of [['summary', 'build/dev-test-summary.json'], ['tests', 'build/dev-test-tree.json']]) {
      try {
        // get test-results emits JSON by default; --format belongs to the legacy get object API.
        const extracted = run('xcrun', ['xcresulttool', 'get', 'test-results', kind, '--path', 'build/DevTests.xcresult'],
          { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
        // Preserve raw evidence even if parsing/validation fails; try the other report independently.
        if (typeof extracted.stdout === 'string' && extracted.stdout.length) writeFile(output, extracted.stdout);
        if (extracted.error) throw extracted.error;
        if (extracted.status !== 0 || extracted.signal) {
          throw Error(`exit ${extracted.status ?? 'unknown'}${extracted.signal ? ` (${extracted.signal})` : ''}: ${extracted.stderr?.trim() ?? ''}`);
        }
        reports[kind] = JSON.parse(extracted.stdout);
      } catch (error) {
        report.errors.push(`xcresulttool ${kind}: ${error.message}`);
      }
    }
    const validation = validateTestResults(reports.summary, reports.tests, selectors);
    report.counts = validation.counts;
    report.selections = validation.selections;
    report.errors.push(...validation.errors);
    if (!report.errors.length) { report.status = 'passed'; report.testsValidated = true; }
  } else {
    report.errors.push('No result bundle available; tests were not validated.');
  }
  // Persist diagnostics BEFORE main sets a failing process exit code.
  writeFile('build/dev-validation.json', JSON.stringify(report, null, 2));
  return { exitCode: buildSucceeded ? (report.errors.length ? 1 : 0) : (result.status || 1), report };
}

function main() {
  const selectors = parseSelectors(process.env.IMAGEIQ_DEV_TESTS);
  const buildOnly = process.env.IMAGEIQ_DEV_BUILD_ONLY === 'true';
  if (process.argv[2] === '--validate') { console.log(JSON.stringify({ selectors, buildOnly })); return; }
  if (process.platform !== 'darwin') throw Error('Native development checks require macOS/Xcode.');
  const modelFiles = fs.readdirSync('Resources/Models').filter(n => n !== 'README.md');
  if (modelFiles.length) throw Error('Model-free development checkout must not contain generated model resources.');
  const args = makeArgs(selectors, process.env.SIMULATOR_ID, buildOnly);
  fs.mkdirSync('build', { recursive: true });
  fs.writeFileSync('build/dev-request.json', JSON.stringify({
    sha: process.env.GITHUB_SHA, selectors, buildOnly, args,
    boundary: 'Development-only, model-free, no release/IPA. Full app and test targets may still compile.',
  }, null, 2));
  const result = runNativeChecks(selectors, process.env.SIMULATOR_ID, buildOnly);
  console.log(JSON.stringify(result.report, null, 2));
  process.exitCode = result.exitCode;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}