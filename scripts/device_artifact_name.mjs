// Pure naming contract; no coercion, trimming, numeric conversion or version/length caps.
// The final lookahead requires the actual end, unlike $ which also permits a trailing newline.
const VERSION = /^[0-9]+(?:\.[0-9]+)*(?![\s\S])/;

export function deviceIPAName(appVersion, appBuild) {
  if (![appVersion, appBuild].every(value => typeof value === 'string' && VERSION.test(value)))
    throw new Error('device-artifact-identity');
  return `LocalImageIQ-${appVersion}-build${appBuild}-iphoneos-unsigned.ipa`;
}